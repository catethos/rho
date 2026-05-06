defmodule RhoFrameworks.UseCases.ImportFromUploadTest do
  use ExUnit.Case, async: false

  alias Rho.Stdlib.Uploads
  alias RhoFrameworks.Scope
  alias RhoFrameworks.UseCases.ImportFromUpload

  @complete "test/fixtures/uploads/complete_framework_import.xlsx"
  @rolesper "test/fixtures/uploads/test_framework_import.xlsx"

  setup do
    sid = "ifu_#{System.unique_integer([:positive])}"
    org_id = "org_test_" <> Integer.to_string(System.unique_integer([:positive]))

    scope = %Scope{session_id: sid, organization_id: org_id, user_id: "u_test"}

    on_exit(fn -> Uploads.stop(sid) end)

    {:ok, sid: sid, scope: scope}
  end

  test "imports complete_framework_import as TWO libraries", %{sid: sid, scope: scope} do
    {:ok, _pid} = Uploads.ensure_started(sid)
    {:ok, h} = put_fixture(sid, fixture_path(@complete))

    {:ok, summary} = ImportFromUpload.run(%{upload_id: h.id}, scope)

    assert length(summary.libraries) == 2
    names = Enum.map(summary.libraries, & &1.library_name) |> Enum.sort()
    assert names == ["Finance Analyst", "HR Manager"]

    hr_lib = Enum.find(summary.libraries, &(&1.library_name == "HR Manager"))
    assert hr_lib.skills_imported == 3
    assert hr_lib.table_name == "library:HR Manager"

    fin_lib = Enum.find(summary.libraries, &(&1.library_name == "Finance Analyst"))
    assert fin_lib.skills_imported == 2
    assert fin_lib.table_name == "library:Finance Analyst"

    assert summary.warnings == []
  end

  test "explicit library_name override forces single library", %{sid: sid, scope: scope} do
    {:ok, _pid} = Uploads.ensure_started(sid)
    {:ok, h} = put_fixture(sid, fixture_path(@complete))

    {:ok, summary} = ImportFromUpload.run(%{upload_id: h.id, library_name: "All Skills"}, scope)

    assert length(summary.libraries) == 1
    assert hd(summary.libraries).library_name == "All Skills"
    # All 5 unique skills from both libraries lumped together
    assert hd(summary.libraries).skills_imported == 5
  end

  test "rejects roles_per_sheet with clean error", %{sid: sid, scope: scope} do
    {:ok, _pid} = Uploads.ensure_started(sid)
    {:ok, h} = put_fixture(sid, fixture_path(@rolesper))

    assert {:error, {:roles_per_sheet_unsupported_v1, sheets}} =
             ImportFromUpload.run(%{upload_id: h.id}, scope)

    assert "Product Manager" in sheets
    assert "Data Engineer" in sheets
    assert "CEO" in sheets
  end

  defp fixture_path(rel) do
    # The fixture lives in apps/rho_stdlib/test/fixtures/uploads/. From either the
    # umbrella root or apps/rho_frameworks/, we resolve relative to umbrella root.
    candidates = [
      Path.expand(rel),
      Path.expand("apps/rho_stdlib/" <> rel),
      Path.expand("../rho_stdlib/" <> rel),
      Path.join([__DIR__, "..", "..", "..", "..", "rho_stdlib", rel]) |> Path.expand()
    ]

    Enum.find(candidates, &File.exists?/1) ||
      raise "Could not find fixture #{rel}; tried: #{Enum.join(candidates, ", ")}"
  end

  defp put_fixture(sid, abs) do
    Uploads.put(sid, %{
      filename: Path.basename(abs),
      mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      tmp_path: abs,
      size: File.stat!(abs).size
    })
  end
end
