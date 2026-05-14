defmodule Rho.Stdlib.Plugins.DebugTapeTest do
  use ExUnit.Case

  alias Rho.Tape.{Service, Store}

  setup do
    tape = "debug_tape_plugin_#{System.unique_integer([:positive])}"
    Service.append(tape, :message, %{"role" => "user", "content" => "inspect me"})

    on_exit(fn -> Store.clear(tape) end)
    %{tape: tape}
  end

  test "plugin exposes debug tools only when configured" do
    tools = Rho.Stdlib.Plugins.DebugTape.tools([], %{})
    names = Enum.map(tools, & &1.tool.name)

    assert "get_tape_slice" in names
    assert "get_visible_context" in names
    assert Rho.Stdlib.resolve_plugin(:debug_tape) == {Rho.Stdlib.Plugins.DebugTape, []}
  end

  test "tools inspect a known tape without mutating it", %{tape: tape} do
    before_count = Store.last_id(tape)

    tool =
      Enum.find(Rho.Stdlib.Plugins.DebugTape.tools([], %{}), &(&1.tool.name == "get_tape_slice"))

    assert {:ok, json} = tool.execute.(%{ref: tape, last: 10}, %{})
    decoded = Jason.decode!(json)

    assert decoded["resolved"]["tape_name"] == tape
    assert length(decoded["entries"]) == 1
    assert Store.last_id(tape) == before_count
  end
end
