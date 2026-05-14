defmodule RhoFrameworks.UseCases.GenerateFrameworkSkeletons do
  @moduledoc """
  Generate the skeleton (name, description, skills) for a new framework
  via a single streaming BAML call. Phase 6 of
  `docs/swappable-decision-policy-plan.md` — the agentic 3-turn path is
  gone; one structured call streams partials into the session's `meta`
  and `library:<name>` tables progressively.

  The UseCase is **synchronous** (typically 3–5s). Callers that need
  non-blocking behaviour spawn it under `Rho.TaskSupervisor` (the wizard
  does this; the chat tool blocks on the result, since it's already in
  an agent loop).

  ## Inputs

      %{
        name:                 String.t,            # required
        description:          String.t,            # required
        target_roles:         String.t | nil,
        skill_count:          String.t | integer | nil,
        similar_role_skills:  String.t | nil,     # rendered seeds
        research:             String.t | nil,     # pinned bullet list
        seeds:                String.t | nil,     # alias for similar_role_skills
        seed_skills:          [%{skill_name | name, category, cluster?, skill_description?}] | nil,
                                                  # extend_existing path: rows already in
                                                  # the framework — model will not regenerate
        scope:                :full | :gaps_only,  # default :full
        gaps:                 [%{skill_name, category, rationale}] | nil
                                                  # extend_existing path: gap list to fill
      }

  ## Return shape

      {:ok, %{
        requested:    pos_integer,                # target skill count
        returned:     non_neg_integer,            # skills the model returned
        added:        [%{name, category, cluster}],  # rows actually persisted
        meta_set:     boolean,                    # did meta land?
        table_name:   String.t,                   # "library:<name>"
        library_name: String.t
      }}

  ## Test seam

  The LLM half is overridable via Application env:

      Application.put_env(:rho_frameworks, :generate_skeleton_fn,
        fn input, on_partial ->
          on_partial.(:meta, %{name: input[:name], description: "..."})
          on_partial.(:skill, %{category: "Eng", cluster: "Tooling",
                                name: "Vim", description: "Editor."})
          {:ok, %{name: ..., description: ..., skills: [...]}}
        end)

  The default impl wraps `LLM.GenerateSkeleton.stream/3` and detects
  newly-completed entries (and the first time meta is fully formed) as
  the BAML structured stream grows.
  """

  @behaviour RhoFrameworks.UseCase

  require Logger

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.DataTableSchemas
  alias RhoFrameworks.Library.Editor
  alias RhoFrameworks.LLM.GenerateSkeleton, as: LLM
  alias RhoFrameworks.Scope
  alias RhoFrameworks.Workbench

  @default_skill_count 12

  @impl true
  def describe do
    %{
      id: :generate_framework_skeletons,
      label: "Generate skill skeletons",
      cost_hint: :cheap,
      doc:
        "One streaming BAML call that produces a framework name, description, and skill skeletons. " <>
          "Rows land in the session's library table progressively as partials arrive."
    }
  end

  @impl true
  def run(input, %Scope{} = scope) do
    name = input[:name] || input["name"] || ""
    description = input[:description] || input["description"] || ""

    cond do
      blank?(name) ->
        {:error, :missing_name}

      blank?(description) ->
        {:error, :missing_description}

      true ->
        do_run(name, description, input, scope)
    end
  end

  defp do_run(name, description, input, %Scope{session_id: session_id} = scope)
       when is_binary(session_id) do
    requested = parse_skill_count(input[:skill_count] || input["skill_count"])
    scope_mode = parse_scope(input[:scope] || input["scope"])
    table_name = resolve_table_name(name, input, scope_mode)
    agent_id = input[:agent_id] || input["agent_id"]

    with :ok <- ensure_session_tables(session_id, table_name),
         seam_input <- build_seam_input(name, description, input, requested, scope_mode),
         {:ok, persisted_state, returned} <- run_seam(scope, table_name, agent_id, seam_input) do
      {:ok,
       %{
         requested: requested,
         returned: returned,
         added: persisted_state.added,
         meta_set: persisted_state.meta_set?,
         table_name: table_name,
         library_name: name,
         scope: scope_mode
       }}
    end
  end

  defp do_run(_name, _description, _input, _scope), do: {:error, :missing_session_id}

  # ──────────────────────────────────────────────────────────────────────
  # Setup
  # ──────────────────────────────────────────────────────────────────────

  defp ensure_session_tables(session_id, table_name) do
    with {:ok, _pid} <- DataTable.ensure_started(session_id),
         :ok <-
           DataTable.ensure_table(
             session_id,
             table_name,
             DataTableSchemas.library_schema()
           ),
         :ok <-
           DataTable.ensure_table(session_id, "meta", DataTableSchemas.meta_schema()) do
      :ok
    else
      {:error, reason} -> {:error, {:ensure_table_failed, reason}}
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Seam invocation
  # ──────────────────────────────────────────────────────────────────────

  defp run_seam(%Scope{} = scope, table_name, agent_id, seam_input) do
    on_partial = fn
      :meta, %{} = meta -> handle_meta(scope, agent_id, meta)
      :skill, %{} = skill -> handle_skill(scope, agent_id, table_name, skill)
      _, _ -> :ok
    end

    case generate_fn().(seam_input, on_partial) do
      {:ok, %{} = result} ->
        # Reconcile from the caller process: ensures the final result lands
        # even when streaming partials never fired (some models buffer the
        # whole response). add_skill dedupes by skill_name and set_meta is
        # an upsert, so the replay is idempotent.
        reconcile_final_result(scope, agent_id, table_name, result)

        state = %{
          added: read_added_rows(scope.session_id, table_name),
          meta_set?: meta_present?(scope.session_id)
        }

        skills = extract_skills(result)
        {:ok, state, length(skills)}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_generate_result, other}}
    end
  end

  defp reconcile_final_result(%Scope{} = scope, agent_id, table_name, result) do
    handle_meta(scope, agent_id, %{
      name: get(result, :name),
      description: get(result, :description)
    })

    result
    |> extract_skills()
    |> Enum.each(&handle_skill(scope, agent_id, table_name, &1))
  end

  defp handle_meta(%Scope{} = scope, agent_id, meta) do
    attrs = %{
      name: get(meta, :name),
      description: get(meta, :description)
    }

    if blank?(attrs.name) or blank?(attrs.description) do
      :ok
    else
      case Workbench.set_meta(scope, attrs) do
        {:ok, _row} ->
          broadcast_partial(scope, agent_id, "→ meta: #{attrs.name}")
          :ok

        {:error, reason} ->
          Logger.warning(fn ->
            "[GenerateFrameworkSkeletons] set_meta failed: #{inspect(reason)}"
          end)

          :ok
      end
    end
  end

  defp handle_skill(%Scope{} = scope, agent_id, table_name, skill) do
    case to_row(skill) do
      {:ok, row} ->
        case Workbench.add_skill(scope, row, table: table_name) do
          {:ok, _row} ->
            broadcast_partial(scope, agent_id, "→ skill: #{row.skill_name}")
            :ok

          {:error, {:duplicate_skill_name, _}} ->
            :ok

          {:error, reason} ->
            Logger.warning(fn ->
              "[GenerateFrameworkSkeletons] add_skill failed: #{inspect(reason)} " <>
                "table=#{inspect(table_name)} row=#{inspect(row)}"
            end)

            :ok
        end

      :skip ->
        :ok
    end
  end

  defp read_added_rows(session_id, table_name) do
    case DataTable.get_rows(session_id, table: table_name) do
      rows when is_list(rows) ->
        Enum.map(rows, fn row ->
          %{
            name: row[:skill_name] || row["skill_name"],
            category: row[:category] || row["category"],
            cluster: row[:cluster] || row["cluster"]
          }
        end)

      _ ->
        []
    end
  end

  defp meta_present?(session_id) do
    case DataTable.get_rows(session_id, table: "meta") do
      [_ | _] -> true
      _ -> false
    end
  end

  defp to_row(skill) when is_map(skill) do
    name = get(skill, :name)
    cluster = get(skill, :cluster)
    description = get(skill, :description)
    category = get(skill, :category)

    if blank?(name) or blank?(cluster) or blank?(description) or blank?(category) do
      :skip
    else
      {:ok,
       %{
         skill_name: name,
         cluster: cluster,
         category: category,
         skill_description: description
       }}
    end
  end

  defp to_row(_), do: :skip

  # ──────────────────────────────────────────────────────────────────────
  # Seam input
  # ──────────────────────────────────────────────────────────────────────

  defp build_seam_input(name, description, input, requested, scope_mode) do
    %{
      name: name,
      description: description,
      target_roles: blank_to_dash(input[:target_roles] || input["target_roles"]),
      seeds:
        blank_to_dash(
          input[:seeds] || input["seeds"] ||
            input[:similar_role_skills] || input["similar_role_skills"]
        ),
      research: blank_to_dash(input[:research] || input["research"]),
      existing_skills: render_existing_skills(input, scope_mode),
      gaps: render_gaps(input, scope_mode),
      skill_count: Integer.to_string(requested)
    }
  end

  defp render_existing_skills(_input, :full), do: "(none)"

  defp render_existing_skills(input, :gaps_only) do
    seed_skills = input[:seed_skills] || input["seed_skills"]

    case seed_skills do
      list when is_list(list) and list != [] -> format_seed_skills(list)
      _ -> "(none)"
    end
  end

  defp render_gaps(_input, :full), do: "(none)"

  defp render_gaps(input, :gaps_only) do
    gaps = input[:gaps] || input["gaps"]

    case gaps do
      list when is_list(list) and list != [] -> format_gaps(list)
      _ -> "(none)"
    end
  end

  defp format_seed_skills(rows) do
    rows
    |> Enum.map_join("\n", fn row ->
      name = get(row, :skill_name) || get(row, :name) || "?"
      cat = get(row, :category) || ""
      cluster = get(row, :cluster) || ""

      "- #{name} [#{cat}#{if cluster == "", do: "", else: " / #{cluster}"}]"
    end)
  end

  defp format_gaps(rows) do
    rows
    |> Enum.map_join("\n", fn row ->
      name = get(row, :skill_name) || "?"
      cat = get(row, :category) || ""
      rationale = get(row, :rationale) || ""

      "- #{name} [#{cat}]" <> if(rationale == "", do: "", else: " — #{rationale}")
    end)
  end

  defp parse_scope(:gaps_only), do: :gaps_only
  defp parse_scope("gaps_only"), do: :gaps_only
  defp parse_scope(_), do: :full

  defp resolve_table_name(name, input, _scope_mode) do
    case input[:table_name] || input["table_name"] do
      tbl when is_binary(tbl) and tbl != "" -> tbl
      _ -> Editor.table_name(name)
    end
  end

  defp blank_to_dash(nil), do: "(none)"
  defp blank_to_dash(""), do: "(none)"
  defp blank_to_dash(s) when is_binary(s), do: s
  defp blank_to_dash(_), do: "(none)"

  # ──────────────────────────────────────────────────────────────────────
  # Verbose-progress broadcast (Open mode picks this up via FlowLive)
  # ──────────────────────────────────────────────────────────────────────

  defp broadcast_partial(%Scope{session_id: nil}, _agent_id, _line), do: :ok

  defp broadcast_partial(%Scope{session_id: session_id}, agent_id, line)
       when is_binary(session_id) do
    # Attribute to the chat agent so the partial appends to its chat
    # thread bubble. Falling back to session_id sends it to a phantom
    # tab that has no UI.
    event_agent_id = agent_id || session_id

    event =
      Rho.Events.event(:structured_partial, session_id, event_agent_id, %{
        text: line <> "\n",
        source: :flow_use_case
      })

    Rho.Events.broadcast(session_id, event)

    # BAML streaming runs in a spawned worker process — its callbacks
    # don't go through the runner's `emit`, so the agent's turn watchdog
    # (60s) never sees activity. Tickle the agent worker directly so it
    # stays alive while the LLM is producing output.
    Rho.Agent.Worker.touch_activity(agent_id)
  end

  # ──────────────────────────────────────────────────────────────────────
  # Default seam — wraps LLM.GenerateSkeleton.stream/3
  # ──────────────────────────────────────────────────────────────────────

  defp generate_fn do
    Application.get_env(:rho_frameworks, :generate_skeleton_fn, &__MODULE__.default_generate/2)
  end

  @doc """
  Default `:generate_skeleton_fn` — bridges `LLM.GenerateSkeleton.stream/3`
  to the `(input, on_partial)` shape.

  Tracks (a) whether meta has been forwarded and (b) how many fully
  formed skills have been forwarded so each new entry surfaces exactly
  once as the BAML structured stream grows.
  """
  @spec default_generate(map(), (atom(), map() -> any())) ::
          {:ok, map()} | {:error, term()}
  def default_generate(input, on_partial) do
    pd_meta_key = {__MODULE__, :default_meta_set?, make_ref()}
    pd_count_key = {__MODULE__, :default_skill_count, make_ref()}
    Process.put(pd_meta_key, false)
    Process.put(pd_count_key, 0)

    callback = fn partial ->
      maybe_emit_meta(partial, on_partial, pd_meta_key)
      maybe_emit_skills(partial, on_partial, pd_count_key)
    end

    try do
      case LLM.stream(input, callback) do
        {:ok, %LLM{name: name, description: description, skills: skills}} ->
          {:ok, %{name: name, description: description, skills: normalize_skills(skills)}}

        {:error, reason} ->
          {:error, reason}
      end
    after
      Process.delete(pd_meta_key)
      Process.delete(pd_count_key)
    end
  end

  defp maybe_emit_meta(partial, on_partial, pd_meta_key) do
    if Process.get(pd_meta_key) do
      :ok
    else
      name = get(partial, :name)
      description = get(partial, :description)

      if not blank?(name) and not blank?(description) do
        on_partial.(:meta, %{name: name, description: description})
        Process.put(pd_meta_key, true)
      end
    end
  end

  defp maybe_emit_skills(partial, on_partial, pd_count_key) do
    skills = extract_skills(partial)
    already = Process.get(pd_count_key, 0)

    newly =
      skills
      |> Enum.drop(already)
      |> Enum.take_while(&fully_formed_skill?/1)

    Enum.each(newly, fn skill -> on_partial.(:skill, skill) end)
    Process.put(pd_count_key, already + length(newly))
  end

  defp extract_skills(partial) when is_map(partial) do
    case get(partial, :skills) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp extract_skills(_), do: []

  defp fully_formed_skill?(skill) when is_map(skill) do
    not blank?(get(skill, :name)) and
      not blank?(get(skill, :cluster)) and
      not blank?(get(skill, :description)) and
      not blank?(get(skill, :category))
  end

  defp fully_formed_skill?(_), do: false

  defp normalize_skills(skills) when is_list(skills) do
    Enum.map(skills, fn skill ->
      %{
        category: get(skill, :category),
        cluster: get(skill, :cluster),
        name: get(skill, :name),
        description: get(skill, :description),
        cited_findings: get(skill, :cited_findings) || []
      }
    end)
  end

  defp normalize_skills(_), do: []

  # ──────────────────────────────────────────────────────────────────────
  # Misc
  # ──────────────────────────────────────────────────────────────────────

  defp parse_skill_count(nil), do: @default_skill_count
  defp parse_skill_count(n) when is_integer(n) and n > 0, do: n

  defp parse_skill_count(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} when n > 0 -> n
      _ -> @default_skill_count
    end
  end

  defp parse_skill_count(_), do: @default_skill_count

  defp get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp get(_, _), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end