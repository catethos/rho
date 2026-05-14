defmodule Rho.Trace.BundleTest do
  use ExUnit.Case

  alias Rho.Tape.{Service, Store}

  setup do
    tape = "trace_bundle_#{System.unique_integer([:positive])}"
    out = Path.join(System.tmp_dir!(), "rho_bundle_test_#{System.unique_integer([:positive])}")

    Service.append(tape, :message, %{"role" => "user", "content" => "bundle this"})

    on_exit(fn ->
      Store.clear(tape)
      File.rm_rf!(out)
    end)

    %{tape: tape, out: out}
  end

  test "writes a complete bundle for a tape", %{tape: tape, out: out} do
    {:ok, summary} = Rho.Trace.Bundle.write(tape, out: out)

    assert summary["tape_name"] == tape
    assert File.exists?(Path.join(out, "summary.json"))
    assert File.exists?(Path.join(out, "tape.jsonl"))
    assert File.exists?(Path.join(out, "events.jsonl"))
    assert File.exists?(Path.join(out, "chat.md"))
    assert File.exists?(Path.join(out, "context.md"))
    assert File.exists?(Path.join(out, "debug-timeline.md"))
    assert File.exists?(Path.join(out, "failures.md"))
    assert File.exists?(Path.join(out, "costs.md"))
    assert File.exists?(Path.join(out, "README.md"))
  end
end
