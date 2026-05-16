defmodule RhoWeb.FlowChat.StepPresenter do
  @moduledoc """
  Projects `RhoFrameworks.FlowRunner` state into chat-native flow messages.
  """

  alias RhoFrameworks.FlowRunner
  alias RhoWeb.FlowChat.{Action, Message}

  @spec present(module(), FlowRunner.state(), keyword()) :: Message.t() | nil
  def present(flow_mod, runner, opts \\ []) when is_atom(flow_mod) do
    case FlowRunner.current_node(runner) do
      nil -> done_message(flow_mod)
      node -> present_node(flow_mod, node, runner, opts)
    end
  end

  @spec present_node(module(), map(), FlowRunner.state(), keyword()) :: Message.t()
  def present_node(flow_mod, %{type: :form} = node, runner, _opts) do
    fields = node.config[:fields] || []

    %Message{
      kind: :flow_prompt,
      flow_id: flow_mod.id(),
      node_id: node.id,
      title: node.label,
      body: form_body(node),
      fields: Enum.map(fields, &field_view(&1, runner.intake)),
      actions: form_actions(fields),
      meta: %{type: :form, routing: node[:routing]}
    }
  end

  def present_node(flow_mod, %{type: :select} = node, _runner, opts) do
    selected_ids = Keyword.get(opts, :selected_ids, [])
    items = Keyword.get(opts, :select_items, [])
    skippable? = node.config[:skippable] != false

    actions =
      []
      |> maybe_add_selected_action(selected_ids)
      |> maybe_add_skip_action(skippable?, node, items)
      |> Enum.reverse()

    %Message{
      kind: :flow_prompt,
      flow_id: flow_mod.id(),
      node_id: node.id,
      title: node.label,
      body: select_body(node, items, selected_ids),
      actions: actions,
      artifact: %{
        kind: :selection,
        node_id: node.id,
        item_count: length(items),
        selected_count: length(selected_ids),
        items: items,
        selected_ids: selected_ids,
        display_fields: node.config[:display_fields] || %{}
      },
      meta: %{type: :select, routing: node[:routing]}
    }
  end

  def present_node(flow_mod, %{type: :table_review} = node, runner, opts) do
    table_name = Keyword.get(opts, :table_name) || table_name_from_summary(node, runner)

    %Message{
      kind: :flow_artifact,
      flow_id: flow_mod.id(),
      node_id: node.id,
      title: node.label,
      body: table_body(node),
      actions: table_actions(node),
      artifact: %{kind: :table, table_name: table_name},
      meta: %{type: :table_review, routing: node[:routing]}
    }
  end

  def present_node(flow_mod, %{type: :action} = node, runner, opts) do
    status = Keyword.get(opts, :step_status, :idle)

    %Message{
      kind: action_kind(status),
      flow_id: flow_mod.id(),
      node_id: node.id,
      title: node.label,
      body: action_body(node, status, runner),
      actions: action_actions(node, status),
      meta: %{type: :action, routing: node[:routing], status: status}
    }
  end

  def present_node(flow_mod, node, _runner, _opts) do
    %Message{
      kind: :flow_prompt,
      flow_id: flow_mod.id(),
      node_id: node.id,
      title: node.label,
      body: "Continue this workflow step.",
      meta: %{type: node[:type], routing: node[:routing]}
    }
  end

  defp done_message(flow_mod) do
    %Message{
      kind: :flow_step_completed,
      flow_id: flow_mod.id(),
      node_id: :done,
      title: flow_mod.label(),
      body: "This flow is complete."
    }
  end

  defp form_body(%{id: :choose_starting_point}),
    do: "How would you like to start this framework?"

  defp form_body(%{id: :role_transform}),
    do: "How should the selected roles shape this framework?"

  defp form_body(%{id: :taxonomy_preferences}),
    do: "Choose the structure, focus, style, and proficiency depth before taxonomy generation."

  defp form_body(_node), do: "Fill in the fields for this step."

  defp form_actions([%{type: :select, name: name, options: options}]) when is_list(options) do
    Enum.map(options, fn {label, value} ->
      %Action{
        id: to_string(value),
        label: label,
        payload: %{name => value},
        event: :submit_form,
        variant: :primary
      }
    end)
  end

  defp form_actions(_fields), do: []

  defp field_view(field, intake) do
    %{
      name: field.name,
      label: field.label,
      type: field.type,
      required: field[:required] == true,
      value: get_intake(intake, field.name) || field[:default],
      options: field[:options] || [],
      description: field[:description],
      option_descriptions: field[:option_descriptions] || %{}
    }
  end

  defp maybe_add_selected_action(actions, []), do: actions

  defp maybe_add_selected_action(actions, selected_ids) do
    [
      %Action{
        id: "continue_selected",
        label: "Continue with #{length(selected_ids)} selected",
        payload: %{selected_ids: selected_ids},
        event: :confirm_selection,
        variant: :primary
      }
      | actions
    ]
  end

  defp maybe_add_skip_action(actions, false, _node, _items), do: actions

  defp maybe_add_skip_action(actions, true, node, items) do
    [
      %Action{
        id: "skip",
        label: skip_label(node, items),
        payload: %{skip: true},
        event: :skip_select,
        variant: :secondary
      }
      | actions
    ]
  end

  defp skip_label(%{id: :similar_roles}, _items), do: "Choose another starting point"
  defp skip_label(_node, _items), do: "Skip"

  defp select_body(%{id: :similar_roles}, [], _selected_ids),
    do:
      "No similar role profiles matched this framework. Choose another starting point to continue."

  defp select_body(%{id: :similar_roles}, _items, []),
    do:
      "Select any role profiles that should shape the framework, or choose another starting point."

  defp select_body(%{id: :similar_roles}, _items, selected_ids),
    do: "#{length(selected_ids)} role profile(s) selected."

  defp select_body(_node, _items, []), do: "Select the records to use for this step."
  defp select_body(_node, _items, selected_ids), do: "#{length(selected_ids)} item(s) selected."

  defp table_body(%{id: :review_taxonomy}),
    do: "Review or edit the taxonomy table before skills are generated."

  defp table_body(%{id: :review_clone}),
    do: "Cloned role skills are ready for surgical editing before saving."

  defp table_body(_node), do: "Review or edit the table artifact before continuing."

  defp table_actions(%{id: :review_taxonomy}) do
    [
      %Action{
        id: "generate_skills",
        label: "Generate skills",
        payload: %{continue: true},
        event: :continue,
        variant: :primary
      },
      %Action{
        id: "regenerate_taxonomy",
        label: "Regenerate taxonomy",
        payload: %{node_id: :generate_taxonomy},
        event: :regenerate_step,
        variant: :secondary
      },
      %Action{
        id: "focus_table",
        label: "Focus table",
        payload: %{},
        event: :focus_table,
        variant: :secondary
      }
    ]
  end

  defp table_actions(%{id: :review_clone}) do
    [
      %Action{
        id: "save_draft",
        label: "Save draft",
        payload: %{continue: true},
        event: :continue,
        variant: :primary
      },
      %Action{
        id: "reclone_skills",
        label: "Re-clone skills",
        payload: %{node_id: :pick_template},
        event: :regenerate_step,
        variant: :secondary
      },
      %Action{
        id: "focus_table",
        label: "Focus table",
        payload: %{},
        event: :focus_table,
        variant: :secondary
      }
    ]
  end

  defp table_actions(_node) do
    [
      %Action{
        id: "continue",
        label: "Continue",
        payload: %{continue: true},
        event: :continue,
        variant: :primary
      },
      %Action{
        id: "focus_table",
        label: "Focus table",
        payload: %{},
        event: :focus_table,
        variant: :secondary
      }
    ]
  end

  defp action_kind(:completed), do: :flow_step_completed
  defp action_kind(:failed), do: :flow_error
  defp action_kind(_status), do: :flow_prompt

  defp action_body(%{id: :identify_gaps}, :completed, runner) do
    gaps =
      runner.summaries
      |> Map.get(:identify_gaps, %{})
      |> get_field(:gaps)

    case gaps do
      list when is_list(list) and list != [] ->
        "Identified #{length(list)} candidate #{pluralise(length(list), "skill", "skills")} to add: " <>
          Enum.map_join(list, "; ", &gap_summary/1)

      _ ->
        "No clear skill gaps were found for the selected framework."
    end
  end

  defp action_body(%{config: %{manual: true}}, :idle, _runner), do: "Ready to continue this step."
  defp action_body(_node, :idle, _runner), do: "This step can run now."
  defp action_body(_node, :running, _runner), do: "This step is running."
  defp action_body(_node, :completed, _runner), do: "This step completed successfully."

  defp action_body(_node, :failed, _runner),
    do: "This step needs attention before it can continue."

  defp action_body(_node, _status, _runner), do: "Continue this workflow step."

  defp gap_summary(gap) when is_map(gap) do
    name = get_field(gap, :skill_name) || "Untitled skill"
    category = get_field(gap, :category)
    rationale = get_field(gap, :rationale)

    name
    |> append_if_present(category, fn value -> " (#{value})" end)
    |> append_if_present(rationale, fn value -> " — #{value}" end)
  end

  defp gap_summary(_gap), do: "Untitled skill"

  defp append_if_present(text, nil, _fun), do: text
  defp append_if_present(text, "", _fun), do: text
  defp append_if_present(text, value, fun), do: text <> fun.(value)

  defp get_field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp get_field(_, _), do: nil

  defp pluralise(1, singular, _plural), do: singular
  defp pluralise(_, _singular, plural), do: plural

  defp action_actions(node, :completed), do: table_actions(node)

  defp action_actions(%{config: %{manual: true}}, :idle) do
    [
      %Action{
        id: "confirm",
        label: "Continue",
        payload: %{confirm: true},
        event: :confirm_manual,
        variant: :primary
      }
    ]
  end

  defp action_actions(_node, :idle) do
    [
      %Action{
        id: "run",
        label: "Run step",
        payload: %{run: true},
        event: :run_action,
        variant: :primary
      }
    ]
  end

  defp action_actions(_node, :failed) do
    [
      %Action{
        id: "retry",
        label: "Retry",
        payload: %{retry: true},
        event: :retry_step,
        variant: :primary
      }
    ]
  end

  defp action_actions(_node, _status), do: []

  defp table_name_from_summary(%{config: config}, %{summaries: summaries}) do
    summary_key = config[:table_summary_key]
    table_field = config[:table_field] || :table_name

    if summary_key do
      get_in(summaries, [summary_key, table_field])
    end
  end

  defp get_intake(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp get_intake(_map, _key), do: nil
end
