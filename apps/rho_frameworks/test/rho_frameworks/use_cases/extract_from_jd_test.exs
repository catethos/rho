defmodule RhoFrameworks.UseCases.ExtractFromJDTest do
  use ExUnit.Case, async: false

  alias Rho.Stdlib.DataTable
  alias Rho.Stdlib.Uploads
  alias RhoFrameworks.Repo
  alias RhoFrameworks.Scope
  alias RhoFrameworks.UseCases.ExtractFromJD

  setup do
    sid = "jd_#{System.unique_integer([:positive])}"
    org_id = "org_test_" <> Integer.to_string(System.unique_integer([:positive]))
    scope = %Scope{session_id: sid, organization_id: org_id, user_id: "u_test"}

    old_pdf = Application.get_env(:rho_frameworks, :extract_from_jd_pdf_fn)
    old_text = Application.get_env(:rho_frameworks, :extract_from_jd_text_fn)

    on_exit(fn ->
      restore_env(:extract_from_jd_pdf_fn, old_pdf)
      restore_env(:extract_from_jd_text_fn, old_text)
      Uploads.stop(sid)
      DataTable.stop(sid)
    end)

    %{sid: sid, scope: scope}
  end

  test "rejects missing input and both input forms", %{scope: scope} do
    assert {:error, :missing_input} = ExtractFromJD.run(%{}, scope)

    assert {:error, :too_many_inputs} =
             ExtractFromJD.run(%{upload_id: "upl_missing", text: "JD"}, scope)
  end

  test "rejects missing upload id", %{scope: scope} do
    assert {:error, {:upload_not_found, "upl_missing"}} =
             ExtractFromJD.run(%{upload_id: "upl_missing"}, scope)
  end

  test "dispatches text input, dedupes skills, and writes library and role tables", %{
    sid: sid,
    scope: scope
  } do
    Process.put(:jd_text_args, nil)

    Application.put_env(:rho_frameworks, :extract_from_jd_text_fn, fn args ->
      Process.put(:jd_text_args, args)
      {:ok, sample_output()}
    end)

    jd_text = "We require SQL and SQL query tuning. Python is a plus."

    assert {:ok, result} =
             ExtractFromJD.run(
               %{text: jd_text, role_name: "Analytics Engineer", library_name: "Analytics JD"},
               scope
             )

    assert Process.get(:jd_text_args) == %{jd_text: jd_text}
    assert result.role_name == "Analytics Engineer"
    assert result.library_name == "Analytics JD"
    assert result.library_table == "library:Analytics JD"
    assert result.skill_count == 2
    assert result.required_count == 1
    assert result.nice_to_have_count == 1
    assert result.dropped_unverified == 1

    library_rows = DataTable.get_rows(sid, table: "library:Analytics JD")
    role_rows = DataTable.get_rows(sid, table: "role_profile")

    assert Enum.map(library_rows, & &1.skill_name) |> Enum.sort() == ["Python", "SQL"]

    sql = Enum.find(role_rows, &(&1.skill_name == "SQL"))
    assert sql.required == true
    assert sql.required_level == 0
    assert sql.priority == "required"
    assert sql.verification == "quote_verified"
    assert sql.source_quote == "SQL"
    assert sql._source == "jd"

    python = Enum.find(role_rows, &(&1.skill_name == "Python"))
    assert python.required == false
  end

  test "dispatches PDF upload as base64 media input", %{sid: sid, scope: scope} do
    {:ok, _pid} = Uploads.ensure_started(sid)
    pdf = Path.join(System.tmp_dir!(), "jd-#{System.unique_integer([:positive])}.pdf")
    File.write!(pdf, "%PDF-1.4 fake")

    on_exit(fn -> File.rm(pdf) end)

    {:ok, handle} =
      Uploads.put(sid, %{
        filename: "senior-backend.pdf",
        mime: "application/pdf",
        tmp_path: pdf,
        size: File.stat!(pdf).size
      })

    test_pid = self()

    Application.put_env(:rho_frameworks, :extract_from_jd_pdf_fn, fn args ->
      send(test_pid, {:pdf_args, args})
      {:ok, sample_output()}
    end)

    assert {:ok, result} = ExtractFromJD.run(%{upload_id: handle.id}, scope)
    assert result.role_name == "Senior Backend Engineer"

    assert_received {:pdf_args,
                     %{
                       jd: %{
                         base64: encoded,
                         media_type: "application/pdf"
                       }
                     }}

    assert Base.decode64!(encoded) == "%PDF-1.4 fake"
  end

  test "normalizes missing OpenRouter API key errors", %{scope: scope} do
    Application.put_env(:rho_frameworks, :extract_from_jd_text_fn, fn _args ->
      {:error,
       "LLM client 'OpenRouterHaiku' requires environment variable 'OPENROUTER_API_KEY' to be set"}
    end)

    assert {:error, {:missing_llm_api_key, "OpenRouterHaiku", "OPENROUTER_API_KEY"}} =
             ExtractFromJD.run(%{text: "We require SQL."}, scope)
  end

  test "applies role and library name overrides", %{scope: scope} do
    Application.put_env(:rho_frameworks, :extract_from_jd_text_fn, fn _args ->
      {:ok, sample_output()}
    end)

    assert {:ok, result} =
             ExtractFromJD.run(
               %{text: "We require SQL.", role_name: "DBA", library_name: "DBA Skills"},
               scope
             )

    assert result.role_name == "DBA"
    assert result.library_name == "DBA Skills"
    assert result.library_table == "library:DBA Skills"
  end

  test "checks library collision and role collision separately", %{sid: sid} do
    org_id = Ecto.UUID.generate()

    Repo.insert!(%RhoFrameworks.Accounts.Organization{
      id: org_id,
      name: "JD Collision Org",
      slug: "jd-collision-#{System.unique_integer([:positive])}"
    })

    scope = %Scope{session_id: sid, organization_id: org_id, user_id: "u_test"}

    Application.put_env(:rho_frameworks, :extract_from_jd_text_fn, fn _args ->
      {:ok, sample_output()}
    end)

    {:ok, _lib} = RhoFrameworks.Library.create_library(org_id, %{name: "Existing Library"})

    assert {:error, {:library_exists, "Existing Library"}} =
             ExtractFromJD.run(
               %{text: "We require SQL.", library_name: "Existing Library"},
               scope
             )

    {:ok, lib} = RhoFrameworks.Library.create_library(org_id, %{name: "Role Collision Lib"})

    {:ok, _} =
      RhoFrameworks.Roles.save_role_profile(
        org_id,
        %{name: "Existing Role"},
        [%{category: "Tech", skill_name: "SQL", required_level: 1, required: true}],
        resolve_library_id: lib.id
      )

    assert {:error, {:role_profile_exists, "Existing Role"}} =
             ExtractFromJD.run(%{text: "We require SQL.", role_name: "Existing Role"}, scope)
  end

  defp sample_output do
    %{
      role_title: "Senior Backend Engineer",
      skills: [
        %{
          skill_name: "SQL.",
          skill_description: "Writes SQL queries.",
          category_hint: "Data",
          priority: "required",
          source_quote: "SQL",
          page_number: 1
        },
        %{
          skill_name: "SQL",
          skill_description: "Duplicate should merge.",
          category_hint: "Data",
          priority: "nice_to_have",
          source_quote: "SQL query tuning",
          page_number: 2
        },
        %{
          skill_name: "Python",
          skill_description: "Writes Python scripts.",
          category_hint: "Programming",
          priority: "nice_to_have",
          source_quote: nil,
          page_number: nil
        },
        %{
          skill_name: "Invented Skill",
          skill_description: "Should be dropped for text quote mismatch.",
          category_hint: "Other",
          priority: "required",
          source_quote: "Kubernetes"
        }
      ]
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:rho_frameworks, key)
  defp restore_env(key, value), do: Application.put_env(:rho_frameworks, key, value)
end
