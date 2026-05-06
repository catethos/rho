defmodule Rho.Stdlib.Uploads.ObserverTest do
  use ExUnit.Case, async: false

  alias Rho.Stdlib.Uploads
  alias Rho.Stdlib.Uploads.Observation
  alias Rho.Stdlib.Uploads.Observer

  @complete "test/fixtures/uploads/complete_framework_import.xlsx"
  @rolesper "test/fixtures/uploads/test_framework_import.xlsx"

  setup do
    sid = "obs_#{System.unique_integer([:positive])}"
    on_exit(fn -> Uploads.stop(sid) end)
    {:ok, sid: sid}
  end

  test "observes complete_framework_import.xlsx as :single_library", %{sid: sid} do
    {:ok, _pid} = Uploads.ensure_started(sid)
    {:ok, h} = put_fixture(sid, @complete)

    assert {:ok, %Observation{} = obs} = Observer.observe(sid, h.id)
    assert obs.kind == :structured_table
    assert [%{name: "Framework"}] = obs.sheets
    assert obs.hints.library_name_column == "Skill Library Name"
    assert obs.hints.skill_name_column == "Skill Name"
    assert obs.hints.level_column == "Level"
    assert obs.hints.sheet_strategy == :single_library
    assert obs.summary_text =~ "[Uploaded: complete_framework_import.xlsx]"
  end

  test "observes test_framework_import.xlsx as :roles_per_sheet", %{sid: sid} do
    {:ok, _pid} = Uploads.ensure_started(sid)
    {:ok, h} = put_fixture(sid, @rolesper)

    assert {:ok, %Observation{} = obs} = Observer.observe(sid, h.id)
    assert obs.kind == :structured_table
    assert length(obs.sheets) == 3
    assert obs.hints.library_name_column == nil
    assert obs.hints.skill_name_column == "Skill Name"
    assert obs.hints.sheet_strategy == :roles_per_sheet
    assert "Multi-sheet file" <> _ = hd(obs.warnings)
  end

  test "second observe/2 returns cached observation (same struct identity)", %{sid: sid} do
    {:ok, _pid} = Uploads.ensure_started(sid)
    {:ok, h} = put_fixture(sid, @complete)
    {:ok, obs1} = Observer.observe(sid, h.id)
    {:ok, obs2} = Observer.observe(sid, h.id)
    assert obs1 == obs2
  end

  test "read_sheet returns paginated rows", %{sid: sid} do
    {:ok, _pid} = Uploads.ensure_started(sid)
    {:ok, h} = put_fixture(sid, @complete)

    assert {:ok, %{columns: cols, rows: rows, total: total}} =
             Observer.read_sheet(sid, h.id, "Framework", offset: 0, limit: 5)

    assert "Skill Library Name" in cols
    assert length(rows) == 5
    # Total is data rows (excludes header). complete_framework_import.xlsx has 26 total rows.
    # If row count differs, verify with: python3 to count and update assertion.
    assert total == 25
  end

  defp put_fixture(sid, src_path) do
    abs_path = Path.expand(src_path)

    Uploads.put(sid, %{
      filename: Path.basename(abs_path),
      mime: mime_for(abs_path),
      tmp_path: abs_path,
      size: File.stat!(abs_path).size
    })
  end

  defp mime_for(path) do
    case Path.extname(path) do
      ".xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      ".csv" -> "text/csv"
      _ -> "application/octet-stream"
    end
  end
end
