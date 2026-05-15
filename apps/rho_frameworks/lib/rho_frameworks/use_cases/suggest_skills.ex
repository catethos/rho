defmodule RhoFrameworks.UseCases.SuggestSkills do
  @moduledoc """
  One-shot "Suggest more skills" UseCase — the Direct → escalate-once
  affordance from §11.3 of `docs/swappable-decision-policy-plan.md`.

  Reads the active library + meta tables out of the Workbench, asks
  `RhoFrameworks.LLM.SuggestSkills` for `n` new skills, and pipes each
  fully-formed partial through `Workbench.add_skill/3`. Each row lands
  with `source: :agent` (rows are AI-authored even though the click
  was user-initiated — see §11.3).

  ## Test seam

  The LLM call is overridable via Application env. The function takes
  four args — `(existing, intake, n, on_partial)` — and is responsible
  for invoking `on_partial.(skill)` for each fully-formed skill it
  decides to emit. This keeps persistence (Workbench) inside the
  UseCase and only varies the LLM half:

      Application.put_env(:rho_frameworks, :suggest_fn,
        fn _existing, _intake, _n, on_partial ->
          on_partial.(%{
            category: "Engineering", cluster: "Tooling",
            name: "Vim", description: "Lightweight text editor."
          })
          {:ok, [%{...}]}
        end)

  The default impl wraps `LLM.SuggestSkills.stream/3` and detects
  newly-completed entries as the BAML structured stream grows.
  """

  @behaviour RhoFrameworks.UseCase

  require Logger

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.LLM.SuggestSkills, as: LLM
  alias RhoFrameworks.Scope
  alias RhoFrameworks.Workbench

  @library_default "library"
  @meta_table "meta"
  @max_n 10
  @default_n 5

  @impl true
  def describe do
    %{
      id: :suggest_skills,
      label: "Suggest more skills",
      cost_hint: :cheap,
      doc:
        "One-shot LLM call that proposes additional skills for the active library — " <>
          "rows stream in via Workbench.add_skill so the user can keep editing while " <>
          "they arrive."
    }
  end

  @impl true
  def run(input, %Scope{} = scope) do
    n = clamp_n(Rho.MapAccess.get(input, :n) || @default_n)
    table = Rho.MapAccess.get(input, :table) || @library_default
    suggest_scope = %{scope | source: :agent, reason: "user requested suggest_skills"}

    existing_text = format_existing(scope, table)
    intake_text = format_intake(scope)

    on_partial = fn skill ->
      persist_skill(suggest_scope, table, skill)
    end

    case suggest_fn().(existing_text, intake_text, n, on_partial) do
      {:ok, skills} when is_list(skills) ->
        added =
          skills
          |> Enum.filter(&fully_formed?/1)
          |> Enum.map(fn skill ->
            %{
              name: get(skill, :name),
              category: get(skill, :category),
              cluster: get(skill, :cluster)
            }
          end)

        {:ok, %{requested: n, returned: length(skills), added: added}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_suggest_result, other}}
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Persistence
  # ──────────────────────────────────────────────────────────────────────

  defp persist_skill(%Scope{} = scope, table, skill) do
    case to_row(skill) do
      {:ok, row} ->
        case Workbench.add_skill(scope, row, table: table) do
          {:ok, _row} ->
            :ok

          {:error, {:duplicate_skill_name, _}} ->
            # BAML may re-emit the same partial as the array grows, and
            # the model may also propose a name that already exists in
            # the library. Both are benign — skip silently.
            :ok

          {:error, reason} ->
            Logger.warning(fn ->
              "[SuggestSkills] add_skill failed: #{inspect(reason)} row=#{inspect(row)}"
            end)

            :ok
        end

      :skip ->
        :ok
    end
  end

  defp to_row(skill) when is_map(skill) do
    name = get(skill, :name)
    cluster = get(skill, :cluster)
    description = get(skill, :description)
    category = get(skill, :category)

    if blank?(name) or blank?(cluster) or blank?(description) or blank?(category) do
      :skip
    else
      {:ok,
       %{
         skill_name: name,
         cluster: cluster,
         category: category,
         skill_description: description
       }}
    end
  end

  defp to_row(_), do: :skip

  # ──────────────────────────────────────────────────────────────────────
  # Inputs
  # ──────────────────────────────────────────────────────────────────────

  defp format_existing(%Scope{session_id: session_id}, table) when is_binary(session_id) do
    case DataTable.get_rows(session_id, table: table) do
      rows when is_list(rows) and rows != [] ->
        rows
        |> Enum.map(&format_existing_row/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      _ ->
        "(library is currently empty)"
    end
  end

  defp format_existing(_, _), do: ""

  defp format_existing_row(row) do
    name = get(row, :skill_name)
    cluster = get(row, :cluster)
    category = get(row, :category)

    cond do
      blank?(name) -> ""
      blank?(cluster) and blank?(category) -> "- #{name}"
      blank?(category) -> "- [#{cluster}] #{name}"
      blank?(cluster) -> "- [#{category}] #{name}"
      true -> "- [#{category} / #{cluster}] #{name}"
    end
  end

  defp format_intake(%Scope{session_id: session_id}) when is_binary(session_id) do
    case DataTable.get_rows(session_id, table: @meta_table) do
      [row | _] ->
        name = get(row, :name)
        description = get(row, :description)

        [
          if(!blank?(name), do: "Name: #{name}", else: nil),
          if(!blank?(description), do: "Description: #{description}", else: nil)
        ]
        |> Enum.reject(&is_nil/1)
        |> case do
          [] -> "(no intake provided)"
          parts -> Enum.join(parts, "\n")
        end

      _ ->
        "(no intake provided)"
    end
  end

  defp format_intake(_), do: ""

  # ──────────────────────────────────────────────────────────────────────
  # Seam + default LLM bridge
  # ──────────────────────────────────────────────────────────────────────

  defp suggest_fn do
    Application.get_env(:rho_frameworks, :suggest_fn, &__MODULE__.default_suggest/4)
  end

  @doc """
  Default `:suggest_fn` — bridges `LLM.SuggestSkills.stream/3` to the
  `(existing, intake, n, on_partial)` shape.

  Tracks how many entries have already been forwarded so each
  fully-formed skill is emitted exactly once as the BAML structured
  stream grows.
  """
  @spec default_suggest(String.t(), String.t(), pos_integer(), (map() -> any())) ::
          {:ok, [map()]} | {:error, term()}
  def default_suggest(existing, intake, n, on_partial) do
    pd_key = {__MODULE__, :persisted_count, make_ref()}
    Process.put(pd_key, 0)

    callback = fn partial ->
      skills = extract_skills(partial)
      already = Process.get(pd_key, 0)

      newly =
        skills
        |> Enum.drop(already)
        |> Enum.take_while(&fully_formed?/1)

      Enum.each(newly, on_partial)
      Process.put(pd_key, already + length(newly))
    end

    try do
      case LLM.stream(%{existing: existing, intake: intake, n: n}, callback) do
        {:ok, %LLM{skills: skills}} ->
          {:ok, normalize_skills(skills)}

        {:error, reason} ->
          {:error, reason}
      end
    after
      Process.delete(pd_key)
    end
  end

  defp extract_skills(partial) when is_map(partial) do
    case get(partial, :skills) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp extract_skills(_), do: []

  defp fully_formed?(skill) when is_map(skill) do
    not blank?(get(skill, :name)) and
      not blank?(get(skill, :cluster)) and
      not blank?(get(skill, :description)) and
      not blank?(get(skill, :category))
  end

  defp fully_formed?(_), do: false

  defp normalize_skills(skills) when is_list(skills) do
    Enum.map(skills, fn skill ->
      %{
        category: get(skill, :category),
        cluster: get(skill, :cluster),
        name: get(skill, :name),
        description: get(skill, :description)
      }
    end)
  end

  defp normalize_skills(_), do: []

  # ──────────────────────────────────────────────────────────────────────
  # Misc
  # ──────────────────────────────────────────────────────────────────────

  defp clamp_n(n) when is_integer(n) and n > 0, do: min(n, @max_n)
  defp clamp_n(_), do: @default_n

  defp get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp get(_, _), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
