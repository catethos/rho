defmodule RhoFrameworks.Tools.WorkflowTools do
  @moduledoc """
  ReqLLM tool wrappers around `RhoFrameworks.UseCases.*`.

  These tools let the chat agent invoke the same workflow units the
  wizard's `RhoFrameworks.FlowRunner` runs. Each wrapper builds a typed
  input map from the LLM-supplied args, delegates to the UseCase, and
  formats the result into the chat-friendly text/error shape the agent
  expects.

  Adding a new UseCase to the chat surface is one new `tool/3` block
  here — the UseCase itself doesn't need to change.
  """

  use Rho.Tool

  alias Rho.Events
  alias Rho.Stdlib.DataTable
  alias Rho.Stdlib.EffectDispatcher
  alias RhoFrameworks.DataTableSchemas
  alias RhoFrameworks.Library.Editor
  alias RhoFrameworks.Scope

  alias RhoFrameworks.UseCases.{
    GenerateFrameworkSkeletons,
    GenerateProficiency,
    LoadSimilarRoles,
    SaveFramework
  }

  @use_case_tool_names %{
    LoadSimilarRoles => "load_similar_roles",
    GenerateFrameworkSkeletons => "generate_framework_skeletons",
    GenerateProficiency => "generate_proficiency",
    SaveFramework => "save_framework"
  }

  @doc """
  Returns the chat-side tool def for a UseCase module, or `nil` if the
  UseCase has no chat surface (e.g. `PickTemplate`, `ResearchDomain`).

  Used by the wizard's `<.step_chat />` component to constrain the
  per-step agent's tool list to *just* the current node's UseCase plus
  `clarify`.
  """
  @spec tool_for_use_case(module()) :: map() | nil
  def tool_for_use_case(use_case) when is_atom(use_case) do
    case Map.fetch(@use_case_tool_names, use_case) do
      {:ok, name} ->
        Enum.find(__tools__(), fn t -> t.tool.name == name end)

      :error ->
        nil
    end
  end

  @doc """
  Returns the `clarify` tool def. Pair with `tool_for_use_case/1` to
  build the step-chat agent's tool list.
  """
  @spec clarify_tool() :: map()
  def clarify_tool do
    Enum.find(__tools__(), fn t -> t.tool.name == "clarify" end)
  end

  # ── load_similar_roles ─────────────────────────────────────────────────

  tool :load_similar_roles,
       "Find existing role profiles similar to the framework being built. " <>
         "Pass intake-style fields; returns the top matches." do
    param(:name, :string, doc: "Framework name")
    param(:description, :string)
    param(:domain, :string)
    param(:target_roles, :string, doc: "Comma-separated role list")
    param(:limit, :integer, doc: "default: 5")

    run(fn args, ctx ->
      scope = Scope.from_context(ctx)

      input =
        %{
          name: args[:name],
          description: args[:description],
          domain: args[:domain],
          target_roles: args[:target_roles]
        }
        |> maybe_put(:limit, args[:limit])

      case LoadSimilarRoles.run(input, scope) do
        {:ok, %{matches: [], skip_reason: reason}} ->
          {:ok, "No similar roles found. #{reason}"}

        {:ok, %{matches: matches}} ->
          {:ok, format_matches(matches)}
      end
    end)
  end

  # ── generate_framework_skeletons ───────────────────────────────────────

  tool :generate_framework_skeletons,
       "Generate the skill skeletons for a new framework via a single streaming BAML call. " <>
         "Synchronous (typically 3–5s); rows stream into the session's library:<name> table " <>
         "as partials arrive." do
    param(:name, :string, required: true, doc: "Framework name")
    param(:description, :string, required: true)
    param(:domain, :string)
    param(:target_roles, :string)
    param(:skill_count, :integer, doc: "default: 12")
    param(:similar_role_skills, :string, doc: "Optional seed context block")
    param(:research, :string, doc: "Optional formatted research bullet list")

    run(fn args, ctx ->
      scope = Scope.from_context(ctx)

      input = %{
        name: args[:name],
        description: args[:description],
        domain: args[:domain],
        target_roles: args[:target_roles],
        skill_count: args[:skill_count],
        similar_role_skills: args[:similar_role_skills],
        research: args[:research],
        # Threaded through so the use case can keep the agent's turn
        # watchdog alive during a long BAML stream. Scope intentionally
        # excludes agent_id (domain-only), so we pass it via input.
        agent_id: ctx.agent_id
      }

      # Pre-flight: ensure the library table exists and switch the LV's
      # active data-table tab to it BEFORE streaming begins. Without this,
      # rows stream in but the user is still looking at the "main" tab.
      maybe_open_library_tab(ctx, args[:name])

      case GenerateFrameworkSkeletons.run(input, scope) do
        {:ok, %{added: added, table_name: tbl}} ->
          %Rho.ToolResponse{
            text: "Generated #{length(added)} skill(s) into '#{tbl}'.",
            effects: [
              %Rho.Effect.OpenWorkspace{key: :data_table},
              %Rho.Effect.Table{
                table_name: tbl,
                schema_key: :skill_library,
                mode_label: "Skill Library — #{args[:name]}",
                rows: [],
                skip_write?: true
              }
            ]
          }

        {:error, :missing_name} ->
          {:error, "name is required."}

        {:error, :missing_description} ->
          {:error, "description is required."}

        {:error, reason} ->
          {:error, "generate_framework_skeletons failed: #{inspect(reason)}"}
      end
    end)
  end

  defp maybe_open_library_tab(_ctx, nil), do: :ok
  defp maybe_open_library_tab(_ctx, ""), do: :ok

  defp maybe_open_library_tab(ctx, name) when is_binary(name) do
    session_id = ctx.session_id
    agent_id = ctx.agent_id

    if is_binary(session_id) do
      table_name = Editor.table_name(name)
      _ = DataTable.ensure_started(session_id)
      _ = DataTable.ensure_table(session_id, table_name, DataTableSchemas.library_schema())

      EffectDispatcher.dispatch_all(
        [
          %Rho.Effect.OpenWorkspace{key: :data_table},
          %Rho.Effect.Table{
            table_name: table_name,
            schema_key: :skill_library,
            mode_label: "Skill Library — #{name}",
            rows: [],
            skip_write?: true
          }
        ],
        %{session_id: session_id, agent_id: agent_id}
      )
    end

    :ok
  end

  # ── generate_proficiency ───────────────────────────────────────────────

  tool :generate_proficiency,
       "Spawn one proficiency-writer agent per category for the given library table. " <>
         "Reads skeleton rows from the named table and fans out asynchronously." do
    param(:table_name, :string, required: true, doc: "Library table name (e.g. library:Eng)")
    param(:levels, :integer, doc: "Levels to generate (default 5)")

    run(fn args, ctx ->
      scope = Scope.from_context(ctx)

      input = %{
        table_name: args[:table_name],
        levels: args[:levels] || 5,
        # Threaded through so the use case's `:task_requested`,
        # `:task_completed`, and `:structured_partial` events attribute
        # to the chat agent's tab — without this they route to a phantom
        # agent (session_id) and never appear in the chat thread.
        agent_id: ctx.agent_id
      }

      case GenerateProficiency.run(input, scope) do
        {:async, %{workers: workers}} ->
          # Block the chat agent's tool call until every fan-out writer
          # finishes. The wait loop tickles the agent's watchdog on every
          # event, so the 60s inactivity limit doesn't fire even when the
          # writers take ~30–60s to complete. The wizard/flow path keeps
          # the use case's async semantics by calling `.run/2` directly.
          worker_ids = Enum.map(workers, & &1.agent_id)

          summary =
            wait_for_writers(ctx.session_id, ctx.agent_id, worker_ids,
              timeout: @proficiency_wait_timeout_ms
            )

          format_proficiency_summary(args[:table_name], length(workers), summary)

        {:error, :missing_table_name} ->
          {:error, "table_name is required."}

        {:error, :empty_rows} ->
          {:error, "No rows in '#{args[:table_name]}'. Generate skeletons first."}

        {:error, reason} ->
          {:error, "generate_proficiency failed: #{inspect(reason)}"}
      end
    end)
  end

  @proficiency_wait_timeout_ms 5 * 60 * 1_000

  defp format_proficiency_summary(table_name, total, %{ok: ok, error: error, pending: 0}) do
    base = "Proficiency complete for '#{table_name}': #{ok}/#{total} categories OK"

    cond do
      error > 0 -> {:ok, base <> ", #{error} failed."}
      true -> {:ok, base <> "."}
    end
  end

  defp format_proficiency_summary(table_name, total, %{
         ok: ok,
         error: error,
         pending: pending
       }) do
    {:error,
     "Proficiency wait timed out for '#{table_name}': #{ok}/#{total} OK, " <>
       "#{error} failed, #{pending} still running."}
  end

  # Waits until every spawned fan-out writer has fired :task_completed
  # for one of `worker_ids`. Side-effects:
  #   - subscribes to the session topic for the duration of the wait
  #   - tickles the agent's `last_activity_at` on every received event
  #     (otherwise the runner's 60s watchdog kills the chat agent)
  defp wait_for_writers(session_id, agent_id, worker_ids, opts) do
    timeout = Keyword.get(opts, :timeout, 5 * 60 * 1_000)
    pending = MapSet.new(worker_ids)

    Rho.Events.subscribe(session_id)

    try do
      do_wait(pending, agent_id, %{ok: 0, error: 0}, timeout)
    after
      Rho.Events.unsubscribe(session_id)
    end
  end

  defp do_wait(pending, _agent_id, counts, _timeout) when pending == %MapSet{} do
    Map.put(counts, :pending, 0)
  end

  defp do_wait(pending, agent_id, counts, timeout) do
    Rho.Agent.Worker.touch_activity(agent_id)

    receive do
      %Rho.Events.Event{
        kind: :task_completed,
        data: %{worker_agent_id: id, status: status}
      } ->
        if MapSet.member?(pending, id) do
          do_wait(MapSet.delete(pending, id), agent_id, bump(counts, status), timeout)
        else
          do_wait(pending, agent_id, counts, timeout)
        end

      %Rho.Events.Event{} ->
        do_wait(pending, agent_id, counts, timeout)
    after
      timeout ->
        Map.put(counts, :pending, MapSet.size(pending))
    end
  end

  defp bump(counts, :ok), do: %{counts | ok: counts.ok + 1}
  defp bump(counts, :error), do: %{counts | error: counts.error + 1}
  defp bump(counts, _), do: counts

  # ── save_framework ─────────────────────────────────────────────────────

  tool :save_framework,
       "Persist the framework currently in the session's library table to the database. " <>
         "If library_id is omitted, saves to (or creates) the org's default library." do
    param(:library_id, :string)
    param(:table, :string, doc: "Library table name override (default: derived from library)")

    run(fn args, ctx ->
      scope = Scope.from_context(ctx)
      input = %{library_id: args[:library_id], table_name: args[:table]}

      case SaveFramework.run(input, scope) do
        {:ok, %{saved_count: count, library_name: name, draft_library_id: draft_id}} ->
          msg = "Saved #{count} skill(s) to '#{name}'."
          if draft_id, do: {:ok, msg <> " Draft created (#{draft_id})."}, else: {:ok, msg}

        {:error, :not_found} ->
          {:error, "Library not found."}

        {:error, {:not_running, tbl}} ->
          {:error, "No '#{tbl}' table — load a library first."}

        {:error, {:empty_table, tbl}} ->
          {:error, "The '#{tbl}' table is empty."}

        {:error, {:save_failed, step, cs}} ->
          {:error, "Save failed at #{step}: #{inspect(cs)}"}

        {:error, reason} ->
          {:error, "save_framework failed: #{inspect(reason)}"}
      end
    end)
  end

  # ── clarify ────────────────────────────────────────────────────────────

  tool :clarify,
       "Ask the user a clarifying question when the request is genuinely ambiguous. " <>
         "Use only when no reasonable assumption resolves the ambiguity — otherwise call " <>
         "the use-case tool directly. Calling clarify ends your turn." do
    param(:question, :string, required: true, doc: "The question to ask the user.")

    run(fn args, ctx ->
      question = args[:question] || ""
      session_id = ctx.session_id
      agent_id = ctx.agent_id

      if is_binary(session_id) and question != "" do
        Events.broadcast(
          session_id,
          Events.event(:step_chat_clarify, session_id, agent_id, %{
            question: question,
            agent_id: agent_id
          })
        )
      end

      {:final, question}
    end)
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_matches(matches) do
    lines =
      Enum.map(matches, fn r ->
        name = Map.get(r, :name) || Map.get(r, "name")
        family = Map.get(r, :role_family) || Map.get(r, "role_family") || "?"
        count = Map.get(r, :skill_count) || Map.get(r, "skill_count") || 0
        "- #{name} (#{family}, #{count} skills)"
      end)

    "Found #{length(matches)} similar role(s):\n" <> Enum.join(lines, "\n")
  end
end
