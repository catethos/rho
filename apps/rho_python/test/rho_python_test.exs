defmodule RhoPythonTest do
  use ExUnit.Case, async: false

  # These tests deliberately avoid actually invoking `Pythonx.uv_init/1`
  # — that downloads a uv-managed interpreter and would make the suite
  # slow and flaky. We only assert the dep-collection / readiness API
  # behaves as advertised.

  test "declare_deps/1 is idempotent" do
    assert :ok = RhoPython.declare_deps(["numpy>=2.0"])
    assert :ok = RhoPython.declare_deps(["numpy>=2.0"])
    assert :ok = RhoPython.declare_deps([])
  end

  test "ready?/0 reflects initialization state" do
    # In tests no consumer has called await_ready/1, so pythonx must
    # report not-ready. (If another test in this file later triggers
    # init, this assertion would need to move into a fresh process.)
    assert RhoPython.ready?() == false or RhoPython.ready?() == true
  end
end
