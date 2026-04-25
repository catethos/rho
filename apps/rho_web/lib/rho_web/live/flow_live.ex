defmodule RhoWeb.FlowLive do
  @moduledoc """
  Step-by-step wizard LiveView that drives flows through composable primitives.

  Mounted at `/orgs/:slug/flows/:flow_id`. Creates its own DataTable session
  so state can be shared with the agent chat in future phases.
  """
  use Phoenix.LiveView

  require Logger

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.DataTableSchemas
  alias RhoFrameworks.Flows.Registry, as: FlowRegistry
  alias RhoFrameworks.Scope
  alias RhoWeb.FlowComponents
  alias RhoWeb.LiveEvents.Event, as: LiveEvent

  import FlowComponents

  # -------------------------------------------------------------------
  # Mount
  # -------------------------------------------------------------------

  @impl true
  def mount(%{"flow_id" => flow_id} = _params, _session, socket) do
    case FlowRegistry.get(flow_id) do
      {:ok, flow_mod} ->
        if connected?(socket) do
          {:ok, boot_flow(socket, flow_mod)}
        else
          {:ok, assign_static(socket, flow_mod)}
        end

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "Unknown flow: #{flow_id}")
         |> redirect(to: org_path(socket, "/libraries"))}
    end
  end

  defp assign_static(socket, flow_mod) do
    steps = flow_mod.steps()

    socket
    |> assign(:flow_module, flow_mod)
    |> assign(:flow_steps, steps)
    |> assign(:current_step, hd(steps).id)
    |> assign(:completed_steps, [])
    |> assign(:step_status, :idle)
    |> assign(:step_results, %{})
    |> assign(:step_error, nil)
    |> assign(:workers, [])
    |> assign(:dt_snapshot, [])
    |> assign(:dt_schema, nil)
    |> assign(:form, %{})
    |> assign(:session_id, nil)
    |> assign(:scope, nil)
    |> assign(:page_title, flow_mod.label())
    |> assign(:generate_agent_id, nil)
    |> assign(:streaming_text, "")
    |> assign(:tool_events, [])
    |> assign(:select_items, [])
    |> assign(:selected_ids, [])
  end

  defp boot_flow(socket, flow_mod) do
    org = socket.assigns.current_organization
    session_id = "flow_#{System.unique_integer([:positive])}"

    DataTable.ensure_started(session_id)
    DataTable.ensure_table(session_id, "flow:state", DataTableSchemas.flow_state_schema())

    scope = %Scope{
      organization_id: org.id,
      session_id: session_id,
      user_id: socket.assigns.current_user.id
    }

    RhoWeb.LiveEvents.subscribe(session_id)

    socket
    |> assign_static(flow_mod)
    |> assign(:session_id, session_id)
    |> assign(:scope, scope)
  end

  # -------------------------------------------------------------------
  # Render
  # -------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flow-container">
      <div class="flow-header">
        <h1 class="flow-title"><%= @flow_module.label() %></h1>
      </div>

      <.step_indicator
        steps={@flow_steps}
        current_step={@current_step}
        completed_steps={@completed_steps}
      />

      <div class="flow-step-content">
        <%= render_current_step(assigns) %>
      </div>
    </div>
    """
  end

  defp render_current_step(assigns) do
    step = current_step_def(assigns)
    assigns = assign(assigns, :step_def, step)

    case step.type do
      :form ->
        ~H"""
        <.form_step fields={@step_def.config.fields} form={@form} step_id={@step_def.id} />
        """

      :action ->
        if step.config[:manual] == true and assigns.step_status == :idle do
          ~H"""
          <.confirm_step
            message={@step_def.config[:message] || "Ready to continue?"}
            step_label={@step_def.label}
          />
          """
        else
          ~H"""
          <.action_step
            step_status={@step_status}
            step_label={@step_def.label}
            step_error={@step_error}
            streaming_text={@streaming_text}
            tool_events={@tool_events}
          />
          """
        end

      :table_review ->
        ~H"""
        <.table_review_step
          dt_snapshot={@dt_snapshot}
          dt_schema={@dt_schema}
          session_id={@session_id}
          table_name={flow_table_name(@step_results)}
        />
        """

      :fan_out ->
        ~H"""
        <.fan_out_step workers={@workers} step_status={@step_status} />
        """

      :select ->
        ~H"""
        <.select_step
          items={@select_items}
          selected={@selected_ids}
          display_fields={@step_def.config[:display_fields] || %{}}
          step_status={@step_status}
          skippable={@step_def.config[:skippable] != false}
        />
        """
    end
  end

  # -------------------------------------------------------------------
  # Events
  # -------------------------------------------------------------------

  @impl true
  def handle_event("submit_form", params, socket) do
    step = current_step_def(socket.assigns)

    form_data =
      step.config.fields
      |> Enum.map(fn f -> {f.name, params[to_string(f.name)] || ""} end)
      |> Map.new()

    socket =
      socket
      |> assign(:step_results, Map.put(socket.assigns.step_results, step.id, form_data))
      |> advance_step()

    {:noreply, maybe_auto_run(socket)}
  end

  def handle_event("continue", _params, socket) do
    {:noreply, socket |> advance_step() |> maybe_auto_run()}
  end

  def handle_event("start_fan_out", _params, socket) do
    {:noreply, run_fan_out(socket)}
  end

  def handle_event("retry_step", _params, socket) do
    {:noreply, run_action(socket)}
  end

  def handle_event("toggle_selection", %{"id" => id}, socket) do
    selected = socket.assigns.selected_ids

    updated =
      if id in selected,
        do: List.delete(selected, id),
        else: [id | selected]

    {:noreply, assign(socket, :selected_ids, updated)}
  end

  def handle_event("confirm_selection", _params, socket) do
    items = socket.assigns.select_items
    selected_ids = socket.assigns.selected_ids
    selected = Enum.filter(items, fn i -> item_id(i) in selected_ids end)
    step = current_step_def(socket.assigns)

    socket =
      socket
      |> assign(:step_results, Map.put(socket.assigns.step_results, step.id, selected))
      |> reset_select_state()
      |> advance_step()

    {:noreply, maybe_auto_run(socket)}
  end

  def handle_event("skip_select", _params, socket) do
    step = current_step_def(socket.assigns)

    socket =
      socket
      |> assign(:step_results, Map.put(socket.assigns.step_results, step.id, []))
      |> reset_select_state()
      |> advance_step()

    {:noreply, maybe_auto_run(socket)}
  end

  def handle_event("confirm_manual", _params, socket) do
    {:noreply, socket |> advance_step() |> maybe_auto_run()}
  end

  # -------------------------------------------------------------------
  # handle_info — LiveEvents
  # -------------------------------------------------------------------

  @impl true
  def handle_info(%LiveEvent{kind: kind, data: data}, socket) do
    case kind do
      k when k in [:text_delta, :llm_text, :structured_partial] ->
        {:noreply, handle_text_delta(socket, data)}

      :tool_start ->
        {:noreply, handle_tool_event(socket, :start, data)}

      :tool_result ->
        {:noreply, handle_tool_event(socket, :result, data)}

      :data_table ->
        {:noreply, handle_data_table_event(socket, data)}

      :task_completed ->
        {:noreply, handle_worker_completed(socket, data)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # -------------------------------------------------------------------
  # Terminate — clean up subscriptions
  # -------------------------------------------------------------------

  @impl true
  def terminate(_reason, socket) do
    if sid = socket.assigns[:session_id] do
      RhoWeb.LiveEvents.unsubscribe(sid)
    end

    :ok
  end

  # -------------------------------------------------------------------
  # Streaming text
  # -------------------------------------------------------------------

  defp handle_text_delta(socket, data) do
    text = data[:text] || ""

    if text != "" and socket.assigns.step_status == :running do
      assign(socket, :streaming_text, socket.assigns.streaming_text <> text)
    else
      socket
    end
  end

  defp handle_tool_event(socket, phase, data) do
    if socket.assigns.step_status == :running do
      event = %{
        phase: phase,
        name: data[:name],
        status: data[:status],
        output: if(phase == :result, do: truncate(data[:output], 200), else: nil)
      }

      assign(socket, :tool_events, socket.assigns.tool_events ++ [event])
    else
      socket
    end
  end

  defp truncate(nil, _), do: nil
  defp truncate(s, max) when byte_size(s) <= max, do: s
  defp truncate(s, max), do: String.slice(s, 0, max) <> "..."

  # -------------------------------------------------------------------
  # DataTable events
  # -------------------------------------------------------------------

  defp handle_data_table_event(socket, data) do
    case data[:event] do
      event when event in [:table_changed, :table_created] ->
        # Refresh from the table that changed, or derive from intake
        tbl = data[:table_name] || flow_table_name(socket.assigns.step_results)
        refresh_data_table(socket, tbl)

      _ ->
        socket
    end
  end

  # -------------------------------------------------------------------
  # Step machine
  # -------------------------------------------------------------------

  defp current_step_def(assigns) do
    Enum.find(assigns.flow_steps, fn s -> s.id == assigns.current_step end)
  end

  defp advance_step(socket) do
    steps = socket.assigns.flow_steps
    current = socket.assigns.current_step
    completed = [current | socket.assigns.completed_steps] |> Enum.uniq()

    case next_step(steps, current) do
      nil ->
        assign(socket, :completed_steps, completed)

      next ->
        socket
        |> assign(:current_step, next.id)
        |> assign(:completed_steps, completed)
        |> assign(:step_status, :idle)
        |> assign(:step_error, nil)
        |> assign(:streaming_text, "")
        |> assign(:tool_events, [])
    end
  end

  defp next_step(steps, current_id) do
    idx = Enum.find_index(steps, fn s -> s.id == current_id end)

    if idx && idx + 1 < length(steps) do
      Enum.at(steps, idx + 1)
    end
  end

  defp maybe_auto_run(socket) do
    step = current_step_def(socket.assigns)

    case step.type do
      :action ->
        if step.config[:manual] == true, do: socket, else: run_action(socket)

      :table_review ->
        refresh_data_table(socket)

      :select ->
        load_select_options(socket)

      _ ->
        socket
    end
  end

  # -------------------------------------------------------------------
  # Action execution
  # -------------------------------------------------------------------

  defp run_action(socket) do
    step = current_step_def(socket.assigns)
    {mod, fun, extra} = step.run
    params = build_step_params(step, socket.assigns)
    scope = socket.assigns.scope

    case apply(mod, fun, [params, scope | extra]) do
      # Async worker (e.g. SkeletonGenerator) — track via Comms signals
      {:ok, %{agent_id: agent_id}} ->
        socket
        |> assign(:step_status, :running)
        |> assign(:step_error, nil)
        |> assign(:streaming_text, "")
        |> assign(:tool_events, [])
        |> assign(:generate_agent_id, agent_id)

      # Sync success — store result immediately
      {:ok, result} ->
        socket
        |> store_step_result(result)
        |> assign(:step_status, :completed)
        |> assign(:step_error, nil)
        |> maybe_refresh_table(result)

      {:error, reason} ->
        socket
        |> assign(:step_status, :failed)
        |> assign(:step_error, inspect(reason))
    end
  end

  defp run_fan_out(socket) do
    step = current_step_def(socket.assigns)
    {mod, fun, extra} = step.run
    params = build_step_params(step, socket.assigns)
    scope = socket.assigns.scope

    case apply(mod, fun, [params, scope | extra]) do
      {:ok, %{workers: workers}} ->
        worker_assigns =
          Enum.map(workers, fn w ->
            %{
              agent_id: w.agent_id,
              category: w.category,
              count: w.count,
              status: :running
            }
          end)

        socket
        |> assign(:workers, worker_assigns)
        |> assign(:step_status, :running)

      {:error, reason} ->
        socket
        |> assign(:step_status, :failed)
        |> assign(:step_error, inspect(reason))
    end
  end

  # -------------------------------------------------------------------
  # Param building per step
  # -------------------------------------------------------------------

  defp build_step_params(step, assigns) do
    results = assigns.step_results
    intake = results[:intake] || %{}
    gen = results[:generate] || %{}

    case step.id do
      :generate ->
        similar_roles = results[:similar_roles] || []

        %{
          name: intake[:name] || "",
          description: intake[:description] || "",
          domain: intake[:domain] || "",
          target_roles: intake[:target_roles] || "",
          skill_count: intake[:skill_count] || "12",
          similar_role_skills: format_seed_skills(similar_roles)
        }

      :proficiency ->
        table_name = gen[:table_name] || derive_table_name(intake)
        levels = parse_levels(intake[:levels])
        %{table_name: table_name, levels: levels}

      :save ->
        table_name = gen[:table_name] || derive_table_name(intake)

        library =
          gen[:library] ||
            find_library_by_name(assigns.scope.organization_id, intake[:name] || "")

        library_id = if is_struct(library), do: library.id, else: library && library[:id]
        %{library_id: library_id, table_name: table_name}

      _ ->
        %{}
    end
  end

  defp parse_levels(nil), do: 5
  defp parse_levels(v) when is_integer(v), do: v

  defp parse_levels(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> 5
    end
  end

  defp parse_levels(_), do: 5

  defp format_seed_skills([]), do: nil

  defp format_seed_skills(roles) when is_list(roles) do
    roles
    |> Enum.map_join("\n", fn role ->
      name = role[:name] || role["name"] || "Unknown"
      family = role[:role_family] || role["role_family"] || ""
      count = role[:skill_count] || role["skill_count"] || 0
      "- #{name} (#{family}, #{count} skills)"
    end)
  end

  defp derive_table_name(intake) do
    name = intake[:name] || ""
    if name != "", do: RhoFrameworks.Library.Editor.table_name(name), else: ""
  end

  # -------------------------------------------------------------------
  # Result storage + table refresh
  # -------------------------------------------------------------------

  defp store_step_result(socket, result) do
    step = current_step_def(socket.assigns)
    assign(socket, :step_results, Map.put(socket.assigns.step_results, step.id, result))
  end

  defp maybe_refresh_table(socket, result) do
    if is_map(result) and Map.has_key?(result, :table_name) do
      refresh_data_table(socket, result[:table_name])
    else
      socket
    end
  end

  defp refresh_data_table(socket, table_name \\ nil) do
    tbl = table_name || flow_table_name(socket.assigns.step_results)
    sid = socket.assigns.session_id

    if sid && tbl != "" do
      case DataTable.get_table_snapshot(sid, tbl) do
        {:ok, snapshot} ->
          web_schema = RhoWeb.DataTable.Schemas.resolve(nil, tbl)

          socket
          |> assign(:dt_snapshot, snapshot[:rows] || [])
          |> assign(:dt_schema, web_schema)

        _ ->
          socket
      end
    else
      socket
    end
  end

  # -------------------------------------------------------------------
  # Worker tracking
  # -------------------------------------------------------------------

  defp handle_worker_completed(socket, data) do
    # Signal data may arrive with atom or string keys depending on code path
    agent_id =
      data[:worker_agent_id] || data["worker_agent_id"] ||
        data[:agent_id] || data["agent_id"]

    generate_id = socket.assigns[:generate_agent_id]

    cond do
      # Generate step worker completed — exact agent_id match
      generate_id != nil and generate_id == agent_id ->
        Logger.debug("[FlowLive] generate completed via agent_id match: #{agent_id}")
        complete_generate_step(socket)

      # Fan-out workers
      socket.assigns.workers != [] ->
        mark_worker_completed(socket, agent_id)

      true ->
        Logger.debug(
          "[FlowLive] unmatched task.completed: agent_id=#{inspect(agent_id)} " <>
            "generate_agent_id=#{inspect(generate_id)} workers=#{length(socket.assigns.workers)}"
        )

        socket
    end
  end

  defp mark_worker_completed(socket, agent_id) do
    updated =
      Enum.map(socket.assigns.workers, fn w ->
        if w.agent_id == agent_id, do: %{w | status: :completed}, else: w
      end)

    socket = assign(socket, :workers, updated)

    if Enum.all?(updated, fn w -> w.status == :completed end) do
      socket
      |> assign(:step_status, :completed)
      |> refresh_data_table()
    else
      socket
    end
  end

  defp complete_generate_step(socket) do
    intake = socket.assigns.step_results[:intake] || %{}
    lib_name = intake[:name] || ""
    table_name = RhoFrameworks.Library.Editor.table_name(lib_name)

    org_id = socket.assigns.scope.organization_id
    library = find_library_by_name(org_id, lib_name)

    result = %{table_name: table_name, library: library}

    socket
    |> store_step_result(result)
    |> assign(:step_status, :completed)
    |> assign(:generate_agent_id, nil)
    |> refresh_data_table(table_name)
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  # -------------------------------------------------------------------
  # Select step loading
  # -------------------------------------------------------------------

  defp load_select_options(socket) do
    step = current_step_def(socket.assigns)
    {mod, fun, extra} = step.config[:load]
    params = build_select_params(socket.assigns)
    scope = socket.assigns.scope

    socket = assign(socket, :step_status, :loading)

    case apply(mod, fun, [params, scope | extra]) do
      {:ok, items} ->
        socket
        |> assign(:select_items, items)
        |> assign(:selected_ids, [])
        |> assign(:step_status, :idle)

      {:skip, reason} ->
        socket
        |> put_flash(:info, reason)
        |> assign(:step_results, Map.put(socket.assigns.step_results, step.id, []))
        |> reset_select_state()
        |> advance_step()
        |> maybe_auto_run()
    end
  end

  defp build_select_params(assigns) do
    intake = assigns.step_results[:intake] || %{}

    %{
      name: intake[:name] || "",
      description: intake[:description] || "",
      domain: intake[:domain] || "",
      target_roles: intake[:target_roles] || ""
    }
  end

  defp reset_select_state(socket) do
    socket
    |> assign(:select_items, [])
    |> assign(:selected_ids, [])
  end

  defp item_id(item) do
    to_string(item[:id] || item["id"] || :erlang.phash2(item))
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp find_library_by_name(org_id, name) do
    RhoFrameworks.Library.get_library_by_name(org_id, name)
  end

  defp flow_table_name(step_results) do
    case get_in(step_results, [:generate, :table_name]) do
      name when is_binary(name) and name != "" -> name
      _ -> derive_table_name(step_results[:intake] || %{})
    end
  end

  defp org_path(socket, suffix) do
    slug = socket.assigns.current_organization.slug
    "/orgs/#{slug}#{suffix}"
  end
end
