defmodule RhoFrameworks.UseCases.ExtractFromJD do
  @moduledoc """
  Extracts a job description into a skill library table and the role profile table.
  """

  @behaviour RhoFrameworks.UseCase

  alias Rho.Stdlib.DataTable
  alias Rho.Stdlib.Uploads
  alias RhoFrameworks.DataTableSchemas
  alias RhoFrameworks.Library
  alias RhoFrameworks.Library.Editor
  alias RhoFrameworks.Roles
  alias RhoFrameworks.Scope
  alias RhoFrameworks.Workbench

  @role_profile_table "role_profile"
  @text_extensions ~w(.txt .md .markdown .html .htm)

  @impl true
  def describe do
    %{
      id: :extract_from_jd,
      label: "Extract role from job description",
      cost_hint: :expensive,
      doc: "Extract skills from JD text or a PDF upload into library and role_profile tables."
    }
  end

  @impl true
  def run(input, %Scope{} = scope) when is_map(input) do
    with {:ok, source} <- resolve_source(input, scope),
         {:ok, result} <- call_extractor(source),
         {:ok, names} <- resolve_names(input, result),
         :ok <- check_collisions(scope, names),
         {:ok, rows} <- build_rows(result, source),
         :ok <- ensure_tables(scope.session_id, names.library_table),
         {:ok, _} <- Workbench.replace_rows(scope, rows.library, table: names.library_table),
         {:ok, _} <- Workbench.replace_rows(scope, rows.role, table: @role_profile_table) do
      {:ok,
       %{
         role_name: names.role_name,
         library_name: names.library_name,
         library_table: names.library_table,
         role_table: @role_profile_table,
         skill_count: length(rows.role),
         required_count: Enum.count(rows.role, & &1.required),
         nice_to_have_count: Enum.count(rows.role, &(&1.required == false)),
         dropped_unverified: rows.dropped_unverified
       }}
    end
  end

  defp resolve_source(input, scope) do
    upload_id = blank_to_nil(Map.get(input, :upload_id) || Map.get(input, "upload_id"))
    text = blank_to_nil(Map.get(input, :text) || Map.get(input, "text"))

    case {upload_id, text} do
      {nil, nil} ->
        {:error, :missing_input}

      {upload_id, text} when is_binary(upload_id) and is_binary(text) ->
        {:error, :too_many_inputs}

      {nil, text} when is_binary(text) ->
        {:ok, %{kind: :text, text: text}}

      {upload_id, nil} when is_binary(upload_id) ->
        source_from_upload(scope.session_id, upload_id)

      _ ->
        {:error, :invalid_input}
    end
  end

  defp source_from_upload(session_id, upload_id) do
    case Uploads.get(session_id, upload_id) do
      {:ok, handle} -> classify_upload(handle)
      :error -> {:error, {:upload_not_found, upload_id}}
      {:error, :not_running} -> {:error, {:upload_not_found, upload_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp classify_upload(handle) do
    ext = handle.filename |> Path.extname() |> String.downcase()
    mime = to_string(handle.mime || "")

    cond do
      ext == ".pdf" or mime == "application/pdf" ->
        {:ok, %{kind: :pdf, handle: handle}}

      ext in @text_extensions or String.starts_with?(mime, "text/") ->
        case File.read(handle.path) do
          {:ok, text} -> {:ok, %{kind: :text, text: text, handle: handle}}
          {:error, reason} -> {:error, {:upload_read_failed, reason}}
        end

      true ->
        {:error, {:unsupported_upload_kind, handle.filename, mime}}
    end
  end

  defp call_extractor(%{kind: :pdf, handle: handle}) do
    pdf_arg = %{
      base64: Base.encode64(File.read!(handle.path)),
      media_type: "application/pdf"
    }

    case pdf_fn().(%{jd: pdf_arg}) do
      {:error, reason} -> {:error, normalize_llm_error(reason)}
      other -> other
    end
  end

  defp call_extractor(%{kind: :text, text: text}) do
    case text_fn().(%{jd_text: text}) do
      {:error, reason} -> {:error, normalize_llm_error(reason)}
      other -> other
    end
  end

  defp normalize_llm_error(reason) when is_binary(reason) do
    cond do
      String.contains?(reason, "OPENROUTER_API_KEY") ->
        {:missing_llm_api_key, "OpenRouterHaiku", "OPENROUTER_API_KEY"}

      true ->
        reason
    end
  end

  defp normalize_llm_error(reason), do: reason

  defp pdf_fn do
    Application.get_env(
      :rho_frameworks,
      :extract_from_jd_pdf_fn,
      &RhoFrameworks.LLM.ExtractFromJDPdf.call/1
    )
  end

  defp text_fn do
    Application.get_env(
      :rho_frameworks,
      :extract_from_jd_text_fn,
      &RhoFrameworks.LLM.ExtractFromJDText.call/1
    )
  end

  defp resolve_names(input, result) do
    role_name =
      Map.get(input, :role_name) ||
        Map.get(input, "role_name") ||
        get(result, :role_title) ||
        "Job Description"

    role_name = role_name |> to_string() |> String.trim()

    library_name =
      Map.get(input, :library_name) ||
        Map.get(input, "library_name") ||
        role_name

    library_name = library_name |> to_string() |> String.trim()

    cond do
      role_name == "" ->
        {:error, :missing_role_name}

      library_name == "" ->
        {:error, :missing_library_name}

      true ->
        {:ok,
         %{
           role_name: role_name,
           library_name: library_name,
           library_table: Editor.table_name(library_name)
         }}
    end
  end

  defp check_collisions(scope, names) do
    with :ok <- check_library_collision(scope, names.library_name),
         :ok <- check_role_collision(scope, names.role_name) do
      :ok
    end
  end

  defp check_library_collision(%Scope{organization_id: org_id}, name) do
    if valid_uuid?(org_id) do
      case Library.get_library_by_name(org_id, name) do
        nil -> :ok
        _ -> {:error, {:library_exists, name}}
      end
    else
      :ok
    end
  end

  defp check_role_collision(%Scope{organization_id: org_id}, name) do
    if valid_uuid?(org_id) do
      case Roles.get_role_profile_by_name(org_id, name) do
        nil -> :ok
        _ -> {:error, {:role_profile_exists, name}}
      end
    else
      :ok
    end
  end

  defp build_rows(result, source) do
    {skills, dropped} =
      result
      |> get(:skills)
      |> List.wrap()
      |> Enum.reduce({%{}, 0}, fn raw, {acc, dropped} ->
        case normalize_skill(raw, source) do
          {:ok, skill} ->
            key = dedupe_key(skill.skill_name)
            {Map.update(acc, key, skill, &merge_skill(&1, skill)), dropped}

          :drop ->
            {acc, dropped + 1}
        end
      end)

    skills = Map.values(skills)

    if skills == [] do
      {:error, :no_skills}
    else
      library_rows = Enum.map(skills, &library_row/1)
      role_rows = Enum.map(skills, &role_row/1)
      {:ok, %{library: library_rows, role: role_rows, dropped_unverified: dropped}}
    end
  end

  defp normalize_skill(raw, source) do
    name = raw |> get(:skill_name) |> to_clean_name()

    if name == "" do
      :drop
    else
      quote = raw |> get(:source_quote) |> blank_to_nil()
      verification = verification(source, quote)

      if verification == :drop do
        :drop
      else
        {:ok,
         %{
           skill_name: name,
           skill_description: get(raw, :skill_description) |> blank_to_nil(),
           category_hint: get(raw, :category_hint) |> blank_to_nil(),
           priority: normalize_priority(get(raw, :priority)),
           source_quote: quote,
           page_number: normalize_page_number(get(raw, :page_number)),
           verification: verification
         }}
      end
    end
  end

  defp verification(%{kind: :text, text: text}, quote) when is_binary(quote) do
    if normalized_contains?(text, quote), do: "quote_verified", else: :drop
  end

  defp verification(%{kind: :text}, _quote), do: "unverified"
  defp verification(%{kind: :pdf}, quote) when is_binary(quote), do: "model_cited"
  defp verification(%{kind: :pdf}, _quote), do: "unverified"

  defp merge_skill(a, b) do
    %{
      a
      | skill_description: first_present(a.skill_description, b.skill_description),
        category_hint: first_present(a.category_hint, b.category_hint),
        priority: merge_priority(a.priority, b.priority),
        source_quote: shortest_quote(a.source_quote, b.source_quote),
        page_number: a.page_number || b.page_number,
        verification: merge_verification(a.verification, b.verification)
    }
  end

  defp merge_priority("required", _), do: "required"
  defp merge_priority(_, "required"), do: "required"
  defp merge_priority(_, _), do: "nice_to_have"

  defp merge_verification("quote_verified", _), do: "quote_verified"
  defp merge_verification(_, "quote_verified"), do: "quote_verified"
  defp merge_verification("model_cited", _), do: "model_cited"
  defp merge_verification(_, "model_cited"), do: "model_cited"
  defp merge_verification(_, _), do: "unverified"

  defp library_row(skill) do
    category = skill.category_hint || "Uncategorized"

    %{
      category: category,
      cluster: category,
      skill_name: skill.skill_name,
      skill_description: skill.skill_description || "",
      _source: "jd"
    }
  end

  defp role_row(skill) do
    category = skill.category_hint || "Uncategorized"

    %{
      category: category,
      cluster: category,
      skill_name: skill.skill_name,
      skill_description: skill.skill_description || "",
      required_level: 0,
      required: skill.priority == "required",
      priority: skill.priority,
      source_quote: skill.source_quote || "",
      page_number: skill.page_number,
      verification: skill.verification,
      _source: "jd"
    }
  end

  defp ensure_tables(session_id, library_table) do
    _ = DataTable.ensure_started(session_id)

    with :ok <-
           DataTable.ensure_table(session_id, library_table, DataTableSchemas.library_schema()) do
      DataTable.ensure_table(
        session_id,
        @role_profile_table,
        DataTableSchemas.role_profile_schema()
      )
    end
  end

  defp to_clean_name(nil), do: ""

  defp to_clean_name(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace(~r/[.,;:!?]+$/, "")
    |> String.replace(~r/\s+/, " ")
  end

  defp dedupe_key(name), do: name |> to_clean_name() |> String.downcase()

  defp normalize_priority(value) do
    case value |> to_string() |> String.downcase() |> String.replace("-", "_") do
      "required" -> "required"
      "must_have" -> "required"
      "mandatory" -> "required"
      _ -> "nice_to_have"
    end
  end

  defp normalize_page_number(nil), do: nil
  defp normalize_page_number(n) when is_integer(n), do: n

  defp normalize_page_number(n) when is_binary(n) do
    case Integer.parse(n) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp normalize_page_number(_), do: nil

  defp first_present(nil, b), do: b
  defp first_present("", b), do: b
  defp first_present(a, _), do: a

  defp shortest_quote(nil, b), do: b
  defp shortest_quote(a, nil), do: a
  defp shortest_quote(a, b) when byte_size(a) <= byte_size(b), do: a
  defp shortest_quote(_a, b), do: b

  defp normalized_contains?(text, quote) do
    normalize_ws(text) =~ normalize_ws(quote)
  end

  defp normalize_ws(value) do
    value
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(value), do: value

  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp get(_, _), do: nil

  defp valid_uuid?(nil), do: false

  defp valid_uuid?(s) when is_binary(s) do
    case Ecto.UUID.cast(s) do
      {:ok, _} -> true
      :error -> false
    end
  end
end
