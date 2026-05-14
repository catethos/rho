defmodule Rho.Stdlib.Uploads.ServerTest do
  use ExUnit.Case, async: false

  alias Rho.Stdlib.Uploads.{Handle, Server}

  setup do
    sid = "test_sess_#{System.unique_integer([:positive])}"
    on_exit(fn -> Server.stop(sid) end)
    {:ok, sid: sid}
  end

  test "start_link spawns a server addressable via Registry", %{sid: sid} do
    {:ok, pid} = Server.start_link(session_id: sid)
    assert is_pid(pid) and Process.alive?(pid)
    assert Server.whereis(sid) == pid
  end

  test "put/2 stores bytes and returns a Handle with a stable path", %{sid: sid} do
    {:ok, _pid} = Server.start_link(session_id: sid)

    src = Path.join(System.tmp_dir!(), "src_#{System.unique_integer([:positive])}.csv")
    File.write!(src, "Skill Name,Category\nElixir,Tech\n")

    assert {:ok, %Handle{} = h} =
             Server.put(sid, %{
               filename: "tiny.csv",
               mime: "text/csv",
               tmp_path: src,
               size: File.stat!(src).size
             })

    assert String.starts_with?(h.id, "upl_")
    assert h.session_id == sid
    assert h.filename == "tiny.csv"
    assert h.mime == "text/csv"
    assert File.exists?(h.path)
    assert File.read!(h.path) == File.read!(src)
  end

  test "list/1 returns all handles for the session", %{sid: sid} do
    {:ok, _pid} = Server.start_link(session_id: sid)
    src = Path.join(System.tmp_dir!(), "f.csv")
    File.write!(src, "a")

    {:ok, _h1} = Server.put(sid, %{filename: "a.csv", mime: "text/csv", tmp_path: src, size: 1})
    {:ok, _h2} = Server.put(sid, %{filename: "b.csv", mime: "text/csv", tmp_path: src, size: 1})

    assert length(Server.list(sid)) == 2
  end

  test "delete/2 removes the handle and the on-disk file", %{sid: sid} do
    {:ok, _pid} = Server.start_link(session_id: sid)
    src = Path.join(System.tmp_dir!(), "to_delete.csv")
    File.write!(src, "x")
    {:ok, h} = Server.put(sid, %{filename: "z.csv", mime: "text/csv", tmp_path: src, size: 1})

    assert :ok = Server.delete(sid, h.id)
    assert :error = Server.get(sid, h.id)
    refute File.exists?(h.path)
  end

  test "terminate/2 deletes the per-session directory", %{sid: sid} do
    {:ok, pid} = Server.start_link(session_id: sid)
    src = Path.join(System.tmp_dir!(), "doomed.csv")
    File.write!(src, "x")
    {:ok, h} = Server.put(sid, %{filename: "d.csv", mime: "text/csv", tmp_path: src, size: 1})
    session_dir = Path.dirname(h.path)
    assert File.exists?(session_dir)

    GenServer.stop(pid, :normal)

    refute File.exists?(session_dir)
  end
end
