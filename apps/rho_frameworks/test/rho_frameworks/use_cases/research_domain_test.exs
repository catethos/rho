defmodule RhoFrameworks.UseCases.ResearchDomainTest do
  use ExUnit.Case, async: false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.UseCases.ResearchDomain
  alias RhoFrameworks.{DataTableSchemas, Scope}

  setup do
    session_id = "sess-research-#{System.unique_integer([:positive])}"

    Application.put_env(:rho_frameworks, :exa_client, __MODULE__.FakeExaClient)
    Application.put_env(:rho_frameworks, :fake_exa_test_pid, self())
    Application.delete_env(:rho_frameworks, :fake_exa_error)
    Application.delete_env(:rho_frameworks, :fake_exa_error_queries)
    Application.delete_env(:rho_frameworks, :fake_exa_results)

    on_exit(fn ->
      Application.delete_env(:rho_frameworks, :exa_client)
      Application.delete_env(:rho_frameworks, :fake_exa_test_pid)
      Application.delete_env(:rho_frameworks, :fake_exa_error)
      Application.delete_env(:rho_frameworks, :fake_exa_error_queries)
      Application.delete_env(:rho_frameworks, :fake_exa_results)
      DataTable.stop(session_id)
    end)

    scope = %Scope{organization_id: "org-test", session_id: session_id}
    %{scope: scope, session_id: session_id}
  end

  describe "describe/0" do
    test "advertises network cost hint" do
      assert %{id: :research_domain, cost_hint: :network} = ResearchDomain.describe()
    end
  end

  describe "table_name/0" do
    test "returns the canonical research_notes table name" do
      assert ResearchDomain.table_name() == "research_notes"
    end
  end

  describe "run/2" do
    test "ensures the research_notes table and inserts pinned Exa summaries", %{scope: scope} do
      assert {:ok, %{inserted: 3, seen: 12, failed_queries: 0, table_name: "research_notes"}} =
               ResearchDomain.run(
                 %{name: "Eng", description: "engineering", domain: "software"},
                 scope
               )

      searches = collect_searches(3)
      assert Enum.any?(searches, fn {query, _opts} -> query =~ "Eng" end)

      assert Enum.all?(searches, fn {_query, opts} ->
               opts[:summary_query] == "Eng - engineering"
             end)

      assert {:ok, %{schema: schema}} =
               DataTable.get_table_snapshot(scope.session_id, "research_notes")

      assert schema.name == "research_notes"

      rows = DataTable.get_rows(scope.session_id, table: "research_notes")
      assert Enum.all?(rows, &Rho.MapAccess.get(&1, :pinned))

      assert Enum.map(rows, &Rho.MapAccess.get(&1, :fact)) == [
               "Summary A",
               "Highlight B",
               "Title C"
             ]

      assert Enum.map(rows, &Rho.MapAccess.get(&1, :source_title)) == [
               "Title A",
               "Title B",
               "Title C"
             ]

      assert Enum.map(rows, &Rho.MapAccess.get(&1, :published_date)) == [
               "2025-01-01",
               "2025-01-02",
               nil
             ]
    end

    test "propagates Exa failures when every query fails", %{scope: scope} do
      Application.put_env(:rho_frameworks, :fake_exa_error, {:exa_failed, :nope})

      assert {:error, {:exa_failed, :nope}} = ResearchDomain.run(%{}, scope)
    end

    test "keeps successful rows when one Exa query fails", %{scope: scope} do
      Application.put_env(:rho_frameworks, :fake_exa_error_queries, ["professional standards"])

      assert {:ok, %{inserted: 3, seen: 8, failed_queries: 1, table_name: "research_notes"}} =
               ResearchDomain.run(%{name: "Risk Analyst"}, scope)

      assert length(DataTable.get_rows(scope.session_id, table: "research_notes")) == 3
    end

    test "returns an empty summary when Exa has no usable rows", %{scope: scope} do
      Application.put_env(:rho_frameworks, :fake_exa_results, [])

      assert {:ok, %{inserted: 0, seen: 0, failed_queries: 0, table_name: "research_notes"}} =
               ResearchDomain.run(%{name: "No hits"}, scope)

      assert DataTable.get_rows(scope.session_id, table: "research_notes") == []
    end

    test "upgrades an existing legacy research_notes schema", %{scope: scope} do
      {:ok, _pid} = DataTable.ensure_started(scope.session_id)

      :ok =
        DataTable.ensure_table(
          scope.session_id,
          "research_notes",
          legacy_research_schema()
        )

      {:ok, [_]} =
        DataTable.add_rows(
          scope.session_id,
          [%{source: "user", fact: "Keep this existing note", tag: "manual", pinned: true}],
          table: "research_notes"
        )

      assert {:ok, %{inserted: 3, failed_queries: 0}} =
               ResearchDomain.run(%{name: "Risk Analyst"}, scope)

      {:ok, schema} = DataTable.get_schema(scope.session_id, "research_notes")
      column_names = Enum.map(schema.columns, & &1.name)

      assert :source_title in column_names
      assert :published_date in column_names
      assert :relevance in column_names

      rows = DataTable.get_rows(scope.session_id, table: "research_notes")
      assert Enum.any?(rows, &(Rho.MapAccess.get(&1, :fact) == "Keep this existing note"))
    end

    test "errors when scope has no session_id" do
      scope = %Scope{organization_id: "org-test", session_id: nil}

      # ensure_research_table guards on missing session
      assert {:error, :missing_session_id} = ResearchDomain.run(%{}, scope)
    end
  end

  describe "research_notes table" do
    test "schema accepts pinned booleans + supports update_cells round-trip", %{scope: scope} do
      {:ok, _pid} = DataTable.ensure_started(scope.session_id)

      :ok =
        DataTable.ensure_table(
          scope.session_id,
          "research_notes",
          DataTableSchemas.research_notes_schema()
        )

      assert {:ok, [row]} =
               DataTable.add_rows(
                 scope.session_id,
                 [%{source: "https://example.com", fact: "Backends use Erlang", pinned: false}],
                 table: "research_notes"
               )

      assert :ok =
               DataTable.update_cells(
                 scope.session_id,
                 [%{id: Rho.MapAccess.get(row, :id), field: :pinned, value: true}],
                 table: "research_notes"
               )

      pinned =
        DataTable.get_rows(scope.session_id, table: "research_notes")
        |> Enum.filter(fn r -> Rho.MapAccess.get(r, :pinned) end)

      assert match?([_], pinned)
    end

    test "schema is the one declared in DataTableSchemas" do
      schema = DataTableSchemas.research_notes_schema()
      assert schema.name == "research_notes"
      column_names = Enum.map(schema.columns, & &1.name)
      assert :source in column_names
      assert :source_title in column_names
      assert :fact in column_names
      assert :published_date in column_names
      assert :relevance in column_names
      assert :tag in column_names
      assert :pinned in column_names
    end
  end

  defmodule FakeExaClient do
    def search(query, opts) do
      Application.get_env(:rho_frameworks, :fake_exa_test_pid)
      |> send({:exa_search, query, opts})

      cond do
        reason = Application.get_env(:rho_frameworks, :fake_exa_error) ->
          {:error, reason}

        query_failed?(query) ->
          {:error, {:exa_failed, :query_failed}}

        true ->
          {:ok, Application.get_env(:rho_frameworks, :fake_exa_results, default_results())}
      end
    end

    defp query_failed?(query) do
      :rho_frameworks
      |> Application.get_env(:fake_exa_error_queries, [])
      |> Enum.any?(&String.contains?(query, &1))
    end

    defp default_results do
      [
        %{
          url: "https://example.com/a",
          title: "Title A",
          summary: "Summary A",
          published_date: "2025-01-01",
          score: 0.91234
        },
        %{
          url: "https://example.com/b",
          title: "Title B",
          highlights: ["Highlight B"],
          published_date: "2025-01-02"
        },
        %{url: "https://example.com/c", title: "Title C"},
        %{url: "https://example.com/a", title: "Duplicate A", summary: "Duplicate"}
      ]
    end
  end

  defp collect_searches(count) do
    Enum.map(1..count, fn _ ->
      assert_receive {:exa_search, query, opts}
      {query, opts}
    end)
  end

  defp legacy_research_schema do
    %Rho.Stdlib.DataTable.Schema{
      name: "research_notes",
      mode: :strict,
      columns: [
        %Rho.Stdlib.DataTable.Schema.Column{name: :source, type: :string, required?: true},
        %Rho.Stdlib.DataTable.Schema.Column{name: :fact, type: :string, required?: true},
        %Rho.Stdlib.DataTable.Schema.Column{name: :tag, type: :string},
        %Rho.Stdlib.DataTable.Schema.Column{name: :pinned, type: :boolean},
        %Rho.Stdlib.DataTable.Schema.Column{name: :_source, type: :string}
      ],
      key_fields: [:source, :fact]
    }
  end
end
