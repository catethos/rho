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
    assert match?([_, _, _, _, _], rows)
    # Total is data rows (excludes header). complete_framework_import.xlsx has 26 total rows.
    # If row count differs, verify with: python3 to count and update assertion.
    assert total == 25
  end

  test "parse_path returns lightweight PDF observation" do
    path = tmp_file("senior-backend-engineer.pdf", "%PDF-1.7\n")

    assert {:ok, %Observation{} = obs} = Observer.parse_path(path)
    assert obs.kind == :pdf
    assert obs.summary_text =~ "PDF uploaded"
    assert obs.summary_text =~ "extract_role_from_jd"
  end

  test "parse_path returns stored-only DOCX observation" do
    path = tmp_file("role.docx", "PK")

    assert {:ok, %Observation{} = obs} = Observer.parse_path(path)
    assert obs.kind == :docx
    assert obs.summary_text =~ "DOCX uploaded"
    assert obs.summary_text =~ "not extracted yet"
  end

  test "parse_path returns prose_text preview for txt" do
    path = tmp_file("notes.txt", "Alpha\n\nBeta")

    assert {:ok, %Observation{} = obs} = Observer.parse_path(path)
    assert obs.kind == :prose_text
    assert obs.summary_text =~ "Text document"
    assert obs.summary_text =~ "--- Document preview ---"
    assert obs.summary_text =~ "Alpha\n\nBeta"
  end

  test "parse_path extracts readable prose from html" do
    path =
      tmp_file(
        "jd.html",
        "<html><head><style>.x{}</style><script>bad()</script></head><body><h1>Lead Engineer</h1><p>Build systems.</p><div hidden>secret</div></body></html>"
      )

    assert {:ok, %Observation{} = obs} = Observer.parse_path(path)
    assert obs.kind == :prose_text
    assert obs.summary_text =~ "HTML document"
    assert obs.summary_text =~ "Lead Engineer"
    assert obs.summary_text =~ "Build systems."
    refute obs.summary_text =~ "bad()"
    refute obs.summary_text =~ "secret"
  end

  test "read_sheet returns not_a_table for prose and PDF uploads", %{sid: sid} do
    {:ok, _pid} = Uploads.ensure_started(sid)

    {:ok, pdf} = put_tmp(sid, "role.pdf", "%PDF-1.7\n")
    {:ok, txt} = put_tmp(sid, "notes.md", "# Notes")

    assert {:error, :not_a_table} = Observer.read_sheet(sid, pdf.id, nil)
    assert {:error, :not_a_table} = Observer.read_sheet(sid, txt.id, nil)
  end

  test "kind_for_path and parse_now? classify upload send behavior" do
    assert Observer.kind_for_path("skills.xlsx") == :structured_table
    assert Observer.kind_for_path("job.pdf") == :pdf
    assert Observer.kind_for_path("notes.md") == :prose_text
    assert Observer.kind_for_path("role.docx") == :docx

    assert Observer.parse_now?("skills.xlsx")
    assert Observer.parse_now?("notes.md")
    refute Observer.parse_now?("job.pdf")
    refute Observer.parse_now?("role.docx")
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

  defp put_tmp(sid, filename, contents) do
    path = tmp_file(filename, contents)

    Uploads.put(sid, %{
      filename: filename,
      mime: mime_for(path),
      tmp_path: path,
      size: File.stat!(path).size
    })
  end

  defp tmp_file(filename, contents) do
    dir = Path.join(System.tmp_dir!(), "rho_observer_test")
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{System.unique_integer([:positive])}_#{filename}")
    File.write!(path, contents)
    path
  end
end
