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

  test "imports complete_framework_import as a single library", %{sid: sid, scope: scope} do
    {:ok, _pid} = Uploads.ensure_started(sid)
    {:ok, h} = put_fixture(sid, fixture_path(@complete))

    {:ok, summary} = ImportFromUpload.run(%{upload_id: h.id}, scope)

    assert summary.library_name == "HR Manager"
    assert summary.table_name == "library:HR Manager"
    # complete_framework_import.xlsx has 5 unique skills × 5 levels each = 25 data rows.
    # skills_imported counts unique skill_name values, not rows.
    assert summary.skills_imported == 5
    assert summary.warnings == []
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
