defmodule RhoFrameworks.UseCases.GenerateProficiencyTest do
  @moduledoc """
  Tests for the per-category proficiency-writer fan-out. The LLM call is
  replaced via the `:write_proficiency_levels_fn` Application env so
  these run without hitting BAML / OpenRouter.

  Workers run as detached `Task.Supervisor.start_child/2` children under
  `Rho.TaskSupervisor`. Each test that depends on persistence or events
  subscribes to the session topic and waits for the per-worker
  `:task_completed` events, so we don't poll DataTable in a sleep loop.
  """

  use ExUnit.Case, async: false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.{DataTableSchemas, Scope}
  alias RhoFrameworks.UseCases.GenerateProficiency

  @table "library:test"

  setup do
    session_id = "sess-prof-#{System.unique_integer([:positive])}"
    {:ok, _pid} = DataTable.ensure_started(session_id)
    :ok = DataTable.ensure_table(session_id, @table, DataTableSchemas.library_schema())

    on_exit(fn ->
      Application.delete_env(:rho_frameworks, :write_proficiency_levels_fn)
      DataTable.stop(session_id)
    end)

    :ok = Rho.Events.subscribe(session_id)

    scope = %Scope{
      organization_id: "org-test",
      session_id: session_id,
      user_id: "user-test",
      source: :flow,
      reason: "wizard:create-framework"
    }

    %{scope: scope, session_id: session_id}
  end

  defp seed_rows(session_id, rows) do
    {:ok, _} = DataTable.add_rows(session_id, rows, table: @table)
    :ok
  end

  defp put_seam(callback) do
    Application.put_env(:rho_frameworks, :write_proficiency_levels_fn, callback)
  end

  defp wait_for_completed(expected_count, timeout \\ 1_000) do
    do_wait_for_completed(expected_count, [], timeout)
  end

  defp do_wait_for_completed(0, acc, _timeout), do: Enum.reverse(acc)

  defp do_wait_for_completed(remaining, acc, timeout) do
    receive do
      %Rho.Events.Event{kind: :task_completed, data: data} ->
        do_wait_for_completed(remaining - 1, [data | acc], timeout)
    after
      timeout ->
        flunk(
          "did not receive #{remaining} more :task_completed events " <>
            "(got #{length(acc)} so far)"
        )
    end
  end

  defp library_rows(session_id) do
    DataTable.get_rows(session_id, table: @table)
  end

  defp by_skill_name(rows) do
    Enum.into(rows, %{}, fn row ->
      {row[:skill_name] || row["skill_name"], row}
    end)
  end

  defp dummy_levels do
    [
      %{level: 1, level_name: "Novice", level_description: "Follows procedures."},
      %{level: 2, level_name: "Advanced", level_description: "Owns outcomes."}
    ]
  end

  describe "describe/0" do
    test "advertises the cheap UseCase" do
      assert %{id: :generate_proficiency, cost_hint: :cheap} = GenerateProficiency.describe()
    end
  end

  describe "run/2 — input handling" do
    test "missing table_name returns :missing_table_name", %{scope: scope} do
      assert {:error, :missing_table_name} = GenerateProficiency.run(%{}, scope)
    end

    test "empty rows returns :empty_rows", %{scope: scope} do
      assert {:error, :empty_rows} =
               GenerateProficiency.run(%{table_name: @table, levels: 5}, scope)
    end
  end

  describe "run/2 — fan-out" do
    test "spawns one worker per category and returns worker descriptors", %{
      scope: scope,
      session_id: session_id
    } do
      seed_rows(session_id, [
        %{
          category: "Eng",
          cluster: "Tooling",
          skill_name: "Vim",
          skill_description: "Editor."
        },
        %{
          category: "Eng",
          cluster: "Tooling",
          skill_name: "Tmux",
          skill_description: "Multiplexer."
        },
        %{
          category: "Design",
          cluster: "Visual",
          skill_name: "Figma",
          skill_description: "Vector."
        }
      ])

      test_pid = self()

      put_seam(fn input, on_partial ->
        send(test_pid, {:seam, input.category, input.levels})

        # Pretend the model returns one fully-formed level per input skill.
        case input.category do
          "Eng" ->
            on_partial.(%{skill_name: "Vim", levels: dummy_levels()})
            on_partial.(%{skill_name: "Tmux", levels: dummy_levels()})

          "Design" ->
            on_partial.(%{skill_name: "Figma", levels: dummy_levels()})
        end

        {:ok, %{skills: []}}
      end)

      assert {:async, %{workers: workers}} =
               GenerateProficiency.run(%{table_name: @table, levels: 5}, scope)

      assert length(workers) == 2
      assert Enum.sort(Enum.map(workers, & &1.category)) == ["Design", "Eng"]
      assert Enum.find(workers, &(&1.category == "Eng")).count == 2
      assert Enum.find(workers, &(&1.category == "Design")).count == 1
      assert Enum.all?(workers, &is_binary(&1.agent_id))

      events = wait_for_completed(2)
      assert Enum.all?(events, &(&1.status == :ok)), "events: #{inspect(events)}"

      rows = by_skill_name(library_rows(session_id))

      for name <- ["Vim", "Tmux", "Figma"] do
        levels = rows[name][:proficiency_levels] || rows[name]["proficiency_levels"]

        assert is_list(levels) and length(levels) == 2,
               "expected #{name} to have 2 levels (row=#{inspect(rows[name])})"
      end
    end

    test "emits :task_requested at spawn and :task_completed per worker", %{
      scope: scope,
      session_id: session_id
    } do
      seed_rows(session_id, [
        %{
          category: "Eng",
          cluster: "T",
          skill_name: "Vim",
          skill_description: "Editor."
        }
      ])

      put_seam(fn _input, on_partial ->
        on_partial.(%{skill_name: "Vim", levels: dummy_levels()})
        {:ok, %{skills: []}}
      end)

      assert {:async, %{workers: [worker]}} =
               GenerateProficiency.run(%{table_name: @table, levels: 5}, scope)

      assert_receive %Rho.Events.Event{
                       kind: :task_requested,
                       data: %{worker_agent_id: req_id, role: :proficiency_writer}
                     },
                     500

      assert req_id == worker.agent_id

      assert_receive %Rho.Events.Event{
                       kind: :task_completed,
                       data: %{worker_agent_id: comp_id, status: :ok}
                     },
                     1_000

      assert comp_id == worker.agent_id
    end

    test "sibling worker crashes don't kill other workers (still get :task_completed)", %{
      scope: scope,
      session_id: session_id
    } do
      seed_rows(session_id, [
        %{
          category: "Eng",
          cluster: "T",
          skill_name: "Vim",
          skill_description: "Editor."
        },
        %{
          category: "Design",
          cluster: "V",
          skill_name: "Figma",
          skill_description: "Vector."
        }
      ])

      put_seam(fn input, on_partial ->
        case input.category do
          "Eng" ->
            raise "boom"

          "Design" ->
            on_partial.(%{skill_name: "Figma", levels: dummy_levels()})
            {:ok, %{skills: []}}
        end
      end)

      assert {:async, %{workers: workers}} =
               GenerateProficiency.run(%{table_name: @table, levels: 5}, scope)

      assert length(workers) == 2

      events = wait_for_completed(2, 1_500)
      statuses = events |> Enum.map(& &1.status) |> Enum.sort()
      assert statuses == [:error, :ok]

      # Design worker still persisted its skill.
      rows = by_skill_name(library_rows(session_id))
      figma_levels = rows["Figma"][:proficiency_levels] || rows["Figma"]["proficiency_levels"]
      assert is_list(figma_levels) and length(figma_levels) == 2

      # Eng worker did not — its row's proficiency_levels stayed at the seed value (nil/[]).
      vim_levels = rows["Vim"][:proficiency_levels] || rows["Vim"]["proficiency_levels"]
      assert vim_levels in [nil, []]
    end

    test "skips partials missing required fields without persisting them", %{
      scope: scope,
      session_id: session_id
    } do
      seed_rows(session_id, [
        %{
          category: "Eng",
          cluster: "T",
          skill_name: "Vim",
          skill_description: "Editor."
        },
        %{
          category: "Eng",
          cluster: "T",
          skill_name: "Tmux",
          skill_description: "Multiplexer."
        }
      ])

      put_seam(fn _input, on_partial ->
        # Missing skill_name — skipped.
        on_partial.(%{skill_name: "", levels: dummy_levels()})
        # Empty levels list — skipped.
        on_partial.(%{skill_name: "Vim", levels: []})
        # Fully formed — persisted.
        on_partial.(%{skill_name: "Tmux", levels: dummy_levels()})
        {:ok, %{skills: []}}
      end)

      assert {:async, %{workers: [_]}} =
               GenerateProficiency.run(%{table_name: @table, levels: 5}, scope)

      _ = wait_for_completed(1)

      rows = by_skill_name(library_rows(session_id))

      assert (rows["Tmux"][:proficiency_levels] || rows["Tmux"]["proficiency_levels"]) |> length() ==
               2

      # Vim never got persisted since both attempts were skipped.
      assert (rows["Vim"][:proficiency_levels] || rows["Vim"]["proficiency_levels"]) in [nil, []]
    end

    test "passes category, levels, and formatted skill bullets to the seam", %{
      scope: scope,
      session_id: session_id
    } do
      seed_rows(session_id, [
        %{
          category: "Eng",
          cluster: "Tooling",
          skill_name: "Vim",
          skill_description: "Editor."
        }
      ])

      test_pid = self()

      put_seam(fn input, _on_partial ->
        send(test_pid, {:seam_input, input})
        {:ok, %{skills: []}}
      end)

      assert {:async, _} =
               GenerateProficiency.run(%{table_name: @table, levels: 3}, scope)

      _ = wait_for_completed(1)

      assert_received {:seam_input, input}
      assert input.category == "Eng"
      assert input.levels == 3
      assert input.skills =~ "1. Vim | Cluster: Tooling | Editor."
    end

    test "defaults levels to 5 when not supplied", %{scope: scope, session_id: session_id} do
      seed_rows(session_id, [
        %{
          category: "Eng",
          cluster: "T",
          skill_name: "Vim",
          skill_description: "Editor."
        }
      ])

      test_pid = self()

      put_seam(fn input, _on_partial ->
        send(test_pid, {:levels, input.levels})
        {:ok, %{skills: []}}
      end)

      assert {:async, _} = GenerateProficiency.run(%{table_name: @table}, scope)
      _ = wait_for_completed(1)

      assert_received {:levels, 5}
    end
  end
end
