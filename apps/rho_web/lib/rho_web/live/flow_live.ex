defmodule RhoWeb.FlowLive do
  @moduledoc """
  Step-by-step wizard LiveView. Drives flows through `RhoFrameworks.FlowRunner`.

  The LV owns UI-only state (streaming text, tool events, workers list,
  select items, intake form scratch) and translates user events into
  runner state mutations + UseCase invocations. Anything table-shaped is
  read live from the Workbench, not held in socket assigns.
  """
  use Phoenix.LiveView

  require Logger

  alias Rho.Stdlib.DataTable
  alias Rho.Events.Event, as: LiveEvent
  alias RhoFrameworks.{AgentJobs, DataTableSchemas, FlowRunner, Scope}
  alias RhoFrameworks.Flow.Policies.{Deterministic, Hybrid}
  alias RhoFrameworks.Flows.Registry, as: FlowRegistry
  alias RhoFrameworks.Tools.WorkflowTools
  alias RhoFrameworks.UseCases.{GenerateFrameworkSkeletons, ResearchDomain}
  alias RhoWeb.Components.{ResearchPanel, RoutingChip, StepChat}
  alias RhoWeb.FlowComponents

  @valid_modes [:guided, :copilot, :open]

  import FlowComponents

  # -------------------------------------------------------------------
  # Mount
  # -------------------------------------------------------------------

  @impl true
  def mount(%{"flow_id" => flow_id} = params, _session, socket) do
    mode = mode_from_params(params)
    intake = intake_from_params(params)

    case FlowRegistry.get(flow_id) do
      {:ok, flow_mod} ->
        if connected?(socket) do
          {:ok, boot_flow(socket, flow_mod, mode, intake)}
        else
          {:ok, assign_static(socket, flow_mod, mode, intake)}
        end

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "Unknown flow: #{flow_id}")
         |> redirect(to: org_path(socket, "/libraries"))}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns[:flow_module] do
      nil ->
        {:noreply, socket}

      _flow_mod ->
        {:noreply, assign(socket, :mode, mode_from_params(params))}
    end
  end

  defp mode_from_params(params) do
    case params["mode"] do
      m when is_binary(m) ->
        atom = String.to_existing_atom(m)
        if atom in @valid_modes, do: atom, else: :guided

      _ ->
        :guided
    end
  rescue
    ArgumentError -> :guided
  end

  # §3.5 Phase 9 — read intake fields from query params so the smart-NL
  # entry surface (and any future deep link) can land on the wizard
  # with the form pre-seeded. Static whitelist (not String.to_atom) to
  # avoid atom-exhaustion via attacker-controlled query strings.
  @intake_param_atoms %{
    "name" => :name,
    "description" => :description,
    "domain" => :domain,
    "target_roles" => :target_roles,
    "skill_count" => :skill_count,
    "levels" => :levels,
    "starting_point" => :starting_point,
    "library_id" => :library_id,
    "library_id_a" => :library_id_a,
    "library_id_b" => :library_id_b
  }

  defp intake_from_params(params) when is_map(params) do
    Enum.reduce(@intake_param_atoms, %{}, fn {key, atom_key}, acc ->
      case Map.get(params, key) do
        v when is_binary(v) and v != "" -> Map.put(acc, atom_key, v)
        _ -> acc
      end
    end)
  end

  defp assign_static(socket, flow_mod, mode, intake) do
    runner = FlowRunner.init(flow_mod, intake: intake)

    socket
    |> assign(:flow_module, flow_mod)
    |> assign(:flow_steps, flow_mod.steps())
    |> assign(:runner, runner)
    |> assign(:mode, mode)
    |> assign(:last_decision, nil)
    |> assign(:chip_expanded?, false)
    |> assign(:completed_steps, [])
    |> assign(:step_status, :idle)
    |> assign(:step_error, nil)
    |> assign(:workers, [])
    |> assign(:dt_snapshot, [])
    |> assign(:dt_schema, nil)
    |> assign(:form, intake)
    |> assign(:session_id, nil)
    |> assign(:scope, nil)
    |> assign(:page_title, flow_mod.label())
    |> assign(:streaming_text, "")
    |> assign(:tool_events, [])
    |> assign(:select_items, [])
    |> assign(:selected_ids, [])
    |> assign(:research_rows, [])
    |> assign(:research_agent_id, nil)
    |> assign(:step_chat_agent_id, nil)
    |> assign(:step_chat_pending_question, nil)
  end

  defp boot_flow(socket, flow_mod, mode, intake) do
    org = socket.assigns.current_organization
    session_id = "flow_#{System.unique_integer([:positive])}"

    DataTable.ensure_started(session_id)
    DataTable.ensure_table(session_id, "flow:state", DataTableSchemas.flow_state_schema())

    scope = %Scope{
      organization_id: org.id,
      session_id: session_id,
      user_id: socket.assigns.current_user.id,
      source: :flow
    }

    Rho.Events.subscribe(session_id)

    socket
    |> assign_static(flow_mod, mode, intake)
    |> assign(:session_id, session_id)
    |> assign(:scope, scope)
    |> maybe_auto_run()
  end

  # -------------------------------------------------------------------
  # Render
  # -------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:current_step, current_node_id(assigns.runner))

    ~H"""
    <div class="flow-container">
      <div class="flow-header">
        <h1 class="flow-title"><%= @flow_module.label() %></h1>
        <.mode_toggle mode={@mode} />
      </div>

      <.step_indicator
        steps={@flow_steps}
        current_step={@current_step}
        completed_steps={@completed_steps}
      />

      <RoutingChip.routing_chip
        :if={@mode != :guided}
        decision={@last_decision}
        expanded?={@chip_expanded?}
        current_node_id={@current_step}
      />

      <div class="flow-step-content">
        <%= render_current_step(assigns) %>
        <%= maybe_render_step_chat(assigns) %>
      </div>
    </div>
    """
  end

  # §3.4 — render the per-step chat only on nodes whose UseCase has a
  # chat-side tool. Hides on :agent_loop nodes (research) where the
  # node already owns the agent loop.
  defp maybe_render_step_chat(assigns) do
    step = current_step_def(assigns)
    use_case = step && Map.get(step, :use_case)
    routing = step && Map.get(step, :routing)

    if use_case && routing != :agent_loop && WorkflowTools.tool_for_use_case(use_case) do
      assigns =
        assigns
        |> assign(:chat_node, step)
        |> assign(:chat_disabled?, step_chat_disabled?(step, assigns.step_status))

      ~H"""
      <StepChat.step_chat
        node={@chat_node}
        agent_id={@step_chat_agent_id}
        streaming_text={@streaming_text}
        tool_events={@tool_events}
        pending_question={@step_chat_pending_question}
        disabled?={@chat_disabled?}
      />
      """
    else
      ~H""
    end
  end

  # Disable submission while a step is mid-flight on nodes whose UseCase
  # writes into a shared table — fan-out and generation. Avoids two
  # BAML calls clobbering the same table.
  defp step_chat_disabled?(%{type: :fan_out}, :running), do: true
  defp step_chat_disabled?(%{id: :generate}, :running), do: true
  defp step_chat_disabled?(_step, _status), do: false

  defp render_current_step(assigns) do
    step = current_step_def(assigns)

    if is_nil(step) do
      assigns =
        assigns
        |> assign(:final_summary, final_save_summary(assigns))
        |> assign(:saved_library_path, saved_library_path(assigns))

      ~H"""
      <div class="flow-action-complete flow-final-complete">
        <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="var(--green)" stroke-width="2.5">
          <circle cx="12" cy="12" r="10" />
          <polyline points="16 9 10.5 14.5 8 12" />
        </svg>
        <span class="flow-action-headline"><%= @flow_module.label() %> complete</span>
        <span :if={@final_summary} class="flow-action-detail"><%= @final_summary %></span>
        <.link :if={@saved_library_path} patch={@saved_library_path} class="btn-primary">
          View library
        </.link>
      </div>
      """
    else
      render_step(assign(assigns, :step_def, step))
    end
  end

  # Pulls a summary line for the current `:action` step, when one exists.
  # Returns `{headline, detail}` — `nil` for either part if not applicable.
  # The :save node is the only step that gets a custom headline today;
  # other actions fall back to the default "<label> — Done".
  defp action_summary_lines(assigns) do
    step = assigns.step_def
    runner = assigns.runner
    summary = runner.summaries[step.id]

    case {step.id, summary} do
      {:save, %{} = s} ->
        skills = Map.get(s, :saved_count, 0)
        notes = Map.get(s, :research_notes_saved, 0)
        name = Map.get(s, :library_name) || "library"

        headline = "Saved \"#{name}\" — #{skills} #{pluralise(skills, "skill", "skills")}"

        detail =
          if notes > 0,
            do: "+ #{notes} #{pluralise(notes, "research note", "research notes")} archived",
            else: nil

        {headline, detail}

      _ ->
        {nil, nil}
    end
  end

  defp final_save_summary(assigns) do
    case assigns.runner.summaries[:save] do
      %{} = s ->
        skills = Map.get(s, :saved_count, 0)
        notes = Map.get(s, :research_notes_saved, 0)
        name = Map.get(s, :library_name) || "library"

        notes_part =
          if notes > 0,
            do: " + #{notes} #{pluralise(notes, "research note", "research notes")}",
            else: ""

        "Saved \"#{name}\" — #{skills} #{pluralise(skills, "skill", "skills")}#{notes_part}"

      _ ->
        nil
    end
  end

  defp saved_library_path(assigns) do
    org = assigns[:current_organization]

    library_id =
      get_in(assigns.runner.summaries, [:save, :library_id]) ||
        get_in(assigns.runner.summaries, [:save, :draft_library_id])

    if org && library_id, do: "/orgs/#{org.slug}/libraries/#{library_id}", else: nil
  end

  defp pluralise(1, singular, _plural), do: singular
  defp pluralise(_, _singular, plural), do: plural

  defp render_step(assigns) do
    case assigns.step_def.type do
      :form ->
        ~H"""
        <.form_step fields={@step_def.config.fields} form={@form} step_id={@step_def.id} />
        """

      :action ->
        cond do
          Map.get(assigns.step_def, :use_case) == ResearchDomain ->
            assigns =
              assign(assigns, :show_theater, show_theater?(assigns.mode, assigns.step_def))

            ~H"""
            <ResearchPanel.research_panel
              rows={@research_rows}
              status={@step_status}
              error={@step_error}
              tool_events={@tool_events}
              show_theater={@show_theater}
            />
            """

          assigns.step_def.config[:manual] == true and assigns.step_status == :idle ->
            ~H"""
            <.confirm_step
              message={@step_def.config[:message] || "Ready to continue?"}
              step_label={@step_def.label}
            />
            """

          true ->
            {summary_message, summary_detail} = action_summary_lines(assigns)

            assigns =
              assigns
              |> assign(:summary_message, summary_message)
              |> assign(:summary_detail, summary_detail)
              |> assign(:show_theater, show_theater?(assigns.mode, assigns.step_def))

            ~H"""
            <.action_step
              step_status={@step_status}
              step_label={@step_def.label}
              step_error={@step_error}
              streaming_text={@streaming_text}
              tool_events={@tool_events}
              summary_message={@summary_message}
              summary_detail={@summary_detail}
              show_theater={@show_theater}
            />
            """
        end

      :table_review ->
        if assigns.step_def.config[:conflict_mode] == true do
          ~H"""
          <.conflict_resolution_step rows={@dt_snapshot} session_id={@session_id} />
          """
        else
          ~H"""
          <.table_review_step
            dt_snapshot={@dt_snapshot}
            dt_schema={@dt_schema}
            session_id={@session_id}
            table_name={flow_table_name(@runner)}
          />
          """
        end

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
      |> update(:runner, &FlowRunner.merge_intake(&1, form_data))
      |> advance_step()

    {:noreply, maybe_auto_run(socket)}
  end

  def handle_event("continue", _params, socket) do
    {:noreply, socket |> advance_step() |> maybe_auto_run()}
  end

  def handle_event("start_fan_out", _params, socket) do
    {:noreply, run_action(socket)}
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
    step = current_step_def(socket.assigns)
    selected_count = length(socket.assigns.selected_ids)
    min_select = step.config[:min_select]
    max_select = step.config[:max_select]

    cond do
      is_integer(min_select) and selected_count < min_select ->
        {:noreply, put_flash(socket, :error, "Select at least #{min_select} to continue.")}

      is_integer(max_select) and selected_count > max_select ->
        {:noreply, put_flash(socket, :error, "Select at most #{max_select} to continue.")}

      true ->
        items = socket.assigns.select_items
        selected_ids = socket.assigns.selected_ids
        selected = Enum.filter(items, fn i -> item_id(i) in selected_ids end)

        summary = %{matches: items, selected: selected, skip_reason: nil}

        socket =
          socket
          |> clear_flash(:error)
          |> update(:runner, &FlowRunner.put_summary(&1, step.id, summary))
          |> reset_select_state()
          |> advance_step()

        {:noreply, maybe_auto_run(socket)}
    end
  end

  def handle_event("skip_select", _params, socket) do
    step = current_step_def(socket.assigns)
    summary = %{matches: [], selected: [], skip_reason: "user skipped"}

    socket =
      socket
      |> update(:runner, &FlowRunner.put_summary(&1, step.id, summary))
      |> reset_select_state()
      |> advance_step()

    {:noreply, maybe_auto_run(socket)}
  end

  def handle_event("confirm_manual", _params, socket) do
    step = current_step_def(socket.assigns)

    if step && Map.get(step, :use_case) do
      # Manual action with a UseCase: run it now; user clicks "Continue"
      # afterwards to advance via the standard action_step UI.
      {:noreply, run_action(socket)}
    else
      {:noreply, socket |> advance_step() |> maybe_auto_run()}
    end
  end

  def handle_event("research_toggle_pin", %{"id" => row_id}, socket) when is_binary(row_id) do
    sid = socket.assigns.session_id
    table = ResearchDomain.table_name()

    current =
      Enum.find(socket.assigns.research_rows, fn r ->
        to_string(r[:id] || r["id"]) == row_id
      end)

    next_pinned = not pinned_row?(current)

    if sid && current do
      Process.put(:rho_source, :user)

      DataTable.update_cells(sid, [%{id: row_id, field: :pinned, value: next_pinned}],
        table: table
      )
    end

    {:noreply, refresh_research(socket)}
  end

  def handle_event("research_add_note", %{"note" => note}, socket)
      when is_binary(note) and note != "" do
    sid = socket.assigns.session_id
    table = ResearchDomain.table_name()

    if sid do
      Process.put(:rho_source, :user)

      DataTable.add_rows(
        sid,
        [%{source: "user", fact: note, tag: nil, pinned: true}],
        table: table
      )
    end

    {:noreply, refresh_research(socket)}
  end

  def handle_event("research_add_note", _params, socket), do: {:noreply, socket}

  def handle_event("research_continue", _params, socket) do
    if agent_id = socket.assigns.research_agent_id, do: AgentJobs.cancel(agent_id)
    {:noreply, advance_from_research(socket)}
  end

  def handle_event("resolve_conflict", %{"id" => row_id, "action" => action}, socket)
      when is_binary(row_id) and action in ["merge_a", "merge_b", "keep_both"] do
    sid = socket.assigns.session_id
    table = RhoFrameworks.Workbench.combine_preview_table()

    if sid do
      Process.put(:rho_source, :user)

      DataTable.update_cells(sid, [%{id: row_id, field: :resolution, value: action}],
        table: table
      )
    end

    {:noreply, refresh_data_table(socket, table)}
  end

  def handle_event("resolve_conflict", _params, socket), do: {:noreply, socket}

  def handle_event("confirm_resolutions", _params, socket) do
    step = current_step_def(socket.assigns)
    runner = socket.assigns.runner
    scope = socket.assigns.scope

    case FlowRunner.run_node(step, runner, scope) do
      {:ok, summary} ->
        socket =
          socket
          |> update(:runner, &FlowRunner.put_summary(&1, step.id, summary))
          |> clear_flash(:error)
          |> advance_step()
          |> maybe_auto_run()

        {:noreply, socket}

      {:error, {:unresolved, count}} ->
        {:noreply, put_flash(socket, :error, "#{count} conflict(s) still unresolved.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cannot continue: #{inspect(reason)}")}
    end
  end

  def handle_event("set_mode", %{"mode" => raw}, socket) do
    new_mode = mode_from_params(%{"mode" => raw})

    socket =
      socket
      |> assign(:mode, new_mode)
      |> push_patch(to: mode_path(socket, new_mode), replace: true)

    {:noreply, socket}
  end

  def handle_event("routing_chip_toggle", _params, socket) do
    {:noreply, assign(socket, :chip_expanded?, not socket.assigns.chip_expanded?)}
  end

  def handle_event("step_chat_submit", %{"message" => msg}, socket)
      when is_binary(msg) and msg != "" do
    {:noreply, spawn_step_chat(socket, msg)}
  end

  def handle_event("step_chat_submit", _params, socket), do: {:noreply, socket}

  def handle_event(
        "override_edge",
        %{"node" => node_str, "edge" => edge_str},
        socket
      ) do
    case socket.assigns.last_decision do
      %{node_id: node_id, allowed: allowed} = decision ->
        with {:ok, origin} <- safe_existing_atom(node_str),
             ^node_id <- origin,
             {:ok, edge_id} <- safe_existing_atom(edge_str),
             true <- Enum.any?(allowed, fn e -> e.to == edge_id end),
             true <- decision.target == socket.assigns.runner.node_id do
          {:noreply, apply_override(socket, origin, edge_id)}
        else
          _ -> {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
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

      :step_chat_clarify ->
        {:noreply, handle_step_chat_clarify(socket, data)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:generate_completed, summary}, socket) do
    if generate_running?(socket) do
      {:noreply, complete_generate_step(socket, summary)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:generate_failed, reason}, socket) do
    if generate_running?(socket) do
      {:noreply,
       socket
       |> assign(:step_status, :failed)
       |> assign(:step_error, inspect(reason))}
    else
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
      Rho.Events.unsubscribe(sid)
    end

    :ok
  end

  # -------------------------------------------------------------------
  # Streaming text / tool events
  # -------------------------------------------------------------------

  defp handle_text_delta(socket, data) do
    text = data[:text] || ""

    if text != "" and stream_target_open?(socket) do
      assign(socket, :streaming_text, socket.assigns.streaming_text <> text)
    else
      socket
    end
  end

  defp handle_tool_event(socket, phase, data) do
    if stream_target_open?(socket) do
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

  # Either the wizard's step is mid-run (the original case) or a
  # step_chat agent is running — both share the streaming_text /
  # tool_events assigns.
  defp stream_target_open?(socket) do
    socket.assigns.step_status == :running or
      is_binary(socket.assigns[:step_chat_agent_id])
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
        tbl = data[:table_name]

        socket
        |> maybe_refresh_research(tbl)
        |> refresh_data_table(tbl || flow_table_name(socket.assigns.runner))

      _ ->
        socket
    end
  end

  defp maybe_refresh_research(socket, tbl) do
    if tbl == ResearchDomain.table_name() or socket.assigns.research_rows != [] do
      refresh_research(socket)
    else
      socket
    end
  end

  defp refresh_research(socket) do
    sid = socket.assigns.session_id
    if is_nil(sid), do: socket, else: assign(socket, :research_rows, fetch_research_rows(sid))
  end

  defp fetch_research_rows(sid) do
    case DataTable.get_rows(sid, table: ResearchDomain.table_name()) do
      rows when is_list(rows) -> rows
      _ -> []
    end
  end

  defp pinned_row?(nil), do: false

  defp pinned_row?(row) when is_map(row) do
    case Map.get(row, :pinned) || Map.get(row, "pinned") do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  # -------------------------------------------------------------------
  # Step machine
  # -------------------------------------------------------------------

  defp current_node_id(%{node_id: id}), do: id

  defp current_step_def(assigns), do: FlowRunner.current_node(assigns.runner)

  defp advance_step(socket) do
    runner = socket.assigns.runner
    node = FlowRunner.current_node(runner)
    policy = policy_for_mode(socket.assigns.mode)

    case FlowRunner.choose_next(runner.flow_mod, node, runner, policy) do
      {:ok, next_id, decision} ->
        completed = [node.id | socket.assigns.completed_steps] |> Enum.uniq()
        last_decision = build_last_decision(node, next_id, decision)

        new_runner =
          runner
          |> FlowRunner.advance(next_id)
          |> apply_populate_intake(next_id, socket.assigns.scope)

        socket
        |> assign(:runner, new_runner)
        |> assign(:form, new_runner.intake)
        |> assign(:completed_steps, completed)
        |> assign(:last_decision, last_decision)
        |> assign(:step_status, :idle)
        |> assign(:step_error, nil)
        |> assign(:streaming_text, "")
        |> assign(:tool_events, [])

      {:error, reason} ->
        Logger.error("[FlowLive] policy.choose_next failed: #{inspect(reason)}")

        socket
        |> assign(:step_status, :failed)
        |> assign(:step_error, "routing failed: #{inspect(reason)}")
    end
  end

  # Hook for flows to seed smart defaults on a node before its form
  # renders. Flows opt in by implementing the optional `populate_intake/3`
  # callback (see `RhoFrameworks.Flow`). Only keys not already present
  # in `intake` are merged, so URL pre-fill and prior user input win.
  defp apply_populate_intake(runner, _next_id, nil), do: runner

  defp apply_populate_intake(runner, next_id, scope) do
    if function_exported?(runner.flow_mod, :populate_intake, 3) do
      defaults = runner.flow_mod.populate_intake(next_id, runner, scope)

      if is_map(defaults) and map_size(defaults) > 0 do
        new_only =
          Enum.reject(defaults, fn {k, _v} -> Map.has_key?(runner.intake, k) end)
          |> Map.new()

        if map_size(new_only) > 0,
          do: FlowRunner.merge_intake(runner, new_only),
          else: runner
      else
        runner
      end
    else
      runner
    end
  end

  @doc """
  Maps the mode toggle onto a `Flow.Policy` implementation. Only
  `:guided` uses the deterministic walker; `:copilot` and `:open` both
  run the Hybrid policy — the difference is theater visibility, not
  edge selection.
  """
  @spec policy_for_mode(:guided | :copilot | :open) :: module()
  def policy_for_mode(:guided), do: Deterministic
  def policy_for_mode(_), do: Hybrid

  @doc """
  §3.2 — gate the raw tool-call log + streaming text panel.

  * `:guided` hides theater entirely.
  * `:copilot` shows it only on agent-driven nodes (`:auto` / `:agent_loop`).
  * `:open` always shows it.
  """
  @spec show_theater?(:guided | :copilot | :open, map()) :: boolean()
  def show_theater?(:guided, _step), do: false
  def show_theater?(:open, _step), do: true

  def show_theater?(:copilot, %{routing: routing}) when routing in [:auto, :agent_loop],
    do: true

  def show_theater?(:copilot, _step), do: false

  # Capture the routing decision the chip will render. Only :auto nodes
  # produce a meaningful chip — fixed/agent_loop edges are not user-pickable.
  defp build_last_decision(%{routing: :auto, id: node_id, next: edges}, next_id, decision)
       when is_atom(next_id) and next_id != :done and is_list(edges) do
    %{
      node_id: node_id,
      target: next_id,
      reason: decision[:reason],
      confidence: decision[:confidence],
      allowed: edges
    }
  end

  defp build_last_decision(_node, _next_id, _decision), do: nil

  # Override path: cancel any in-flight worker, walk the runner back to
  # the origin auto node, write user_override, and re-run advance_step.
  # The Hybrid policy short-circuits on user_override (§2.4), so this
  # picks the user's chosen edge with no LLM call.
  defp apply_override(socket, origin_node_id, edge_id) do
    runner = socket.assigns.runner

    if id = socket.assigns[:research_agent_id], do: AgentJobs.cancel(id)

    completed = List.delete(socket.assigns.completed_steps, origin_node_id)

    rolled_back =
      runner
      |> FlowRunner.put_user_override(origin_node_id, edge_id)
      |> FlowRunner.advance(origin_node_id)

    socket
    |> assign(:runner, rolled_back)
    |> assign(:completed_steps, completed)
    |> assign(:chip_expanded?, false)
    |> assign(:last_decision, nil)
    |> assign(:research_rows, [])
    |> assign(:research_agent_id, nil)
    |> assign(:streaming_text, "")
    |> assign(:tool_events, [])
    |> assign(:workers, [])
    |> assign(:select_items, [])
    |> assign(:selected_ids, [])
    |> assign(:step_status, :idle)
    |> assign(:step_error, nil)
    |> advance_step()
    |> maybe_auto_run()
  end

  defp safe_existing_atom(s) when is_binary(s) do
    {:ok, String.to_existing_atom(s)}
  rescue
    ArgumentError -> :error
  end

  defp safe_existing_atom(_), do: :error

  defp maybe_auto_run(socket) do
    case current_step_def(socket.assigns) do
      nil ->
        socket

      step ->
        case step.type do
          :action ->
            if step.config[:manual] == true, do: socket, else: run_action(socket)

          :table_review ->
            if step.config[:conflict_mode] == true do
              refresh_data_table(socket, RhoFrameworks.Workbench.combine_preview_table())
            else
              refresh_data_table(socket)
            end

          :select ->
            load_select_options(socket)

          _ ->
            socket
        end
    end
  end

  # -------------------------------------------------------------------
  # Action execution (delegates to FlowRunner)
  # -------------------------------------------------------------------

  defp run_action(socket) do
    runner = socket.assigns.runner
    node = FlowRunner.current_node(runner)
    scope = socket.assigns.scope

    if Map.get(node, :use_case) == GenerateFrameworkSkeletons do
      spawn_generate_skeletons(socket, node, runner, scope)
    else
      run_action_via_runner(socket, node, runner, scope)
    end
  end

  defp run_action_via_runner(socket, node, runner, scope) do
    case FlowRunner.run_node(node, runner, scope) do
      {:async, %{agent_id: agent_id}} ->
        socket =
          socket
          |> assign(:step_status, :running)
          |> assign(:step_error, nil)
          |> assign(:streaming_text, "")
          |> assign(:tool_events, [])

        if Map.get(node, :use_case) == ResearchDomain do
          socket
          |> assign(:research_agent_id, agent_id)
          |> refresh_research()
        else
          socket
        end

      {:async, %{workers: workers}} ->
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

      {:ok, summary} ->
        socket
        |> update(:runner, &FlowRunner.put_summary(&1, node.id, summary))
        |> assign(:step_status, :completed)
        |> assign(:step_error, nil)
        |> maybe_refresh_table_from_summary(summary)

      :ok ->
        socket
        |> assign(:step_status, :completed)
        |> assign(:step_error, nil)

      {:error, reason} ->
        socket
        |> assign(:step_status, :failed)
        |> assign(:step_error, inspect(reason))
    end
  end

  # Phase 6 — generate-skeletons spawns the BAML UseCase under
  # `Rho.TaskSupervisor`. The UseCase emits `:data_table` events through
  # `Workbench.add_skill` which the existing `handle_data_table_event`
  # picks up to stream rows in. Completion arrives as `:generate_completed`.
  defp spawn_generate_skeletons(socket, node, runner, scope) do
    flow_mod = runner.flow_mod
    input = flow_mod.build_input(node.id, runner, scope)
    lv_pid = self()

    Task.Supervisor.start_child(Rho.TaskSupervisor, fn ->
      case GenerateFrameworkSkeletons.run(input, scope) do
        {:ok, summary} ->
          send(lv_pid, {:generate_completed, summary})

        {:error, reason} ->
          Logger.warning(fn -> "[FlowLive] generate_skeletons failed: #{inspect(reason)}" end)
          send(lv_pid, {:generate_failed, reason})
      end
    end)

    socket
    |> assign(:step_status, :running)
    |> assign(:step_error, nil)
    |> assign(:streaming_text, "")
    |> assign(:tool_events, [])
  end

  # -------------------------------------------------------------------
  # Step chat (Phase 8 — §3.4)
  # -------------------------------------------------------------------

  defp spawn_step_chat(socket, message) do
    step = current_step_def(socket.assigns)
    use_case = step && Map.get(step, :use_case)
    use_case_tool = use_case && WorkflowTools.tool_for_use_case(use_case)
    scope = socket.assigns.scope
    runner = socket.assigns.runner

    cond do
      is_nil(use_case_tool) ->
        socket

      step_chat_disabled?(step, socket.assigns.step_status) ->
        socket

      is_nil(scope) or is_nil(scope.session_id) ->
        socket

      true ->
        config = Rho.AgentConfig.agent(:default)

        spawn_args = [
          task: message,
          parent_agent_id: scope.session_id,
          tools: [use_case_tool, WorkflowTools.clarify_tool()],
          model: config.model,
          system_prompt: step_chat_system_prompt(step, runner),
          max_steps: 5,
          turn_strategy: Rho.TurnStrategy.Direct,
          provider: config.provider || %{},
          agent_name: :step_chat,
          session_id: scope.session_id,
          organization_id: scope.organization_id
        ]

        case step_chat_spawn_fn().(spawn_args) do
          {:ok, agent_id} when is_binary(agent_id) ->
            socket
            |> assign(:step_chat_agent_id, agent_id)
            |> assign(:step_chat_pending_question, nil)
            |> assign(:streaming_text, "")
            |> assign(:tool_events, [])

          _ ->
            socket
        end
    end
  end

  defp step_chat_system_prompt(step, runner) do
    """
    You are a per-step assistant inside a wizard. The user is on step "#{step.label}".

    #{wizard_context_block(runner)}

    You have exactly two tools: the step's use-case tool, and `clarify`.

    - The wizard already knows the values listed above. Do not ask for them
      via `clarify`; pass them through to the use-case tool as-is.
    - If the user's request is clear, call the use-case tool with the right
      arguments and stop. Do not chain calls.
    - If the request is genuinely ambiguous and no reasonable assumption
      resolves it, call `clarify` with a single short question. Calling
      `clarify` ends your turn — wait for the user to answer in a new turn.
    - Never run more than one tool per turn.
    """
  end

  # Snapshots the wizard's current intake + resolved table name into a
  # context block. Without this, the chat agent has no idea which
  # framework / table it's working on and ends up asking via `clarify`
  # for things the wizard already knows.
  defp wizard_context_block(runner) do
    intake = runner.intake || %{}
    table_name = flow_table_name(runner)

    fields = [
      {"Framework name", get(intake, :name)},
      {"Description", get(intake, :description)},
      {"Domain", get(intake, :domain)},
      {"Target roles", get(intake, :target_roles)},
      {"Skill count", get(intake, :skill_count)},
      {"Proficiency levels", get(intake, :levels)},
      {"Library table", if(table_name == "", do: nil, else: table_name)}
    ]

    rendered =
      fields
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Enum.map_join("\n", fn {k, v} -> "- #{k}: #{v}" end)

    if rendered == "" do
      "Current context: (none yet — the user hasn't filled in the intake form)"
    else
      "Current context (use these as-is — do not ask the user for them):\n" <> rendered
    end
  end

  defp get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp step_chat_spawn_fn do
    Application.get_env(:rho_web, :step_chat_spawn_fn, &AgentJobs.start/1)
  end

  defp handle_step_chat_clarify(socket, data) do
    agent_id = data[:agent_id] || data["agent_id"]

    if is_binary(agent_id) and agent_id == socket.assigns[:step_chat_agent_id] do
      assign(socket, :step_chat_pending_question, data[:question] || data["question"])
    else
      socket
    end
  end

  defp finalize_step_chat(socket) do
    socket
    |> assign(:step_chat_agent_id, nil)
    |> refresh_data_table()
  end

  # -------------------------------------------------------------------
  # Table refresh
  # -------------------------------------------------------------------

  defp maybe_refresh_table_from_summary(socket, %{table_name: name}) when is_binary(name) do
    refresh_data_table(socket, name)
  end

  defp maybe_refresh_table_from_summary(socket, _), do: socket

  defp refresh_data_table(socket, table_name \\ nil) do
    tbl = table_name || flow_table_name(socket.assigns.runner)
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
    agent_id =
      data[:worker_agent_id] || data["worker_agent_id"] ||
        data[:agent_id] || data["agent_id"]

    research_id = socket.assigns[:research_agent_id]
    step_chat_id = socket.assigns[:step_chat_agent_id]

    cond do
      research_id != nil and research_id == agent_id ->
        Logger.debug("[FlowLive] research worker finished — awaiting user: #{agent_id}")
        finalize_research_step(socket)

      step_chat_id != nil and step_chat_id == agent_id ->
        Logger.debug("[FlowLive] step_chat agent finished: #{agent_id}")
        finalize_step_chat(socket)

      socket.assigns.workers != [] ->
        mark_worker_completed(socket, agent_id)

      true ->
        Logger.debug(fn ->
          "[FlowLive] unmatched task.completed: agent_id=#{inspect(agent_id)} " <>
            "workers=#{length(socket.assigns.workers)}"
        end)

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

  # Worker finished naturally (`task_completed`). Stop the spinner, but
  # do NOT advance — the user needs to review/pin/add notes first. The
  # research panel switches its button label from "Continue early →" to
  # "Continue →" off the `:awaiting_user` status.
  defp finalize_research_step(socket) do
    socket
    |> assign(:step_status, :awaiting_user)
    |> assign(:research_agent_id, nil)
  end

  # User clicked Continue (or Continue early). Cancel the worker if
  # still running, snapshot pin counts, then advance.
  defp advance_from_research(socket) do
    pinned_count = Enum.count(socket.assigns.research_rows, &pinned_row?/1)
    total = length(socket.assigns.research_rows)

    summary = %{
      table_name: ResearchDomain.table_name(),
      pinned_count: pinned_count,
      total_count: total
    }

    socket
    |> update(:runner, &FlowRunner.put_summary(&1, :research, summary))
    |> assign(:step_status, :completed)
    |> assign(:research_agent_id, nil)
    |> advance_step()
    |> maybe_auto_run()
  end

  defp complete_generate_step(socket, %{table_name: table_name} = summary) do
    runner_summary = %{
      table_name: table_name,
      library_id: Map.get(summary, :library_id),
      library_name: Map.get(summary, :library_name)
    }

    socket
    |> update(:runner, &FlowRunner.put_summary(&1, :generate, runner_summary))
    |> assign(:step_status, :completed)
    |> assign(:step_error, nil)
    |> refresh_data_table(table_name)
  end

  defp generate_running?(socket) do
    socket.assigns[:step_status] == :running and
      current_node_id(socket.assigns.runner) == :generate
  end

  # -------------------------------------------------------------------
  # Select step loading
  # -------------------------------------------------------------------

  defp load_select_options(socket) do
    runner = socket.assigns.runner
    node = FlowRunner.current_node(runner)
    scope = socket.assigns.scope

    socket = assign(socket, :step_status, :loading)

    case FlowRunner.run_node(node, runner, scope) do
      {:ok, %{matches: [], skip_reason: reason}} when is_binary(reason) ->
        summary = %{matches: [], selected: [], skip_reason: reason}

        socket
        |> put_flash(:info, reason)
        |> update(:runner, &FlowRunner.put_summary(&1, node.id, summary))
        |> reset_select_state()
        |> advance_step()
        |> maybe_auto_run()

      {:ok, %{matches: matches}} ->
        pre_picked = initial_selected_ids(node, runner, matches)

        socket
        |> assign(:select_items, matches)
        |> assign(:selected_ids, pre_picked)
        |> assign(:step_status, :idle)
        |> maybe_auto_advance_picker(node, matches, pre_picked)

      {:error, reason} ->
        socket
        |> assign(:step_status, :failed)
        |> assign(:step_error, inspect(reason))
    end
  end

  # When the user arrived at `:pick_existing_library` with a singleton
  # pre-pick AND the flow is `:edit-framework`, skip the confirmation
  # click. Edit-framework users come from the library landing page
  # "Edit" affordance or NL chat ("edit our X framework") — both
  # express unambiguous intent. For `:create-framework` (extend/merge),
  # we leave pre-pick visible so the user can confirm or change their
  # mind before triggering the heavier action chain (load → identify
  # gaps → generate).
  defp maybe_auto_advance_picker(socket, %{id: :pick_existing_library} = node, matches, [_id]) do
    if edit_framework_flow?(socket),
      do: auto_advance_with_selection(socket, node, matches),
      else: socket
  end

  defp maybe_auto_advance_picker(socket, _node, _matches, _pre_picked), do: socket

  defp edit_framework_flow?(socket) do
    case socket.assigns[:flow_module] do
      RhoFrameworks.Flows.EditFramework -> true
      _ -> false
    end
  end

  defp auto_advance_with_selection(socket, node, matches) do
    selected_ids = socket.assigns.selected_ids
    selected = Enum.filter(matches, fn i -> item_id(i) in selected_ids end)
    summary = %{matches: matches, selected: selected, skip_reason: nil}

    socket
    |> update(:runner, &FlowRunner.put_summary(&1, node.id, summary))
    |> reset_select_state()
    |> advance_step()
    |> maybe_auto_run()
  end

  defp reset_select_state(socket) do
    socket
    |> assign(:select_items, [])
    |> assign(:selected_ids, [])
  end

  # Phase 10d — pre-pick a library when the smart-NL entry resolved a
  # `library_hint` to a `library_id` that's now in `intake`. Only fires
  # for `:pick_existing_library`; other select steps default to nothing
  # selected. The id must exist in the loaded matches; otherwise the
  # user picks normally (no surprise auto-selection of stale ids).
  defp initial_selected_ids(%{id: :pick_existing_library}, runner, matches) do
    case Map.get(runner.intake, :library_id) do
      id when is_binary(id) and id != "" ->
        if Enum.any?(matches, fn m -> item_id(m) == id end), do: [id], else: []

      _ ->
        []
    end
  end

  # Phase 10e — pre-pick two libraries when the smart-NL entry resolved
  # both `library_hints` to ids that are now in `intake`. Only fires
  # for `:pick_two_libraries` (the merge fork). Both ids must exist in
  # the loaded matches; if only one resolves, fall through to no
  # pre-pick rather than auto-selecting a half-pair the user didn't
  # intend.
  defp initial_selected_ids(%{id: :pick_two_libraries}, runner, matches) do
    id_a = Map.get(runner.intake, :library_id_a)
    id_b = Map.get(runner.intake, :library_id_b)

    with true <- is_binary(id_a) and id_a != "",
         true <- is_binary(id_b) and id_b != "",
         true <- id_a != id_b,
         true <- Enum.any?(matches, fn m -> item_id(m) == id_a end),
         true <- Enum.any?(matches, fn m -> item_id(m) == id_b end) do
      [id_a, id_b]
    else
      _ -> []
    end
  end

  defp initial_selected_ids(_node, _runner, _matches), do: []

  defp item_id(item) do
    to_string(item[:id] || item["id"] || :erlang.phash2(item))
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp flow_table_name(%{summaries: summaries, intake: intake}) do
    case get_in(summaries, [:generate, :table_name]) do
      name when is_binary(name) and name != "" ->
        name

      _ ->
        case Map.get(intake, :name) || Map.get(intake, "name") do
          name when is_binary(name) and name != "" ->
            RhoFrameworks.Library.Editor.table_name(name)

          _ ->
            ""
        end
    end
  end

  defp org_path(socket, suffix) do
    slug = socket.assigns.current_organization.slug
    "/orgs/#{slug}#{suffix}"
  end

  defp mode_path(socket, mode) do
    flow_id = socket.assigns.flow_module.id()
    org = socket.assigns[:current_organization]

    base =
      if org && Map.get(org, :slug),
        do: "/orgs/#{org.slug}/flows/#{flow_id}",
        else: "/flows/#{flow_id}"

    if mode == :guided, do: base, else: "#{base}?mode=#{mode}"
  end
end
