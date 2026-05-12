defmodule Rho.Stdlib.Tools.Python.InterpreterTest do
  # Tagged :integration_python because it requires :erlang_python running
  # against a uv-built venv. Excluded from `mix test` by default; run with
  # `mix test --include integration_python` after the venv is warmed.

  use ExUnit.Case, async: false

  alias Rho.Stdlib.Tools.Python.Interpreter

  @moduletag :integration_python

  setup_all do
    # Build the venv once for the suite. Tests use stdlib-only Python
    # (ast/io/sys), but matplotlib is asserted in one case so we
    # declare it explicitly.
    :ok = RhoPython.declare_deps(["matplotlib"])
    :ok = RhoPython.await_ready(:timer.minutes(5))
    :ok
  end

  setup do
    session_id = "interp_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> Interpreter.stop(session_id) end)
    {:ok, session_id: session_id}
  end

  test "captures stdout and last-expression result", %{session_id: sid} do
    assert {disposition, output} = Interpreter.eval(sid, "print('hi')\n1 + 1")
    assert disposition in [:ok, :final]
    assert output =~ "hi"
    assert output =~ "2"
  end

  test "variables persist across calls", %{session_id: sid} do
    assert {_, _} = Interpreter.eval(sid, "A = [1, 2, 3]")
    assert {disposition, output} = Interpreter.eval(sid, "sum(A)")
    assert disposition in [:ok, :final]
    assert output =~ "6"
  end

  test "{final: False, result: ...} keeps the turn open", %{session_id: sid} do
    code = ~s|{"final": False, "result": "intermediate"}|
    assert {:ok, output} = Interpreter.eval(sid, code)
    assert output =~ "intermediate"
  end

  test "Python error returns :error with traceback", %{session_id: sid} do
    assert {:error, {:eval_failed, msg}} = Interpreter.eval(sid, "1 / 0")
    assert msg =~ "ZeroDivisionError"
  end

  test "matplotlib figure capture writes a PNG", %{session_id: sid} do
    original_cwd = File.cwd!()

    workspace =
      Path.join(System.tmp_dir!(), "rho_interp_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    on_exit(fn ->
      # Interpreter chdirs Python into workspace; restore the BEAM
      # process cwd before removing it, or other tests can't `cwd!()`.
      File.cd!(original_cwd)
      File.rm_rf!(workspace)
    end)

    {:ok, _} =
      DynamicSupervisor.start_child(
        Rho.Stdlib.Tools.Python.Supervisor,
        {Interpreter, session_id: sid, workspace: workspace}
      )

    code = """
    import matplotlib.pyplot as plt
    plt.plot([1, 2, 3])
    """

    assert {_, output} = Interpreter.eval(sid, code, workspace)
    assert output =~ "[Plot saved:"
    assert [_ | _] = Path.wildcard(Path.join(workspace, "plot_*.png"))
  end
end
