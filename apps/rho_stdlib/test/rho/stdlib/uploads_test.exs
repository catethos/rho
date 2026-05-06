defmodule Rho.Stdlib.UploadsTest do
  use ExUnit.Case, async: false

  alias Rho.Stdlib.Uploads
  alias Rho.Stdlib.Uploads.Handle

  setup do
    sid = "test_uploads_#{System.unique_integer([:positive])}"
    on_exit(fn -> Uploads.stop(sid) end)
    {:ok, sid: sid}
  end

  test "ensure_started is idempotent and starts a per-session server", %{sid: sid} do
    assert {:ok, _pid} = Uploads.ensure_started(sid)
    assert {:ok, _pid} = Uploads.ensure_started(sid)
  end

  test "put → get → list → delete round-trip", %{sid: sid} do
    {:ok, _pid} = Uploads.ensure_started(sid)
    src = write_tmp("hello world")

    {:ok, %Handle{id: id} = h} =
      Uploads.put(sid, %{filename: "h.csv", mime: "text/csv", tmp_path: src, size: 11})

    assert {:ok, ^h} = Uploads.get(sid, id)
    assert [%Handle{id: ^id}] = Uploads.list(sid)
    assert :ok = Uploads.delete(sid, id)
    assert :error = Uploads.get(sid, id)
    assert [] = Uploads.list(sid)
  end

  test "parse_one_off/1 parses a CSV and returns an Observation", %{sid: _sid} do
    src = write_tmp("a,b\n1,2\n")

    assert {:ok, %Rho.Stdlib.Uploads.Observation{kind: :structured_table}} =
             Uploads.parse_one_off(src)
  end

  describe "SessionJanitor" do
    test "stops the upload server on :agent_stopped event", %{sid: sid} do
      {:ok, _pid} = Uploads.ensure_started(sid)

      # Real function name verified in apps/rho/lib/rho/events.ex:71.
      # Use Rho.Events.event/2 so session_id is injected into data — matching
      # how Worker.terminate/2 publishes :agent_stopped in production.
      Rho.Events.broadcast_lifecycle(Rho.Events.event(:agent_stopped, sid))

      # Janitor handles asynchronously — give the BEAM a tick.
      Process.sleep(50)

      assert is_nil(Rho.Stdlib.Uploads.Server.whereis(sid))
    end
  end

  defp write_tmp(content) do
    p = Path.join(System.tmp_dir!(), "upl_#{System.unique_integer([:positive])}.csv")
    File.write!(p, content)
    p
  end
end
