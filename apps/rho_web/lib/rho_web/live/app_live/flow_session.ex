defmodule RhoWeb.AppLive.FlowSession do
  @moduledoc """
  Chat-hosted flow runner for `RhoWeb.AppLive`.

  This module keeps `RhoFrameworks.FlowRunner` as the workflow source of truth
  while projecting the current node into first-class chat cards.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, push_patch: 2]

  require Logger

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.Flow.Policies.Deterministic
  alias RhoFrameworks.{FlowRunner, Scope}
  alias RhoFrameworks.Flows.Registry, as: FlowRegistry
  alias RhoWeb.AppLive
  alias RhoWeb.AppLive.{DataTableEvents, WorkbenchDisplayState}
  alias RhoWeb.FlowChat.{Message, ReplyParser, StepPresenter}
  alias RhoWeb.Session.{SessionCore, SignalRouter}

  alias RhoFrameworks.UseCases.{
    GenerateFrameworkSkeletons,
    GenerateFrameworkTaxonomy,
    GenerateSkillsForTaxonomy,
    ResearchDomain
  }

  @type active_flow :: %{
          id: String.t(),
          flow_mod: module(),
          runner: FlowRunner.state(),
          scope: Scope.t(),
          status: atom(),
          completed_steps: [atom()],
          selected_ids: [String.t()],
          select_items: [map()],
          step_status: atom(),
          step_error: String.t() | nil,
          flow_chat_error: String.t() | nil,
          current_message_id: String.t() | nil
        }

  @doc "Start a flow in the active AppLive chat session."
  def start(socket, flow_id, intake \\ %{}, opts \\ [])
      when is_binary(flow_id) and is_map(intake) do
    case FlowRegistry.get(flow_id) do
      {:ok, flow_mod} ->
        {sid, socket} = ensure_chat_session(socket)
        :ok = ensure_data_table(sid)

        socket =
          case Keyword.get(opts, :user_message) do
            text when is_binary(text) and text != "" -> append_user_message(socket, text)
            _ -> socket
          end

        scope = %Scope{
          organization_id: socket.assigns.current_organization.id,
          session_id: sid,
          user_id: current_user_id(socket),
          source: :flow,
          reason: "chat-hosted #{flow_id} flow"
        }

        active_flow = %{
          id: flow_id,
          flow_mod: flow_mod,
          runner: FlowRunner.init(flow_mod, intake: normalize_intake(intake)),
          scope: scope,
          status: :awaiting_user,
          completed_steps: [],
          selected_ids: [],
          select_items: [],
          step_status: :idle,
          step_error: nil,
          flow_chat_error: nil,
          current_message_id: nil
        }

        socket
        |> assign(:active_flow, active_flow)
        |> maybe_push_chat(sid)
        |> append_current_card()

      :error ->
        put_flash(socket, :error, "Unknown flow: #{flow_id}")
    end
  end

  @doc "Handle a structured flow-card button click."
  def handle_action(socket, %{"action-id" => action_id, "node-id" => node_id})
      when is_binary(action_id) do
    with %Message{} = message <- current_message(socket),
         true <- stale_safe?(message, node_id),
         {:ok, result} <- ReplyParser.parse_action(message, action_id) do
      apply_result(socket, message, result)
    else
      false -> append_error(socket, "That action belongs to an earlier step.")
      {:error, _} -> append_error(socket, "That action is no longer available.")
      nil -> socket
    end
  end

  def handle_action(socket, _params), do: socket

  @doc "Toggle a selectable item in the active flow card."
  def handle_select_toggle(socket, %{"item-id" => item_id, "node-id" => node_id})
      when is_binary(item_id) and is_binary(node_id) do
    with %Message{} = message <- current_message(socket),
         true <- stale_safe?(message, node_id) do
      socket
      |> update_flow(fn flow ->
        selected_ids =
          if item_id in flow.selected_ids do
            List.delete(flow.selected_ids, item_id)
          else
            [item_id | flow.selected_ids]
          end

        %{flow | selected_ids: Enum.reverse(selected_ids), flow_chat_error: nil}
      end)
      |> replace_current_card()
    else
      false -> append_error(socket, "That selection belongs to an earlier step.")
      nil -> socket
    end
  end

  def handle_select_toggle(socket, _params), do: socket

  @doc "Handle editable fields submitted from a flow card."
  def handle_form(socket, %{"node-id" => node_id} = params) when is_binary(node_id) do
    with %Message{} = message <- current_message(socket),
         true <- stale_safe?(message, node_id) do
      payload =
        params
        |> Map.drop(["node-id"])
        |> Enum.reject(fn {_key, value} -> is_binary(value) and String.trim(value) == "" end)
        |> Map.new(fn
          {key, value} when is_binary(value) -> {key, String.trim(value)}
          pair -> pair
        end)

      apply_result(socket, message, %{
        action_id: "submit_form",
        event: :submit_form,
        payload: payload
      })
    else
      false -> append_error(socket, "That form belongs to an earlier step.")
      nil -> socket
    end
  end

  def handle_form(socket, _params), do: socket

  @doc "Handle normal composer text while a flow is active."
  def handle_reply(socket, text) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" ->
        socket

      active?(socket) ->
        socket = append_user_message(socket, text)
        message = current_message(socket)

        case ReplyParser.parse_reply(message, text) do
          {:ok, result} ->
            apply_result(socket, message, Map.put(result, :reply, text))

          {:error, _} ->
            append_error(
              socket,
              "I could not map that to this step. Use one of the actions or be more specific."
            )
        end

      true ->
        socket
    end
  end

  def active?(socket), do: is_map(socket.assigns[:active_flow])

  def active_awaiting_input?(socket) do
    case socket.assigns[:active_flow] do
      %{status: status} when status in [:awaiting_user, :failed] -> true
      _ -> false
    end
  end

  def complete_long_step(socket, node_id, summary) when is_atom(node_id) and is_map(summary) do
    if long_step_current?(socket, node_id) do
      runner_summary =
        summary
        |> Map.take([
          :table_name,
          :taxonomy_table_name,
          :library_id,
          :library_name,
          :category_count,
          :cluster_count,
          :preferences,
          :rejected_count,
          :inserted,
          :seen,
          :failed_queries,
          :pinned_count,
          :total_count
        ])
        |> Map.put_new(:table_name, summary[:table_name])

      socket
      |> update_flow(fn flow ->
        flow
        |> Map.update!(:runner, &FlowRunner.put_summary(&1, node_id, runner_summary))
        |> Map.merge(%{status: :awaiting_user, step_status: :completed, step_error: nil})
      end)
      |> refresh_data_table(summary[:table_name])
      |> append_current_card()
    else
      socket
    end
  end

  def fail_long_step(socket, node_id, reason) when is_atom(node_id) do
    if long_step_current?(socket, node_id) do
      socket
      |> update_flow(fn flow ->
        %{flow | status: :failed, step_status: :failed, step_error: inspect(reason)}
      end)
      |> append_current_card()
    else
      socket
    end
  end

  defp apply_result(socket, %Message{} = message, %{event: :submit_form} = result) do
    payload = normalize_intake(result[:payload] || %{})
    result = Map.put(result, :payload, payload)

    socket
    |> update_current_card_fields(message, payload)
    |> record_choice(message, result)
    |> update_flow(fn flow ->
      flow
      |> Map.update!(:runner, &FlowRunner.merge_intake(&1, payload))
      |> Map.merge(%{flow_chat_error: nil})
    end)
    |> advance_step()
    |> maybe_auto_run()
    |> append_current_card()
  end

  defp apply_result(socket, %Message{} = message, result) do
    socket = record_choice(socket, message, result)

    case result[:event] do
      :continue ->
        socket |> advance_step() |> maybe_auto_run() |> append_current_card()

      :confirm_selection ->
        socket |> confirm_selection() |> maybe_auto_run() |> append_current_card()

      :skip_select ->
        socket |> skip_select() |> maybe_auto_run() |> append_current_card()

      :confirm_manual ->
        confirm_manual(socket)

      :run_action ->
        socket |> run_action() |> append_current_card()

      :retry_step ->
        socket |> run_action() |> append_current_card()

      :regenerate_step ->
        socket |> regenerate_step(result[:payload] || %{}) |> append_current_card()

      :focus_table ->
        socket |> focus_table(message) |> append_current_card()

      _ ->
        append_current_card(socket)
    end
  end

  defp confirm_manual(socket) do
    case current_node(socket) do
      %{use_case: _} -> socket |> run_action() |> append_current_card()
      _ -> socket |> advance_step() |> maybe_auto_run() |> append_current_card()
    end
  end

  defp confirm_selection(socket) do
    flow = socket.assigns.active_flow
    step = FlowRunner.current_node(flow.runner)
    selected_count = length(flow.selected_ids)
    min_select = step.config[:min_select]
    max_select = step.config[:max_select]

    cond do
      is_integer(min_select) and selected_count < min_select ->
        append_error(socket, "Select at least #{min_select} to continue.")

      is_integer(max_select) and selected_count > max_select ->
        append_error(socket, "Select at most #{max_select} to continue.")

      true ->
        selected =
          Enum.filter(flow.select_items, fn item -> item_id(item) in flow.selected_ids end)

        summary = %{matches: flow.select_items, selected: selected, skip_reason: nil}

        socket
        |> update_flow(fn flow ->
          flow
          |> Map.update!(:runner, &FlowRunner.put_summary(&1, step.id, summary))
          |> Map.merge(%{selected_ids: [], select_items: [], flow_chat_error: nil})
        end)
        |> advance_step()
    end
  end

  defp skip_select(socket) do
    flow = socket.assigns.active_flow
    step = FlowRunner.current_node(flow.runner)
    summary = %{matches: [], selected: [], skip_reason: "user skipped"}

    socket
    |> update_flow(fn flow ->
      flow
      |> Map.update!(:runner, &FlowRunner.put_summary(&1, step.id, summary))
      |> Map.merge(%{selected_ids: [], select_items: [], flow_chat_error: nil})
    end)
    |> advance_step()
  end

  defp regenerate_step(socket, %{node_id: node_id}) when is_atom(node_id) do
    flow = socket.assigns.active_flow

    if Enum.any?(flow.flow_mod.steps(), &(&1.id == node_id)) do
      socket
      |> update_flow(fn flow ->
        %{
          flow
          | runner: FlowRunner.advance(flow.runner, node_id),
            completed_steps: flow.completed_steps -- [node_id, flow.runner.node_id],
            status: :running,
            step_status: :idle,
            step_error: nil,
            flow_chat_error: nil
        }
      end)
      |> run_action()
    else
      append_error(socket, "That step is not available in this flow.")
    end
  end

  defp regenerate_step(socket, _), do: append_error(socket, "That step cannot be regenerated.")

  defp focus_table(socket, %Message{artifact: %{kind: :table, table_name: table_name}})
       when is_binary(table_name) and table_name != "" do
    sid = socket.assigns[:session_id]
    _ = DataTable.set_active_table(sid, table_name)

    socket
    |> refresh_data_table(table_name)
    |> update_flow(&%{&1 | flow_chat_error: nil})
  end

  defp focus_table(socket, _message), do: socket

  defp maybe_auto_run(socket) do
    case current_node(socket) do
      nil ->
        update_flow(socket, &%{&1 | status: :done, step_status: :completed})

      %{type: :action, config: %{manual: true}} ->
        update_flow(socket, &%{&1 | status: :awaiting_user})

      %{type: :action} ->
        run_action(socket)

      %{type: :table_review} = step ->
        table_name = review_table_name(step, socket.assigns.active_flow.runner)

        socket
        |> refresh_data_table(table_name)
        |> update_flow(&%{&1 | status: :awaiting_user})

      %{type: :select} ->
        load_select_options(socket)

      _ ->
        update_flow(socket, &%{&1 | status: :awaiting_user})
    end
  end

  defp run_action(socket) do
    flow = socket.assigns.active_flow
    node = FlowRunner.current_node(flow.runner)

    cond do
      is_nil(node) ->
        socket

      long_running_use_case?(Map.get(node, :use_case)) ->
        spawn_long_step(socket, node, flow.runner, flow.scope)

      true ->
        run_action_via_runner(socket, node, flow.runner, flow.scope)
    end
  end

  defp run_action_via_runner(socket, node, runner, scope) do
    case FlowRunner.run_node(node, runner, scope) do
      {:ok, summary} ->
        socket
        |> update_flow(fn flow ->
          flow
          |> Map.update!(:runner, &FlowRunner.put_summary(&1, node.id, summary))
          |> Map.merge(%{status: :awaiting_user, step_status: :completed, step_error: nil})
        end)
        |> maybe_refresh_table_from_summary(summary)

      :ok ->
        update_flow(socket, fn flow ->
          %{flow | status: :awaiting_user, step_status: :completed, step_error: nil}
        end)

      {:async, _} ->
        update_flow(socket, fn flow ->
          %{flow | status: :running, step_status: :running, step_error: nil}
        end)

      {:error, reason} ->
        update_flow(socket, fn flow ->
          %{flow | status: :failed, step_status: :failed, step_error: inspect(reason)}
        end)
    end
  end

  defp load_select_options(socket) do
    flow = socket.assigns.active_flow
    node = FlowRunner.current_node(flow.runner)
    socket = update_flow(socket, &%{&1 | step_status: :loading, status: :running})

    case FlowRunner.run_node(node, flow.runner, flow.scope) do
      {:ok, %{matches: [], skip_reason: reason}} when is_binary(reason) ->
        summary = %{matches: [], selected: [], skip_reason: reason}

        socket
        |> update_flow(fn flow ->
          flow
          |> Map.update!(:runner, &FlowRunner.put_summary(&1, node.id, summary))
          |> Map.merge(%{select_items: [], selected_ids: []})
        end)
        |> advance_step()
        |> maybe_auto_run()

      {:ok, %{matches: matches}} ->
        selected_ids = initial_selected_ids(node, flow.runner, matches)

        update_flow(socket, fn flow ->
          %{
            flow
            | select_items: matches,
              selected_ids: selected_ids,
              step_status: :idle,
              status: :awaiting_user
          }
        end)

      {:error, reason} ->
        update_flow(socket, fn flow ->
          %{flow | status: :failed, step_status: :failed, step_error: inspect(reason)}
        end)
    end
  end

  defp spawn_long_step(socket, node, runner, scope) do
    input = runner.flow_mod.build_input(node.id, runner, scope)
    parent = self()
    node_id = node.id
    use_case = Map.fetch!(node, :use_case)

    long_step_spawn_fn().(fn ->
      case use_case.run(input, scope) do
        {:ok, summary} -> send(parent, {:flow_long_step_completed, node_id, summary})
        {:error, reason} -> send(parent, {:flow_long_step_failed, node_id, reason})
      end
    end)

    update_flow(socket, fn flow ->
      %{flow | status: :running, step_status: :running, step_error: nil}
    end)
  end

  defp long_step_spawn_fn do
    Application.get_env(:rho_web, :flow_long_step_spawn_fn, fn fun ->
      Task.Supervisor.start_child(Rho.TaskSupervisor, fun)
    end)
  end

  defp long_running_use_case?(use_case) do
    use_case in [
      GenerateFrameworkSkeletons,
      GenerateFrameworkTaxonomy,
      GenerateSkillsForTaxonomy,
      ResearchDomain
    ]
  end

  defp advance_step(socket) do
    flow = socket.assigns.active_flow
    node = FlowRunner.current_node(flow.runner)

    case FlowRunner.choose_next(flow.flow_mod, node, flow.runner, Deterministic) do
      {:ok, next_id, _decision} ->
        runner =
          flow.runner
          |> FlowRunner.advance(next_id)
          |> populate_intake(next_id, flow.scope)

        {runner, skipped_steps} = skip_prefilled_intake_steps(runner, flow.scope, [])

        update_flow(socket, fn flow ->
          %{
            flow
            | runner: runner,
              completed_steps: Enum.uniq([node.id | skipped_steps ++ flow.completed_steps]),
              status: :awaiting_user,
              step_status: :idle,
              step_error: nil,
              flow_chat_error: nil
          }
        end)

      {:error, reason} ->
        Logger.error("[AppLive.FlowSession] choose_next failed: #{inspect(reason)}")

        update_flow(socket, fn flow ->
          %{
            flow
            | status: :failed,
              step_status: :failed,
              step_error: "routing failed: #{inspect(reason)}"
          }
        end)
    end
  end

  defp skip_prefilled_intake_steps(runner, scope, skipped_steps) do
    node = FlowRunner.current_node(runner)

    if prefilled_intake_step?(node, runner) do
      case FlowRunner.choose_next(runner.flow_mod, node, runner, Deterministic) do
        {:ok, next_id, _decision} ->
          runner =
            runner
            |> FlowRunner.advance(next_id)
            |> populate_intake(next_id, scope)

          skip_prefilled_intake_steps(runner, scope, [node.id | skipped_steps])

        {:error, _reason} ->
          {runner, Enum.reverse(skipped_steps)}
      end
    else
      {runner, Enum.reverse(skipped_steps)}
    end
  end

  defp prefilled_intake_step?(
         %{id: id, type: :form, config: %{fields: fields}},
         %{intake: intake}
       )
       when id in [:intake_scratch, :intake_template, :intake_extend, :intake_merge] do
    required_fields =
      fields
      |> Enum.filter(&Map.get(&1, :required))
      |> Enum.map(&Map.fetch!(&1, :name))

    required_fields != [] and
      Enum.all?(required_fields, fn field ->
        case Rho.MapAccess.get(intake, field) do
          value when is_binary(value) -> String.trim(value) != ""
          nil -> false
          _value -> true
        end
      end)
  end

  defp prefilled_intake_step?(_node, _runner), do: false

  defp populate_intake(runner, _next_id, nil), do: runner

  defp populate_intake(%{flow_mod: flow_mod} = runner, next_id, scope) do
    if function_exported?(flow_mod, :populate_intake, 3) do
      defaults = flow_mod.populate_intake(next_id, runner, scope)

      if is_map(defaults) do
        new_only =
          defaults
          |> Enum.reject(fn {key, _value} -> Map.has_key?(runner.intake, key) end)
          |> Map.new()

        FlowRunner.merge_intake(runner, new_only)
      else
        runner
      end
    else
      runner
    end
  end

  defp append_current_card(socket) do
    case current_message(socket) do
      nil ->
        socket

      %Message{} = flow_message ->
        {message_id, socket} = next_message_id(socket, "flow")
        active_flow = %{socket.assigns.active_flow | current_message_id: message_id}
        socket = assign(socket, :active_flow, active_flow)

        msg = %{
          id: message_id,
          role: :assistant,
          type: :flow_card,
          agent_id: active_agent_id(socket),
          content: flow_message.body,
          flow: flow_message,
          flow_status: flow_card_status(active_flow),
          flow_error: active_flow.flow_chat_error || active_flow.step_error
        }

        socket
        |> mark_flow_cards_past(active_flow.id)
        |> SignalRouter.append_message(msg)
    end
  end

  defp flow_card_status(%{status: :failed}), do: :error
  defp flow_card_status(%{runner: %{node_id: :done}}), do: :done
  defp flow_card_status(_), do: :active

  defp mark_flow_cards_past(socket, flow_id) do
    updated =
      Map.new(socket.assigns.agent_messages, fn {agent_id, messages} ->
        {agent_id,
         Enum.map(messages, fn
           %{type: :flow_card, flow: %{flow_id: ^flow_id}} = msg ->
             Map.put(msg, :flow_status, :past)

           msg ->
             msg
         end)}
      end)

    assign(socket, :agent_messages, updated)
  end

  defp record_choice(socket, %Message{} = prompt, result) do
    if result[:reply] do
      socket
    else
      body = choice_body(prompt, result)

      choice = %{
        id: "flow_choice_#{System.unique_integer([:positive])}",
        role: :user,
        type: :text,
        agent_id: active_agent_id(socket),
        content: body,
        flow_choice?: true,
        flow_id: prompt.flow_id,
        flow_node_id: prompt.node_id
      }

      SignalRouter.append_message(socket, choice)
    end
  end

  defp choice_body(%Message{actions: actions} = prompt, result) do
    case Enum.find(actions, &(&1.id == result[:action_id])) do
      %{label: label} ->
        label

      _ ->
        if result[:event] == :submit_form,
          do: submitted_choice_body(prompt, result),
          else: "Continued"
    end
  end

  defp submitted_choice_body(%Message{fields: fields}, %{payload: payload})
       when is_map(payload) do
    payload
    |> Enum.reject(fn {_key, value} -> is_nil(value) or to_string(value) == "" end)
    |> Enum.map_join("\n", fn {key, value} ->
      field = Enum.find(fields, &(to_string(&1.name) == to_string(key)))
      label = if field, do: field.label, else: humanize_key(key)
      "#{label}: #{display_field_value(field, value)}"
    end)
    |> case do
      "" -> "Submitted"
      text -> text
    end
  end

  defp submitted_choice_body(_prompt, _), do: "Submitted"

  defp display_field_value(%{type: :select, options: options}, value) when is_list(options) do
    value_string = to_string(value)

    case Enum.find(options, fn {_label, option_value} ->
           to_string(option_value) == value_string
         end) do
      {label, _option_value} -> label
      nil -> value_string
    end
  end

  defp display_field_value(_field, value), do: value

  defp update_current_card_fields(socket, %Message{} = message, payload) when is_map(payload) do
    current_message_id = socket.assigns.active_flow.current_message_id

    updated =
      Map.new(socket.assigns.agent_messages, fn {agent_id, messages} ->
        {agent_id,
         Enum.map(messages, fn
           %{id: ^current_message_id, type: :flow_card, flow: %Message{} = flow} = msg ->
             updated_flow = %{flow | fields: submitted_fields(message.fields, payload)}

             msg
             |> Map.put(:flow, updated_flow)
             |> Map.put(:content, updated_flow.body)
             |> Map.put(:flow_error, nil)

           msg ->
             msg
         end)}
      end)

    assign(socket, :agent_messages, updated)
  end

  defp replace_current_card(socket) do
    current_message_id = socket.assigns.active_flow.current_message_id
    flow_message = current_message(socket)
    active_flow = socket.assigns.active_flow

    updated =
      Map.new(socket.assigns.agent_messages, fn {agent_id, messages} ->
        {agent_id,
         Enum.map(messages, fn
           %{id: ^current_message_id, type: :flow_card} = msg ->
             %{
               msg
               | content: flow_message.body,
                 flow: flow_message,
                 flow_status: flow_card_status(active_flow),
                 flow_error: active_flow.flow_chat_error || active_flow.step_error
             }

           msg ->
             msg
         end)}
      end)

    assign(socket, :agent_messages, updated)
  end

  defp submitted_fields(fields, payload) do
    Enum.map(fields, fn field ->
      Map.put(field, :value, payload_value(payload, field.name) || field[:value])
    end)
  end

  defp payload_value(payload, key) do
    Map.get(payload, key) || Map.get(payload, to_string(key))
  end

  defp humanize_key(key) do
    key
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp append_user_message(socket, text) do
    {message_id, socket} = next_message_id(socket, "user")

    msg = %{
      id: message_id,
      role: :user,
      type: :text,
      content: text,
      agent_id: active_agent_id(socket)
    }

    SignalRouter.append_message(socket, msg)
  end

  defp append_error(socket, error) do
    socket
    |> update_flow(&%{&1 | status: :failed, flow_chat_error: error})
    |> append_current_card()
  end

  defp current_message(%{assigns: %{active_flow: flow}}) when is_map(flow) do
    opts = [
      selected_ids: flow.selected_ids,
      select_items: flow.select_items,
      step_status: flow.step_status
    ]

    opts =
      case FlowRunner.current_node(flow.runner) do
        %{type: :table_review} = step ->
          Keyword.put(opts, :table_name, review_table_name(step, flow.runner))

        _ ->
          opts
      end

    StepPresenter.present(flow.flow_mod, flow.runner, opts)
  end

  defp current_message(_socket), do: nil

  defp current_node(socket), do: FlowRunner.current_node(socket.assigns.active_flow.runner)

  defp stale_safe?(%Message{node_id: node_id}, node) do
    to_string(node_id) == to_string(node)
  end

  defp update_flow(socket, fun) when is_function(fun, 1) do
    assign(socket, :active_flow, fun.(socket.assigns.active_flow))
  end

  defp refresh_data_table(socket, table_name) when is_binary(table_name) and table_name != "" do
    sid = socket.assigns[:session_id]
    _ = DataTable.set_active_table(sid, table_name)
    DataTableEvents.publish_view_focus(sid, table_name)

    socket =
      socket
      |> DataTableEvents.open_workspace()
      |> DataTableEvents.refresh_session()

    state =
      socket
      |> DataTableEvents.read_state()
      |> Map.merge(%{
        active_table: table_name,
        view_key: nil,
        mode_label: nil,
        error: nil
      })

    socket
    |> SignalRouter.write_ws_state(:data_table, state)
    |> WorkbenchDisplayState.put_table(table_name)
    |> DataTableEvents.refresh_active(table_name)
  end

  defp refresh_data_table(socket, _), do: socket

  defp maybe_refresh_table_from_summary(socket, %{table_name: table_name})
       when is_binary(table_name),
       do: refresh_data_table(socket, table_name)

  defp maybe_refresh_table_from_summary(socket, _), do: socket

  defp ensure_chat_session(socket) do
    if sid = socket.assigns[:session_id] do
      {sid, socket}
    else
      ensure_opts = AppLive.session_ensure_opts(socket.assigns[:live_action])
      {sid, socket} = SessionCore.ensure_session(socket, nil, ensure_opts)
      socket = SessionCore.subscribe_and_hydrate(socket, sid, ensure_opts)
      {sid, AppLive.maybe_push_new_session_patch(socket, sid, true)}
    end
  end

  defp maybe_push_chat(socket, sid) do
    if socket.assigns[:active_page] in [:chat, :chat_show] do
      socket
    else
      case socket.assigns[:current_organization] do
        %{slug: slug} when is_binary(slug) -> push_patch(socket, to: "/orgs/#{slug}/chat/#{sid}")
        _ -> socket
      end
    end
  end

  defp ensure_data_table(sid) do
    case DataTable.ensure_started(sid) do
      {:ok, _pid} -> :ok
      _ -> :ok
    end
  end

  defp next_message_id(socket, prefix) do
    next_id = (socket.assigns[:next_id] || 1) + 1
    {"#{prefix}_#{next_id}", assign(socket, :next_id, next_id)}
  end

  defp active_agent_id(socket) do
    socket.assigns[:active_agent_id] ||
      (socket.assigns[:session_id] && Rho.Agent.Primary.agent_id(socket.assigns.session_id))
  end

  defp current_user_id(socket) do
    case socket.assigns[:current_user] do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp normalize_intake(payload) when is_map(payload) do
    Map.new(payload, fn
      {key, value} when is_binary(key) -> {safe_existing_atom(key), value}
      pair -> pair
    end)
  end

  defp safe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp initial_selected_ids(%{id: :pick_existing_library}, runner, matches) do
    case Map.get(runner.intake, :library_id) do
      id when is_binary(id) and id != "" ->
        if Enum.any?(matches, fn match -> item_id(match) == id end), do: [id], else: []

      _ ->
        []
    end
  end

  defp initial_selected_ids(%{id: :pick_two_libraries}, runner, matches) do
    id_a = Map.get(runner.intake, :library_id_a)
    id_b = Map.get(runner.intake, :library_id_b)

    with true <- is_binary(id_a) and id_a != "",
         true <- is_binary(id_b) and id_b != "",
         true <- id_a != id_b,
         true <- Enum.any?(matches, fn match -> item_id(match) == id_a end),
         true <- Enum.any?(matches, fn match -> item_id(match) == id_b end) do
      [id_a, id_b]
    else
      _ -> []
    end
  end

  defp initial_selected_ids(_node, _runner, _matches), do: []

  defp item_id(item) do
    to_string(Rho.MapAccess.get(item, :id) || :erlang.phash2(item))
  end

  defp flow_table_name(%{summaries: summaries, intake: intake}) do
    case get_in(summaries, [:generate_skills, :table_name]) ||
           get_in(summaries, [:generate, :table_name]) ||
           get_in(summaries, [:pick_template, :table_name]) ||
           get_in(summaries, [:load_existing_library, :table_name]) ||
           get_in(summaries, [:merge_frameworks, :table_name]) do
      name when is_binary(name) and name != "" ->
        name

      _ ->
        case Rho.MapAccess.get(intake, :name) do
          name when is_binary(name) and name != "" ->
            RhoFrameworks.Library.Editor.table_name(name)

          _ ->
            ""
        end
    end
  end

  defp review_table_name(%{config: %{table_summary_key: summary_key} = config}, runner)
       when is_atom(summary_key) do
    field = Map.get(config, :table_field, :table_name)

    case get_in(runner.summaries, [summary_key, field]) do
      name when is_binary(name) and name != "" -> name
      _ -> flow_table_name(runner)
    end
  end

  defp review_table_name(_step, runner), do: flow_table_name(runner)

  defp long_step_current?(socket, node_id) do
    case socket.assigns[:active_flow] do
      %{runner: %{node_id: ^node_id}, step_status: :running} -> true
      _ -> false
    end
  end
end
