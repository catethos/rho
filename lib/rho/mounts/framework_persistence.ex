defmodule Rho.Mounts.FrameworkPersistence do
  @moduledoc """
  Mount that provides tools for saving, loading, searching, comparing,
  and deduplicating skill frameworks in the database.

  All operations are scoped to the current user via context.user_id.
  """

  @behaviour Rho.Mount

  alias Rho.Frameworks
  alias Rho.Comms

  @spreadsheet_registry :rho_spreadsheet_registry
  @stream_batch_size 5

  @impl Rho.Mount
  def tools(_mount_opts, %{user_id: nil}), do: []
  def tools(_mount_opts, %{user_id: _} = context), do: build_tools(context)
  def tools(_mount_opts, _context), do: []

  defp build_tools(context) do
    user_id = context.user_id
    session_id = context.session_id

    [
      save_framework_tool(user_id, session_id),
      load_framework_tool(user_id, session_id, context.agent_id),
      list_frameworks_tool(user_id),
      delete_framework_tool(user_id),
      search_frameworks_tool(user_id),
      compare_frameworks_tool(user_id),
      find_duplicates_tool(user_id)
    ]
  end

  # --- Tool definitions ---

  defp save_framework_tool(user_id, session_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "save_framework",
          description:
            "Save the current spreadsheet as a named skill framework. Each framework name must be unique per user.",
          parameter_schema: [
            name: [type: :string, required: true, doc: "Unique name for this framework"],
            description: [
              type: :string,
              required: false,
              doc: "Brief description of the framework"
            ],
            overwrite: [
              type: :boolean,
              required: false,
              doc: "If true, overwrite existing framework with same name. Default: false"
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        name = args["name"] || args[:name]
        description = args["description"] || args[:description] || ""
        overwrite = args["overwrite"] || args[:overwrite] || false

        if is_nil(name) or name == "" do
          {:error, "Framework name is required"}
        else
          rows = read_spreadsheet_rows(session_id)

          if rows == [] do
            {:error, "Spreadsheet is empty — nothing to save"}
          else
            case Frameworks.save_framework(user_id, name, description, rows, overwrite: overwrite) do
              {:ok, %{framework: fw, skills: count}} ->
                {:ok, "Saved framework '#{fw.name}' with #{count} skill rows"}

              {:error, :name_taken, _} ->
                {:error,
                 "A framework named '#{name}' already exists. Use overwrite: true to replace it."}

              {:error, _step, changeset, _} ->
                {:error, "Save failed: #{inspect(changeset.errors)}"}
            end
          end
        end
      end
    }
  end

  defp load_framework_tool(user_id, session_id, agent_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "load_framework",
          description:
            "Load a saved skill framework into the spreadsheet by name. Replaces current spreadsheet data.",
          parameter_schema: [
            name: [type: :string, required: true, doc: "Name of the framework to load"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        name = args["name"] || args[:name]

        case Frameworks.get_framework_with_skills(user_id, name) do
          nil ->
            {:error, "Framework '#{name}' not found"}

          framework ->
            rows =
              Enum.map(framework.skills, fn s ->
                %{
                  category: s.category,
                  cluster: s.cluster,
                  skill_name: s.skill_name,
                  skill_description: s.skill_description || "",
                  level: s.level,
                  level_name: s.level_name || "",
                  level_description: s.level_description || ""
                }
              end)

            # Clear spreadsheet then stream rows
            publish_spreadsheet_event(session_id, agent_id, :replace_all, %{})
            stream_rows_progressive(rows, session_id, agent_id)

            {:ok, "Loaded framework '#{name}' with #{length(rows)} rows into the spreadsheet"}
        end
      end
    }
  end

  defp list_frameworks_tool(user_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "list_frameworks",
          description: "List all saved skill frameworks for the current user.",
          parameter_schema: [],
          callback: fn _args -> :ok end
        ),
      execute: fn _args ->
        frameworks = Frameworks.list_frameworks(user_id)

        result =
          Enum.map(frameworks, fn fw ->
            %{
              name: fw.name,
              description: fw.description,
              skill_count: fw.skill_count,
              updated_at: to_string(fw.updated_at)
            }
          end)

        {:ok, Jason.encode!(result)}
      end
    }
  end

  defp delete_framework_tool(user_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "delete_framework",
          description: "Delete a saved skill framework by name.",
          parameter_schema: [
            name: [type: :string, required: true, doc: "Name of the framework to delete"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        name = args["name"] || args[:name]

        case Frameworks.delete_framework(user_id, name) do
          {:ok, _} -> {:ok, "Deleted framework '#{name}'"}
          {:error, :not_found} -> {:error, "Framework '#{name}' not found"}
        end
      end
    }
  end

  defp search_frameworks_tool(user_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "search_frameworks",
          description:
            "Search across saved skill frameworks by keyword. Searches skill names, descriptions, categories, clusters, and level descriptions.",
          parameter_schema: [
            query: [type: :string, required: true, doc: "Search keyword(s)"],
            framework_name: [
              type: :string,
              required: false,
              doc: "Limit search to a specific framework"
            ],
            category: [type: :string, required: false, doc: "Filter by category"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        query = args["query"] || args[:query] || ""

        opts =
          []
          |> maybe_add_opt(:framework_name, args["framework_name"] || args[:framework_name])
          |> maybe_add_opt(:category, args["category"] || args[:category])

        results = Frameworks.search_skills(user_id, query, opts)
        {:ok, Jason.encode!(results)}
      end
    }
  end

  defp compare_frameworks_tool(user_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "compare_frameworks",
          description:
            "Cross-reference two or more saved skill frameworks. Shows shared skills, unique skills per framework, and coverage gaps.",
          parameter_schema: [
            framework_names_json: [
              type: :string,
              required: true,
              doc: ~s(JSON array of framework names, e.g. ["Framework A", "Framework B"])
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        raw = args["framework_names_json"] || args[:framework_names_json] || "[]"

        case Jason.decode(raw) do
          {:ok, names} when is_list(names) and length(names) >= 2 ->
            result = Frameworks.compare_frameworks(user_id, names)
            {:ok, Jason.encode!(result)}

          {:ok, _} ->
            {:error, "Provide at least 2 framework names to compare"}

          {:error, _} ->
            {:error, "Invalid JSON. Pass a JSON array of framework names."}
        end
      end
    }
  end

  defp find_duplicates_tool(user_id) do
    %{
      tool:
        ReqLLM.tool(
          name: "find_duplicates",
          description:
            "Find duplicate skills within a framework or across all frameworks. Groups by normalized skill name and category.",
          parameter_schema: [
            framework_name: [
              type: :string,
              required: false,
              doc: "Search within a specific framework. Omit to search across all."
            ]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args ->
        opts =
          maybe_add_opt([], :framework_name, args["framework_name"] || args[:framework_name])

        results = Frameworks.find_duplicates(user_id, opts)
        {:ok, Jason.encode!(results)}
      end
    }
  end

  # --- Helpers ---

  defp read_spreadsheet_rows(session_id) do
    ensure_table()

    case :ets.lookup(@spreadsheet_registry, session_id) do
      [{_, pid}] when is_pid(pid) ->
        if Process.alive?(pid) do
          ref = make_ref()
          send(pid, {:spreadsheet_get_table, {self(), ref}, nil})

          receive do
            {^ref, {:ok, rows}} -> rows
          after
            5_000 -> []
          end
        else
          []
        end

      _ ->
        []
    end
  end

  defp ensure_table do
    if :ets.whereis(@spreadsheet_registry) == :undefined do
      :ets.new(@spreadsheet_registry, [:named_table, :public, :set, read_concurrency: true])
    end
  rescue
    ArgumentError -> :ok
  end

  defp stream_rows_progressive(rows, session_id, agent_id) do
    rows
    |> Enum.chunk_every(@stream_batch_size)
    |> Enum.with_index()
    |> Enum.each(fn {batch, idx} ->
      if idx > 0, do: Process.sleep(30)

      publish_spreadsheet_event(session_id, agent_id, :rows_delta, %{
        rows: batch,
        op: :add
      })
    end)
  end

  defp publish_spreadsheet_event(session_id, agent_id, event_type, payload) do
    topic = "rho.session.#{session_id}.events.spreadsheet_#{event_type}"
    source = "/session/#{session_id}/agent/#{agent_id}"

    Comms.publish(
      topic,
      Map.merge(payload, %{session_id: session_id, agent_id: agent_id}),
      source: source
    )
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, _key, ""), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
