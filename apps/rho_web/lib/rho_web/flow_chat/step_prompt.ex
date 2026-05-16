defmodule RhoWeb.FlowChat.StepPrompt do
  @moduledoc """
  Builds compact, step-scoped prompts from flow metadata.

  This keeps step chat aligned with `FlowRunner` and `RhoFrameworks.Flow`
  definitions instead of duplicating workflow playbooks in a separate prompt.
  """

  alias RhoFrameworks.FlowRunner
  alias RhoWeb.FlowChat.{Message, StepPresenter}

  @spec build(module(), FlowRunner.state(), keyword()) :: String.t()
  def build(flow_mod, runner, opts \\ []) when is_atom(flow_mod) and is_map(runner) do
    step = Keyword.get(opts, :step) || FlowRunner.current_node(runner)
    message = Keyword.get(opts, :message) || present(flow_mod, runner, step, opts)
    tool_names = Keyword.get(opts, :tool_names, [])

    table_name =
      Keyword.get(opts, :table_name) || artifact_table(message) || table_from_runner(runner)

    """
    You are a step-scoped assistant inside the "#{flow_mod.label()}" flow.
    FlowRunner owns workflow state. Interpret the user's request only for the current step.

    Current step: #{format_node_id(step)}
    Step label: #{step_label(step)}
    Step type: #{step_type(step)}
    Goal: #{goal(message, step)}

    Allowed actions:
    #{format_actions(message)}

    Allowed tools:
    #{format_tools(tool_names)}

    Current artifacts:
    #{format_artifacts(message, table_name, runner)}

    Current context:
    #{format_context(runner, table_name)}

    Rules:
    - Stay inside this step. Do not route to other workflow steps.
    - Use only the listed tool surface for this step.
    - If the user's request is clear, call the current step's use-case tool once and stop.
    - If the request is genuinely ambiguous, call `clarify` with one short question and stop.
    - Do not ask for values already listed in Current context; pass them through as-is.
    - Never run more than one tool per turn.
    """
  end

  defp present(_flow_mod, _runner, nil, _opts), do: nil

  defp present(flow_mod, runner, step, opts) do
    presenter_opts =
      opts
      |> Keyword.take([:selected_ids, :select_items, :step_status, :table_name])
      |> Keyword.put_new(:step_status, :idle)

    StepPresenter.present_node(flow_mod, step, runner, presenter_opts)
  end

  defp format_node_id(%{id: id}), do: Atom.to_string(id)
  defp format_node_id(_step), do: "(none)"

  defp step_label(%{label: label}) when is_binary(label), do: label
  defp step_label(_step), do: "(none)"

  defp step_type(%{type: type}) when is_atom(type), do: Atom.to_string(type)
  defp step_type(_step), do: "(unknown)"

  defp goal(%Message{body: body}, _step) when is_binary(body) and body != "", do: body
  defp goal(_message, %{label: label}) when is_binary(label), do: "Complete #{label}."
  defp goal(_message, _step), do: "Complete the current flow step."

  defp format_actions(%Message{actions: []}), do: "- No direct flow actions for this step."

  defp format_actions(%Message{actions: actions}) do
    Enum.map_join(actions, "\n", fn action ->
      "- #{action.id}: #{action.label}"
    end)
  end

  defp format_actions(_message), do: "- No direct flow actions for this step."

  defp format_tools([]), do: "- clarify"

  defp format_tools(tool_names) do
    tool_names
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> case do
      [] -> ["clarify"]
      names -> names
    end
    |> Enum.map_join("\n", fn name -> "- #{name}" end)
  end

  defp format_artifacts(
         %Message{artifact: %{kind: :table, table_name: table}},
         _table_name,
         _runner
       )
       when is_binary(table) and table != "" do
    "- Table artifact: #{table}"
  end

  defp format_artifacts(%Message{artifact: %{kind: :selection} = artifact}, _table_name, runner) do
    selected_count = Map.get(artifact, :selected_count, 0)
    item_count = Map.get(artifact, :item_count, 0)
    selected_roles = selected_role_names(runner)

    suffix =
      case selected_roles do
        [] -> ""
        roles -> " (#{Enum.join(roles, ", ")})"
      end

    "- Selection artifact: #{selected_count} of #{item_count} selected#{suffix}"
  end

  defp format_artifacts(_message, table_name, _runner)
       when is_binary(table_name) and table_name != "" do
    "- Table artifact: #{table_name}"
  end

  defp format_artifacts(_message, _table_name, runner) do
    case selected_role_names(runner) do
      [] -> "- No current artifact."
      roles -> "- Selected role profiles: #{Enum.join(roles, ", ")}"
    end
  end

  defp artifact_table(%Message{artifact: %{kind: :table, table_name: table}})
       when is_binary(table) and table != "",
       do: table

  defp artifact_table(_message), do: nil

  defp table_from_runner(%{summaries: summaries, intake: intake}) do
    get_in(summaries, [:generate_skills, :table_name]) ||
      get_in(summaries, [:generate, :table_name]) ||
      get_in(summaries, [:pick_template, :table_name]) ||
      table_from_intake(intake)
  end

  defp table_from_runner(_runner), do: nil

  defp table_from_intake(intake) do
    case get_intake(intake, :name) do
      name when is_binary(name) and name != "" -> RhoFrameworks.Library.Editor.table_name(name)
      _ -> nil
    end
  end

  defp format_context(runner, table_name) do
    intake = Map.get(runner, :intake, %{}) || %{}

    [
      {"Framework name", get_intake(intake, :name)},
      {"Description", get_intake(intake, :description)},
      {"Domain", get_intake(intake, :domain)},
      {"Target roles", get_intake(intake, :target_roles)},
      {"Structure size", get_intake(intake, :taxonomy_size)},
      {"Focus", get_intake(intake, :transferability)},
      {"Style", get_intake(intake, :specificity)},
      {"Proficiency levels", get_intake(intake, :levels)},
      {"Library table", table_name}
    ]
    |> Enum.reject(fn {_label, value} -> blank?(value) end)
    |> case do
      [] -> "- (none yet)"
      fields -> Enum.map_join(fields, "\n", fn {label, value} -> "- #{label}: #{value}" end)
    end
  end

  defp selected_role_names(%{summaries: %{similar_roles: %{selected: selected}}})
       when is_list(selected) do
    selected
    |> Enum.map(fn role -> Rho.MapAccess.get(role, :name) end)
    |> Enum.reject(&blank?/1)
  end

  defp selected_role_names(_runner), do: []

  defp get_intake(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp get_intake(_map, _key), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
