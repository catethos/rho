defmodule RhoFrameworks.UseCases.IdentifyFrameworkGaps do
  @moduledoc """
  Identify the skills missing from an already-loaded framework, relative
  to the new framework's intake (`name`, `description`, `domain`,
  `target_roles`). Reads the library snapshot from the session's
  Workbench (loaded by `LoadExistingFramework`) and calls
  `RhoFrameworks.LLM.IdentifyGaps`.

  Cheap LLM call — the existing-skills rendering is the heavy input and
  the gap list is small. The result feeds `:generate` with
  `seed_skills:` (existing rows) and `scope: :gaps_only`.

  Input:

      %{
        library_id:  String.t,
        table_name:  String.t,    # from LoadExistingFramework summary
        intake:      %{name, description, domain, target_roles}
      }

  Returns `{:ok, %{gaps: [...], gap_count, library_id, table_name}}`.

  ## Test seam

      Application.put_env(:rho_frameworks, :identify_gaps_fn,
        fn input -> {:ok, %{gaps: [%{skill_name: "X", category: "Y", rationale: "Z"}]}} end)
  """

  @behaviour RhoFrameworks.UseCase

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.LLM.IdentifyGaps, as: LLM
  alias RhoFrameworks.Scope

  @impl true
  def describe do
    %{
      id: :identify_framework_gaps,
      label: "Identify framework gaps",
      cost_hint: :cheap,
      doc: "Surface skills missing from a loaded framework relative to the intake."
    }
  end

  @impl true
  def run(input, %Scope{} = scope) do
    library_id = get(input, :library_id)
    table_name = get(input, :table_name)
    intake = get(input, :intake) || %{}

    cond do
      blank?(library_id) ->
        {:error, :missing_library_id}

      blank?(table_name) ->
        {:error, :missing_table_name}

      true ->
        do_run(library_id, table_name, intake, scope)
    end
  end

  defp do_run(library_id, table_name, intake, %Scope{session_id: sid}) do
    rows = read_rows(sid, table_name)
    existing_skills = format_existing_skills(rows)

    seam_input = %{
      framework_name: intake_field(intake, :name),
      framework_description: intake_field(intake, :description),
      domain: intake_field(intake, :domain),
      target_roles: intake_field(intake, :target_roles),
      existing_skills: existing_skills
    }

    case identify_fn().(seam_input) do
      {:ok, %{gaps: gaps}} when is_list(gaps) ->
        normalized = Enum.map(gaps, &normalize_gap/1)

        {:ok,
         %{
           gaps: normalized,
           gap_count: length(normalized),
           library_id: library_id,
           table_name: table_name
         }}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_identify_result, other}}
    end
  end

  defp identify_fn do
    Application.get_env(:rho_frameworks, :identify_gaps_fn, &__MODULE__.default_identify/1)
  end

  @doc """
  Default `:identify_gaps_fn` — wraps `LLM.IdentifyGaps.call/1` and
  unwraps the struct into the plain map shape `run/2` expects.
  """
  @spec default_identify(map()) :: {:ok, %{gaps: [map()]}} | {:error, term()}
  def default_identify(input) do
    case LLM.call(input) do
      {:ok, %LLM{gaps: gaps}} -> {:ok, %{gaps: gaps || []}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_rows(sid, table) do
    case DataTable.get_rows(sid, table: table) do
      rows when is_list(rows) -> rows
      _ -> []
    end
  end

  defp format_existing_skills([]), do: "(none — the loaded framework is empty)"

  defp format_existing_skills(rows) do
    rows
    |> Enum.map(fn row ->
      name = row[:skill_name] || row["skill_name"] || "?"
      cat = row[:category] || row["category"] || ""
      desc = row[:skill_description] || row["skill_description"] || ""

      "- #{name} [#{cat}]" <> if(desc == "", do: "", else: " — #{desc}")
    end)
    |> Enum.join("\n")
  end

  defp normalize_gap(gap) when is_map(gap) do
    %{
      skill_name: get(gap, :skill_name) || "",
      category: get(gap, :category) || "",
      rationale: get(gap, :rationale) || ""
    }
  end

  defp normalize_gap(_), do: %{skill_name: "", category: "", rationale: ""}

  defp intake_field(intake, key) do
    case get(intake, key) do
      nil -> "(none)"
      "" -> "(none)"
      v when is_binary(v) -> v
      other -> to_string(other)
    end
  end

  defp get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp get(_, _), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
