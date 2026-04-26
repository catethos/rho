defmodule Rho.Stdlib.DataTableTest do
  use ExUnit.Case, async: false

  alias Rho.Stdlib.DataTable
  alias Rho.Stdlib.DataTable.Schema
  alias Rho.Stdlib.DataTable.Schema.Column

  setup do
    session_id = "test_sess_#{System.unique_integer([:positive])}"
    on_exit(fn -> DataTable.stop(session_id) end)
    {:ok, session_id: session_id}
  end

  defp library_schema do
    %Schema{
      name: "library",
      mode: :strict,
      columns: [
        %Column{name: :category, type: :string, required?: true},
        %Column{name: :skill_name, type: :string, required?: true},
        %Column{name: :skill_description, type: :string}
      ],
      children_key: :proficiency_levels,
      child_columns: [
        %Column{name: :level, type: :integer, required?: true},
        %Column{name: :level_name, type: :string}
      ],
      key_fields: [:skill_name]
    }
  end

  describe "ensure_started/1" do
    test "starts a server and is idempotent", %{session_id: sid} do
      assert {:ok, pid} = DataTable.ensure_started(sid)
      assert is_pid(pid) and Process.alive?(pid)
      assert {:ok, ^pid} = DataTable.ensure_started(sid)
    end

    test "concurrent ensure_started converges to a single server", %{session_id: sid} do
      parent = self()

      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            {:ok, pid} = DataTable.ensure_started(sid)
            send(parent, {:got, pid})
            pid
          end)
        end

      pids = tasks |> Enum.map(&Task.await/1) |> Enum.uniq()
      assert length(pids) == 1
    end
  end

  describe "main table" do
    test "is eagerly created with a dynamic schema", %{session_id: sid} do
      DataTable.ensure_started(sid)
      snapshot = DataTable.get_session_snapshot(sid)
      assert [%{name: "main"} | _] = snapshot.tables
      assert {:ok, main} = DataTable.get_table_snapshot(sid, "main")
      assert main.rows == []
      assert main.schema.mode == :dynamic
    end

    test "accepts arbitrary keys", %{session_id: sid} do
      DataTable.ensure_started(sid)

      assert {:ok, [row]} =
               DataTable.add_rows(sid, [%{"foo" => "bar", "baz" => 1}])

      assert row["foo"] == "bar"
      assert row["baz"] == 1
      assert is_binary(row.id)
    end

    test "write-then-read sees newly added rows (no race)", %{session_id: sid} do
      DataTable.ensure_started(sid)
      assert {:ok, [_, _]} = DataTable.add_rows(sid, [%{"a" => 1}, %{"a" => 2}])
      rows = DataTable.get_rows(sid)
      assert length(rows) == 2
    end
  end

  describe "strict schemas" do
    test "ensure_table creates a typed table", %{session_id: sid} do
      assert :ok = DataTable.ensure_table(sid, "library", library_schema())

      tables = DataTable.list_tables(sid)
      assert Enum.any?(tables, &(&1.name == "library"))
    end

    test "ensure_table is idempotent on identical schema", %{session_id: sid} do
      assert :ok = DataTable.ensure_table(sid, "library", library_schema())
      assert :ok = DataTable.ensure_table(sid, "library", library_schema())
    end

    test "ensure_table rejects incompatible schema", %{session_id: sid} do
      assert :ok = DataTable.ensure_table(sid, "library", library_schema())

      different = %Schema{
        mode: :strict,
        columns: [%Column{name: :other, type: :string}]
      }

      assert {:error, :schema_mismatch} =
               DataTable.ensure_table(sid, "library", different)
    end

    test "rejects unknown fields in strict mode", %{session_id: sid} do
      DataTable.ensure_table(sid, "library", library_schema())

      row = %{
        category: "Engineering",
        skill_name: "Foo",
        bogus: "nope"
      }

      assert {:error, {:unknown_fields, _}} =
               DataTable.add_rows(sid, [row], table: "library")
    end

    test "rejects missing required fields", %{session_id: sid} do
      DataTable.ensure_table(sid, "library", library_schema())

      assert {:error, {:missing_required, _}} =
               DataTable.add_rows(sid, [%{category: "Engineering"}], table: "library")
    end

    test "coerces primitive types", %{session_id: sid} do
      DataTable.ensure_table(sid, "library", library_schema())

      row = %{
        category: "Eng",
        skill_name: "Foo",
        proficiency_levels: [%{level: "3", level_name: "Advanced"}]
      }

      assert {:ok, [inserted]} = DataTable.add_rows(sid, [row], table: "library")
      assert [%{level: 3}] = inserted.proficiency_levels
    end

    test "never atom-leaks from unknown string keys", %{session_id: sid} do
      DataTable.ensure_started(sid)
      # Dynamic "main" table with an atom-looking string should NOT create an atom
      fake_key = "not_a_real_atom_#{System.unique_integer([:positive])}"
      assert {:ok, [row]} = DataTable.add_rows(sid, [%{fake_key => 1}])
      assert Map.has_key?(row, fake_key)

      # Verify the key was never converted to an atom
      assert_raise ArgumentError, fn -> String.to_existing_atom(fake_key) end
    end
  end

  describe "get/update/delete" do
    test "get_rows with filter", %{session_id: sid} do
      DataTable.ensure_started(sid)

      DataTable.add_rows(sid, [
        %{"k" => "a"},
        %{"k" => "b"},
        %{"k" => "a"}
      ])

      assert length(DataTable.get_rows(sid)) == 3
      assert length(DataTable.get_rows(sid, filter: %{"k" => "a"})) == 2
    end

    test "delete_rows by id", %{session_id: sid} do
      DataTable.ensure_started(sid)
      {:ok, [r1, _r2]} = DataTable.add_rows(sid, [%{"k" => 1}, %{"k" => 2}])
      assert :ok = DataTable.delete_rows(sid, [r1.id])
      assert length(DataTable.get_rows(sid)) == 1
    end

    test "delete_by_filter", %{session_id: sid} do
      DataTable.ensure_started(sid)

      {:ok, _} =
        DataTable.add_rows(sid, [%{"k" => "a"}, %{"k" => "b"}, %{"k" => "a"}])

      assert {:ok, 2} = DataTable.delete_by_filter(sid, %{"k" => "a"})
      assert length(DataTable.get_rows(sid)) == 1
    end

    test "update_cells", %{session_id: sid} do
      DataTable.ensure_started(sid)
      {:ok, [row]} = DataTable.add_rows(sid, [%{"k" => "orig"}])

      assert :ok =
               DataTable.update_cells(sid, [
                 %{"id" => row.id, "field" => "k", "value" => "new"}
               ])

      [updated] = DataTable.get_rows(sid)
      assert updated["k"] == "new"
    end

    test "replace_all wipes and refills", %{session_id: sid} do
      DataTable.ensure_started(sid)
      DataTable.add_rows(sid, [%{"a" => 1}, %{"a" => 2}])
      assert {:ok, [_]} = DataTable.replace_all(sid, [%{"a" => 99}])
      assert [row] = DataTable.get_rows(sid)
      assert row["a"] == 99
    end
  end

  describe "version counter" do
    test "increments on every mutation", %{session_id: sid} do
      DataTable.ensure_started(sid)
      {:ok, %{version: v0}} = DataTable.get_table_snapshot(sid)

      DataTable.add_rows(sid, [%{"x" => 1}])
      {:ok, %{version: v1}} = DataTable.get_table_snapshot(sid)
      assert v1 > v0

      DataTable.add_rows(sid, [%{"x" => 2}])
      {:ok, %{version: v2}} = DataTable.get_table_snapshot(sid)
      assert v2 > v1
    end
  end

  describe "notifications" do
    test "publishes table_changed on mutation", %{session_id: sid} do
      DataTable.ensure_started(sid)
      Rho.Events.subscribe(sid)

      DataTable.add_rows(sid, [%{"x" => 1}])

      assert_receive %Rho.Events.Event{
                       kind: :data_table,
                       data: %{event: :table_changed, table_name: "main"}
                     },
                     500
    end

    test "publishes table_created on ensure_table", %{session_id: sid} do
      DataTable.ensure_started(sid)
      Rho.Events.subscribe(sid)

      DataTable.ensure_table(sid, "library", library_schema())

      assert_receive %Rho.Events.Event{
                       kind: :data_table,
                       data: %{event: :table_created, table_name: "library"}
                     },
                     500
    end
  end

  describe "crash behavior" do
    test "server stays down after crash (restart :temporary)", %{session_id: sid} do
      {:ok, pid} = DataTable.ensure_started(sid)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, _, _}, 500

      # Wait for supervisor to (NOT) restart
      Process.sleep(50)
      assert DataTable.Server.whereis(sid) == nil
    end

    test "reads return {:error, :not_running} after crash", %{session_id: sid} do
      {:ok, pid} = DataTable.ensure_started(sid)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, _, _}, 500
      Process.sleep(50)

      assert DataTable.get_rows(sid) == {:error, :not_running}
      assert DataTable.get_session_snapshot(sid) == {:error, :not_running}
      assert DataTable.get_table_snapshot(sid) == {:error, :not_running}
      assert DataTable.list_tables(sid) == {:error, :not_running}
    end

    test "writes return {:error, :not_running} after crash", %{session_id: sid} do
      {:ok, pid} = DataTable.ensure_started(sid)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, _, _}, 500
      Process.sleep(50)

      assert DataTable.add_rows(sid, [%{"name" => "x"}]) == {:error, :not_running}
      assert DataTable.update_cells(sid, []) == {:error, :not_running}
      assert DataTable.delete_rows(sid, []) == {:error, :not_running}
      assert DataTable.delete_by_filter(sid, %{"k" => "v"}) == {:error, :not_running}
      assert DataTable.replace_all(sid, []) == {:error, :not_running}
    end

    test "reads and writes return :not_running if never started", %{session_id: sid} do
      assert DataTable.get_rows(sid) == {:error, :not_running}
      assert DataTable.add_rows(sid, [%{"a" => 1}]) == {:error, :not_running}
    end

    test "ensure_table still starts the server on demand", %{session_id: sid} do
      schema = library_schema()
      assert :ok = DataTable.ensure_table(sid, "library", schema)
      assert is_pid(DataTable.whereis(sid))
    end
  end
end
