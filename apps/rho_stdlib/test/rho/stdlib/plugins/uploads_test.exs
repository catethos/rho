defmodule Rho.Stdlib.Plugins.UploadsTest do
  use ExUnit.Case, async: false

  alias Rho.Stdlib.Plugins.Uploads, as: Plugin
  alias Rho.Stdlib.Uploads

  setup do
    sid = "plug_#{System.unique_integer([:positive])}"
    on_exit(fn -> Uploads.stop(sid) end)
    {:ok, sid: sid}
  end

  test "list_uploads returns 'no uploads' when empty", %{sid: sid} do
    {:ok, _pid} = Uploads.ensure_started(sid)
    {:ok, text} = exec(:list_uploads, %{}, sid)
    assert text =~ "No uploads"
  end

  test "list_uploads + observe_upload happy path", %{sid: sid} do
    {:ok, _pid} = Uploads.ensure_started(sid)
    {:ok, h} = put_complete(sid)

    {:ok, list_text} = exec(:list_uploads, %{}, sid)
    assert list_text =~ h.id
    assert list_text =~ "complete_framework_import.xlsx"

    {:ok, obs_text} = exec(:observe_upload, %{upload_id: h.id}, sid)
    assert obs_text =~ "Skill Library Name"
    assert obs_text =~ "single library"
  end

  test "observe_upload returns clean error for bad id", %{sid: sid} do
    {:ok, _pid} = Uploads.ensure_started(sid)
    assert {:error, _} = exec(:observe_upload, %{upload_id: "upl_nonexistent"}, sid)
  end

  test "read_upload paginates", %{sid: sid} do
    {:ok, _pid} = Uploads.ensure_started(sid)
    {:ok, h} = put_complete(sid)
    {:ok, _} = exec(:observe_upload, %{upload_id: h.id}, sid)

    {:ok, text} = exec(:read_upload, %{upload_id: h.id, sheet: "Framework", limit: 2}, sid)
    assert text =~ "Recruitment Strategy"
  end

  defp exec(name, args, sid) do
    [tool] =
      Plugin.tools([], %{session_id: sid})
      |> Enum.filter(&(&1.tool.name == Atom.to_string(name)))

    tool.execute.(args, %Rho.Context{agent_name: :test, session_id: sid})
  end

  defp put_complete(sid) do
    src =
      Path.join([__DIR__, "../../../fixtures/uploads/complete_framework_import.xlsx"])
      |> Path.expand()

    Uploads.put(sid, %{
      filename: "complete_framework_import.xlsx",
      mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      tmp_path: src,
      size: File.stat!(src).size
    })
  end
end
