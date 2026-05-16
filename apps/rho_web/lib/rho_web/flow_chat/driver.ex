defmodule RhoWeb.FlowChat.Driver do
  @moduledoc """
  Applies chat-native flow actions to a `FlowRunner`-backed LiveView socket.

  `FlowLive` owns the page shell and side effects such as running steps,
  refreshing tables, and advancing the current node. This module owns the
  chat-specific projection and result normalization so that chat behavior stays
  separate from the LiveView.
  """

  import Phoenix.Component, only: [assign: 3, update: 3]
  import Phoenix.LiveView, only: [clear_flash: 2, put_flash: 3]

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.FlowRunner
  alias RhoWeb.FlowChat.{Message, StepPresenter}

  @type ops :: %{
          advance_step: (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t()),
          maybe_auto_run: (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t()),
          reset_select_state: (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t()),
          run_action: (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t()),
          refresh_data_table: (Phoenix.LiveView.Socket.t(), String.t() ->
                                 Phoenix.LiveView.Socket.t()),
          review_table_name: (map(), FlowRunner.state() -> String.t()),
          item_id: (map() -> term())
        }

  @spec current_message(map(), ops()) :: Message.t() | nil
  def current_message(assigns, ops) when is_map(assigns) do
    step = FlowRunner.current_node(assigns.runner)

    opts = [
      selected_ids: Map.get(assigns, :selected_ids, []),
      select_items: Map.get(assigns, :select_items, []),
      step_status: Map.get(assigns, :step_status, :idle)
    ]

    opts =
      if step && step.type == :table_review do
        Keyword.put(opts, :table_name, ops.review_table_name.(step, assigns.runner))
      else
        opts
      end

    StepPresenter.present(assigns.flow_module, assigns.runner, opts)
  end

  @spec show_step_surface?(map(), Message.t()) :: boolean()
  def show_step_surface?(%{type: type}, %Message{}) when type in [:select, :table_review],
    do: true

  def show_step_surface?(%{type: :form}, %Message{actions: []}), do: true

  def show_step_surface?(%{type: :action}, %Message{meta: %{status: status}})
      when status in [:running, :completed, :failed],
      do: true

  def show_step_surface?(_step, _message), do: false

  @spec apply_result(Phoenix.LiveView.Socket.t(), Message.t(), map(), ops()) ::
          Phoenix.LiveView.Socket.t()
  def apply_result(socket, %Message{} = message, result, ops) do
    socket =
      socket
      |> record_choice(message, result)
      |> assign(:flow_chat_error, nil)

    case result[:event] do
      :submit_form ->
        payload = normalize_payload(result[:payload] || %{})

        socket
        |> update(:runner, &FlowRunner.merge_intake(&1, payload))
        |> call(ops.advance_step)
        |> call(ops.maybe_auto_run)

      :continue ->
        socket |> call(ops.advance_step) |> call(ops.maybe_auto_run)

      :confirm_selection ->
        confirm_selection(socket, ops)

      :skip_select ->
        skip_select(socket, ops)

      :confirm_manual ->
        confirm_manual(socket, ops)

      :run_action ->
        ops.run_action.(socket)

      :retry_step ->
        ops.run_action.(socket)

      :regenerate_step ->
        regenerate_step(socket, result[:payload] || %{}, ops)

      :focus_table ->
        focus_table(socket, message, ops)

      _ ->
        socket
    end
  end

  defp call(socket, fun), do: fun.(socket)

  defp normalize_payload(payload) when is_map(payload) do
    Map.new(payload, fn
      {key, value} when is_binary(key) -> {safe_payload_key(key), value}
      pair -> pair
    end)
  end

  defp safe_payload_key(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp record_choice(socket, %Message{} = prompt, result) do
    choice = %Message{
      kind: :flow_choice,
      flow_id: prompt.flow_id,
      node_id: prompt.node_id,
      title: prompt.title,
      body: result[:reply] || choice_body(prompt, result),
      meta: %{
        action_id: result[:action_id],
        payload: result[:payload],
        source: if(result[:reply], do: :natural_language, else: :structured_action)
      }
    }

    update(socket, :flow_chat_events, fn events -> events ++ [choice] end)
  end

  defp choice_body(%Message{actions: actions}, result) do
    action_id = result[:action_id]

    case Enum.find(actions, &(&1.id == action_id)) do
      %{label: label} -> label
      _ -> "Continued"
    end
  end

  defp confirm_selection(socket, ops) do
    step = FlowRunner.current_node(socket.assigns.runner)
    selected_count = length(socket.assigns.selected_ids)
    min_select = step.config[:min_select]
    max_select = step.config[:max_select]

    cond do
      is_integer(min_select) and selected_count < min_select ->
        put_flash(socket, :error, "Select at least #{min_select} to continue.")

      is_integer(max_select) and selected_count > max_select ->
        put_flash(socket, :error, "Select at most #{max_select} to continue.")

      true ->
        items = socket.assigns.select_items
        selected_ids = socket.assigns.selected_ids
        selected = Enum.filter(items, fn item -> ops.item_id.(item) in selected_ids end)
        summary = %{matches: items, selected: selected, skip_reason: nil}

        socket
        |> clear_flash(:error)
        |> update(:runner, &FlowRunner.put_summary(&1, step.id, summary))
        |> call(ops.reset_select_state)
        |> call(ops.advance_step)
        |> call(ops.maybe_auto_run)
    end
  end

  defp skip_select(socket, ops) do
    step = FlowRunner.current_node(socket.assigns.runner)
    summary = %{matches: [], selected: [], skip_reason: "user skipped"}

    socket
    |> update(:runner, &FlowRunner.put_summary(&1, step.id, summary))
    |> call(ops.reset_select_state)
    |> call(ops.advance_step)
    |> call(ops.maybe_auto_run)
  end

  defp confirm_manual(socket, ops) do
    step = FlowRunner.current_node(socket.assigns.runner)

    if step && Map.get(step, :use_case) do
      ops.run_action.(socket)
    else
      socket |> call(ops.advance_step) |> call(ops.maybe_auto_run)
    end
  end

  defp regenerate_step(socket, %{node_id: target_node_id}, ops) when is_atom(target_node_id) do
    runner = socket.assigns.runner

    case find_flow_node(runner.flow_mod, target_node_id) do
      nil ->
        assign(socket, :flow_chat_error, "That step is not available in this flow.")

      _node ->
        completed =
          socket.assigns.completed_steps
          |> List.delete(target_node_id)
          |> List.delete(runner.node_id)

        socket
        |> assign(:runner, FlowRunner.advance(runner, target_node_id))
        |> assign(:completed_steps, completed)
        |> assign(:step_status, :idle)
        |> assign(:step_error, nil)
        |> assign(:streaming_text, "")
        |> assign(:tool_events, [])
        |> call(ops.run_action)
    end
  end

  defp regenerate_step(socket, _payload, _ops),
    do: assign(socket, :flow_chat_error, "That step cannot be regenerated.")

  defp focus_table(socket, %Message{artifact: %{kind: :table, table_name: table_name}}, ops)
       when is_binary(table_name) and table_name != "" do
    if sid = socket.assigns[:session_id] do
      _ = DataTable.set_active_table(sid, table_name)
    end

    ops.refresh_data_table.(socket, table_name)
  end

  defp focus_table(socket, _message, _ops), do: socket

  defp find_flow_node(flow_mod, node_id) do
    Enum.find(flow_mod.steps(), fn node -> node.id == node_id end)
  end
end
