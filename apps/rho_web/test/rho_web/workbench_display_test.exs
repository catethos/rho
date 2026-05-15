defmodule RhoWeb.WorkbenchDisplayTest do
  use ExUnit.Case, async: true

  alias RhoWeb.WorkbenchDisplay

  test "home?/2 follows explicit display mode" do
    state = %{
      table_order: ["library:Core"],
      tables: [%{name: "library:Core", row_count: 2}],
      active_table: "library:Core"
    }

    refute WorkbenchDisplay.home?(
             WorkbenchDisplay.from_data_state(state, {:table, "library:Core"}),
             state
           )

    assert WorkbenchDisplay.home?(WorkbenchDisplay.from_data_state(state, :home), state)
  end

  test "closable_table?/1 protects default main table" do
    refute WorkbenchDisplay.closable_table?("main")
    assert WorkbenchDisplay.closable_table?("library:Core")
    refute WorkbenchDisplay.closable_table?(nil)
  end

  test "fallback_table/1 prefers visible artifact tables over empty main" do
    state = %{
      table_order: ["main", "library:Core"],
      tables: [%{name: "main", row_count: 0}, %{name: "library:Core", row_count: 3}],
      active_table: "main"
    }

    assert WorkbenchDisplay.fallback_table(state) == "library:Core"
  end

  test "mode_after_close/2 selects a fallback editor when another library remains" do
    state = %{
      table_order: ["main", "library:Core", "library:Sales"],
      tables: [
        %{name: "main", row_count: 0},
        %{name: "library:Core", row_count: 3},
        %{name: "library:Sales", row_count: 4}
      ],
      active_table: "library:Core"
    }

    assert WorkbenchDisplay.mode_after_close(state, "library:Core") == {:table, "library:Sales"}
  end

  test "mode_after_close/2 returns home when the last non-main table closes" do
    state = %{
      table_order: ["main", "library:Core"],
      tables: [%{name: "main", row_count: 0}, %{name: "library:Core", row_count: 3}],
      active_table: "library:Core"
    }

    assert WorkbenchDisplay.mode_after_close(state, "library:Core") == :home
  end

  test "async refresh preserves current explicit mode" do
    state = %{
      table_order: ["library:Core"],
      tables: [%{name: "library:Core", row_count: 0}],
      active_table: "library:Core"
    }

    display = WorkbenchDisplay.from_data_state(state, {:table, "library:Core"})

    refreshed =
      WorkbenchDisplay.from_data_state(
        %{state | tables: [%{name: "library:Core", row_count: 10}]},
        display.mode
      )

    assert refreshed.mode == {:table, "library:Core"}
  end

  test "refresh falls back home when the current table disappears" do
    state = %{
      table_order: ["main"],
      tables: [%{name: "main", row_count: 0}],
      active_table: "library:Core"
    }

    assert WorkbenchDisplay.from_data_state(state).mode == :home
  end

  test "for_render/3 derives legacy natural home only when no display is supplied" do
    state = %{table_order: [], tables: [], active_table: "main"}

    assert WorkbenchDisplay.for_render(nil, state, true).mode == :home

    display =
      WorkbenchDisplay.from_data_state(
        %{state | table_order: ["library:Core"]},
        {:table, "library:Core"}
      )

    assert WorkbenchDisplay.for_render(display, state, true).mode == {:table, "library:Core"}
  end

  test "return_available?/2 is true only for explicit home over an open artifact" do
    empty_state = %{table_order: [], tables: [], active_table: "main"}
    artifact_state = %{table_order: ["library:Core"], tables: [], active_table: "library:Core"}

    assert WorkbenchDisplay.return_available?(
             WorkbenchDisplay.from_data_state(artifact_state, :home),
             artifact_state
           )

    refute WorkbenchDisplay.return_available?(
             WorkbenchDisplay.from_data_state(empty_state, :home),
             empty_state
           )
  end
end
