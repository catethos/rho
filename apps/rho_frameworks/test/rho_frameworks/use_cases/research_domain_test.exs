defmodule RhoFrameworks.UseCases.ResearchDomainTest do
  use ExUnit.Case, async: false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.UseCases.ResearchDomain
  alias RhoFrameworks.{DataTableSchemas, Scope}

  setup do
    session_id = "sess-research-#{System.unique_integer([:positive])}"
    parent = self()

    spawn_fn = fn opts ->
      send(parent, {:spawn_called, opts})
      {:ok, "fixture-research-agent-#{System.unique_integer([:positive])}"}
    end

    Application.put_env(:rho_frameworks, :research_domain_spawn_fn, spawn_fn)

    on_exit(fn ->
      Application.delete_env(:rho_frameworks, :research_domain_spawn_fn)
      DataTable.stop(session_id)
    end)

    scope = %Scope{organization_id: "org-test", session_id: session_id}
    %{scope: scope, session_id: session_id}
  end

  describe "describe/0" do
    test "advertises :agent_loop cost hint" do
      assert %{id: :research_domain, cost_hint: :agent} = ResearchDomain.describe()
    end
  end

  describe "table_name/0" do
    test "returns the canonical research_notes table name" do
      assert ResearchDomain.table_name() == "research_notes"
    end
  end

  describe "run/2" do
    test "ensures the research_notes table and spawns a worker", %{scope: scope} do
      assert {:async, %{agent_id: agent_id, table_name: "research_notes"}} =
               ResearchDomain.run(
                 %{name: "Eng", description: "engineering", domain: "software"},
                 scope
               )

      assert is_binary(agent_id)
      assert_received {:spawn_called, opts}
      assert opts[:session_id] == scope.session_id
      assert opts[:agent_name] == :researcher
      tool_names = Enum.map(opts[:tools], fn t -> t.tool.name end)
      assert "web_fetch" in tool_names
      assert "save_finding" in tool_names
      assert "finish" in tool_names

      # research_notes table is now usable for downstream callers (panel,
      # build_input).
      assert {:ok, %{schema: schema}} =
               DataTable.get_table_snapshot(scope.session_id, "research_notes")

      assert schema.name == "research_notes"
    end

    test "propagates spawn failures as {:error, {:spawn_failed, reason}}", %{scope: scope} do
      Application.put_env(:rho_frameworks, :research_domain_spawn_fn, fn _opts ->
        {:error, :nope}
      end)

      assert {:error, {:spawn_failed, :nope}} = ResearchDomain.run(%{}, scope)
    end

    test "errors when scope has no session_id" do
      scope = %Scope{organization_id: "org-test", session_id: nil}

      # ensure_research_table guards on missing session
      assert {:error, :missing_session_id} = ResearchDomain.run(%{}, scope)
    end
  end

  describe "research_notes table" do
    test "schema accepts pinned booleans + supports update_cells round-trip", %{scope: scope} do
      {:async, _} = ResearchDomain.run(%{name: "Eng"}, scope)

      assert {:ok, [row]} =
               DataTable.add_rows(
                 scope.session_id,
                 [%{source: "https://example.com", fact: "Backends use Erlang", pinned: false}],
                 table: "research_notes"
               )

      assert :ok =
               DataTable.update_cells(
                 scope.session_id,
                 [%{id: row[:id] || row["id"], field: :pinned, value: true}],
                 table: "research_notes"
               )

      pinned =
        DataTable.get_rows(scope.session_id, table: "research_notes")
        |> Enum.filter(fn r -> Map.get(r, :pinned) || Map.get(r, "pinned") end)

      assert match?([_], pinned)
    end

    test "schema is the one declared in DataTableSchemas" do
      schema = DataTableSchemas.research_notes_schema()
      assert schema.name == "research_notes"
      column_names = Enum.map(schema.columns, & &1.name)
      assert :source in column_names
      assert :fact in column_names
      assert :tag in column_names
      assert :pinned in column_names
    end
  end
end
