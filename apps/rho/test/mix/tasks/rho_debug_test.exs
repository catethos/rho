defmodule Mix.Tasks.RhoDebugTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias Rho.Tape.{Service, Store}

  setup do
    tape = "rho_debug_task_#{System.unique_integer([:positive])}"
    out = Path.join(System.tmp_dir!(), "rho_debug_task_out_#{System.unique_integer([:positive])}")
    Service.append(tape, :message, %{"role" => "user", "content" => "debug"})

    on_exit(fn ->
      Store.clear(tape)
      File.rm_rf!(out)
      Mix.Task.reenable("rho.debug")
    end)

    %{tape: tape, out: out}
  end

  test "mix rho.debug writes a bundle", %{tape: tape, out: out} do
    output =
      capture_io(fn ->
        Mix.Task.rerun("rho.debug", [tape, "--out", out])
      end)

    assert output =~ "Wrote Rho debug bundle"
    assert File.exists?(Path.join(out, "summary.json"))
  end
end
