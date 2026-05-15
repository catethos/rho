defmodule Rho.Stdlib.DataTable.WorkbenchContext do
  @moduledoc """
  Derived artifact/workflow summary for the DataTable workbench.

  This module is intentionally pure. It interprets DataTable snapshots,
  selections, schemas, and optional effect metadata into compact user-facing
  summaries for both the Phoenix UI and agent prompt sections. It is not a
  second source of truth; rows and table state remain owned by
  `Rho.Stdlib.DataTable.Server`.
  """

  alias Rho.Stdlib.DataTable.Schema

  defmodule ArtifactSummary do
    @moduledoc "Compact user-facing summary for one DataTable-backed artifact."
    defstruct table_name: nil,
              kind: :generic_table,
              title: "Data Table",
              subtitle: nil,
              source_label: nil,
              workflow: nil,
              row_count: 0,
              metrics: %{},
              state: [],
              selected_count: 0,
              selected_preview: [],
              linked: %{},
              actions: [],
              surface: nil,
              columns: []
  end

  defmodule WorkflowSummary do
    @moduledoc "Compact summary of the workflow that produced linked artifacts."
    defstruct id: nil,
              title: nil,
              source_label: nil,
              artifact_tables: [],
              active_table: nil,
              summary: nil,
              next_actions: []
  end

  defstruct active_table: nil,
            workflow: nil,
            artifacts: [],
            active_artifact: nil,
            debug: %{}

  @known_kinds [
    :skill_library,
    :role_profile,
    :role_candidates,
    :combine_preview,
    :dedup_preview,
    :analysis_result,
    :generic_table
  ]

  @doc """
  Build a workbench context from snapshot-like inputs.

  Expected keys:

    * `:tables` - session snapshot table summaries
    * `:table_order` - optional table ordering
    * `:active_table` - currently focused table name
    * `:active_snapshot` - full snapshot for the active table
    * `:selections` - `%{table_name => MapSet.t() | [row_id]}`
    * `:metadata` - optional metadata from the latest table effect
  """
  def build(opts) when is_map(opts) do
    tables = Map.get(opts, :tables, [])
    order = Map.get(opts, :table_order, []) || []
    active_table = Map.get(opts, :active_table)
    active_snapshot = Map.get(opts, :active_snapshot)
    metadata = normalize_metadata(Map.get(opts, :metadata, %{}))
    selections = Map.get(opts, :selections, %{}) || %{}

    ordered_tables = ordered_tables(tables, order)

    artifacts =
      Enum.map(ordered_tables, fn table ->
        rows = rows_for(table, active_table, active_snapshot)
        selected_ids = selected_ids(selections, table_name(table))

        artifact_summary(table, rows,
          active?: table_name(table) == active_table,
          metadata: metadata_for_table(metadata, table_name(table), active_table),
          selected_ids: selected_ids
        )
      end)

    active_artifact = Enum.find(artifacts, &(&1.table_name == active_table))
    workflow = workflow_summary(active_artifact, artifacts, metadata, active_table)

    %__MODULE__{
      active_table: active_table,
      workflow: workflow,
      artifacts: artifacts,
      active_artifact: active_artifact,
      debug: %{
        table_order: Enum.map(ordered_tables, &table_name/1),
        view_key: Map.get(opts, :view_key)
      }
    }
  end

  def build(_), do: build(%{})

  @doc "Render a compact prompt section body in markdown or XML."
  def render_prompt(ctx, format \\ :markdown)

  def render_prompt(%__MODULE__{} = ctx, :xml) do
    workflow = ctx.workflow

    artifacts =
      Enum.map_join(ctx.artifacts, "\n", fn artifact ->
        active = artifact.table_name == ctx.active_table
        metrics = metric_summary(artifact)

        """
          <artifact table="#{escape_xml(artifact.table_name)}" kind="#{artifact.kind}" active="#{active}" rows="#{artifact.row_count}">
            <display>#{escape_xml(artifact.title)}</display>
            <summary>#{escape_xml(metrics)}</summary>
            <columns>#{escape_xml(if(active, do: Enum.join(artifact.columns, ", "), else: ""))}</columns>
          </artifact>\
        """
      end)

    selected = render_selected_xml(ctx.active_artifact)

    """
    <workbench_context active_table="#{escape_xml(ctx.active_table || "")}">
      <workflow id="#{workflow && workflow.id}">#{escape_xml((workflow && workflow.title) || "")}</workflow>
    #{artifacts}
    #{selected}
      <instruction>When the user says this framework, these skills, selected skills, or the table, prefer the active artifact unless they name another artifact explicitly.</instruction>
    </workbench_context>\
    """
  end

  def render_prompt(%__MODULE__{} = ctx, _format) do
    workflow = ctx.workflow

    header =
      case workflow do
        %WorkflowSummary{id: id, title: title, source_label: source} when not is_nil(id) ->
          ["Workbench context", "Workflow: #{title}", source && "Source: #{source}"]

        _ ->
          ["Workbench context"]
      end
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    artifacts =
      Enum.map_join(ctx.artifacts, "\n", fn artifact ->
        marker = if artifact.table_name == ctx.active_table, do: " currently open", else: ""

        columns =
          if artifact.table_name == ctx.active_table and artifact.columns != [] do
            "\n  columns: #{Enum.join(artifact.columns, ", ")}"
          else
            ""
          end

        "- #{artifact.table_name} [#{artifact.kind}]#{marker}\n" <>
          "  display: #{artifact.title}\n" <>
          "  summary: #{metric_summary(artifact)}" <>
          columns <>
          selected_count_line(artifact)
      end)

    selected = render_selected_markdown(ctx.active_artifact)

    """
    #{header}

    Artifacts:
    #{artifacts}
    #{selected}
    When the user says "this framework", "these skills", "selected skills",
    or "the table", they mean the currently open artifact unless they name
    another artifact explicitly. Use the exact table names and column names
    above for data-table tool calls.\
    """
  end

  defp artifact_summary(table, rows, opts) do
    metadata = Keyword.fetch!(opts, :metadata)
    selected_ids = Keyword.fetch!(opts, :selected_ids)
    name = table_name(table)
    schema = table_schema(table)
    kind = infer_kind(name, schema, metadata)
    row_count = table_row_count(table, rows)
    metrics = metrics(kind, rows, row_count, selected_ids, metadata)
    state = states(kind, metrics, metadata, row_count)

    %ArtifactSummary{
      table_name: name,
      kind: kind,
      title: title(kind, name, metadata, row_count),
      subtitle: subtitle(kind, name, metadata, row_count),
      source_label:
        first_metadata(metadata, [:source_label, :source_document_name, :source_upload_id]),
      workflow: metadata[:workflow],
      row_count: row_count,
      metrics: metrics,
      state: state,
      selected_count: length(selected_ids),
      selected_preview: selected_preview(kind, rows, selected_ids),
      linked: linked(metadata),
      actions: actions(kind, metrics, state, row_count, metadata),
      surface: metadata[:ui_intent],
      columns: column_names(schema)
    }
  end

  defp infer_kind(_name, _schema, %{artifact_kind: kind}) when kind in @known_kinds, do: kind

  defp infer_kind(_name, _schema, %{artifact_kind: kind}) when is_binary(kind),
    do: normalize_kind(kind)

  defp infer_kind(name, schema, _metadata) do
    schema_name = schema_name(schema)

    cond do
      schema_name == "library" or starts_with?(name, "library:") or name == "library" ->
        :skill_library

      schema_name == "role_profile" or name == "role_profile" ->
        :role_profile

      schema_name == "role_candidates" or name == "role_candidates" ->
        :role_candidates

      schema_name == "combine_preview" or name == "combine_preview" ->
        :combine_preview

      schema_name == "dedup_preview" or name == "dedup_preview" ->
        :dedup_preview

      schema_name in ["analysis_result", "gap_analysis", "gap_review", "lens_scoring"] or
          name in ["analysis_result", "gap_analysis", "gap_review", "lens_scoring"] ->
        :analysis_result

      true ->
        :generic_table
    end
  rescue
    ArgumentError -> :generic_table
  end

  defp normalize_kind(kind) when kind in @known_kinds, do: kind
  defp normalize_kind("skill_library"), do: :skill_library
  defp normalize_kind("role_profile"), do: :role_profile
  defp normalize_kind("role_candidates"), do: :role_candidates
  defp normalize_kind("combine_preview"), do: :combine_preview
  defp normalize_kind("dedup_preview"), do: :dedup_preview
  defp normalize_kind("analysis_result"), do: :analysis_result
  defp normalize_kind("gap_analysis"), do: :analysis_result
  defp normalize_kind("gap_review"), do: :analysis_result
  defp normalize_kind("lens_scoring"), do: :analysis_result
  defp normalize_kind("generic_table"), do: :generic_table
  defp normalize_kind(_), do: :generic_table

  defp metrics(:skill_library, rows, row_count, _selected_ids, _metadata) do
    %{
      skills: row_count,
      categories: rows |> unique_count(:category),
      clusters: rows |> unique_pair_count(:category, :cluster),
      proficiency_levels:
        Enum.reduce(rows, 0, &(&2 + length(list_value(&1, :proficiency_levels)))),
      missing_levels: Enum.count(rows, &(list_value(&1, :proficiency_levels) == []))
    }
  end

  defp metrics(:role_profile, rows, row_count, _selected_ids, _metadata) do
    required = Enum.count(rows, &(fetch(&1, :required) == true))

    %{
      required_skills: row_count,
      required: required,
      optional: max(row_count - required, 0),
      missing_required_levels: Enum.count(rows, &blank_or_zero?(fetch(&1, :required_level))),
      unverified: Enum.count(rows, &unverified?/1)
    }
  end

  defp metrics(:role_candidates, rows, row_count, selected_ids, metadata) do
    %{
      candidates: metadata[:candidate_count] || row_count,
      queries: metadata[:query_count] || unique_count(rows, :query),
      selected: length(selected_ids)
    }
  end

  defp metrics(kind, rows, row_count, _selected_ids, metadata)
       when kind in [:combine_preview, :dedup_preview] do
    pairs = metadata[:conflict_count] || row_count
    unresolved = metadata[:unresolved_count] || Enum.count(rows, &unresolved?/1)

    %{
      pairs: pairs,
      clean: metadata[:clean_count],
      unresolved: unresolved,
      resolved: max(pairs - unresolved, 0),
      clusters: unique_count(rows, :cluster)
    }
  end

  defp metrics(:analysis_result, rows, row_count, _selected_ids, metadata) do
    recommendations = metadata[:recommendation_count] || metadata[:finding_count] || row_count
    unresolved = metadata[:unresolved_count] || Enum.count(rows, &unresolved_finding?/1)

    %{
      recommendations: recommendations,
      high_priority: metadata[:high_priority_count] || Enum.count(rows, &high_priority?/1),
      unresolved: unresolved,
      resolved: max(recommendations - unresolved, 0)
    }
  end

  defp metrics(_kind, _rows, row_count, _selected_ids, _metadata), do: %{rows: row_count}

  defp states(:skill_library, metrics, metadata, row_count) do
    []
    |> maybe_state(:draft, row_count > 0)
    |> maybe_state(:generated, truthy?(metadata[:generated?]))
    |> maybe_state(:imported, truthy?(metadata[:imported?]))
    |> maybe_state(:saved, truthy?(metadata[:persisted?]))
    |> maybe_state(:published, truthy?(metadata[:published?]))
    |> maybe_state(:needs_levels, Map.get(metrics, :missing_levels, 0) > 0)
    |> maybe_state(
      :ready_to_publish,
      truthy?(metadata[:persisted?]) and Map.get(metrics, :missing_levels, 0) == 0
    )
  end

  defp states(:role_profile, metrics, _metadata, row_count) do
    []
    |> maybe_state(:draft, row_count > 0)
    |> maybe_state(:needs_review, Map.get(metrics, :unverified, 0) > 0)
    |> maybe_state(:ready_to_save, row_count > 0)
  end

  defp states(:role_candidates, metrics, _metadata, _row_count) do
    if Map.get(metrics, :selected, 0) > 0, do: [:has_selection], else: [:awaiting_selection]
  end

  defp states(kind, metrics, _metadata, row_count)
       when kind in [:combine_preview, :dedup_preview] do
    []
    |> maybe_state(:needs_resolution, Map.get(metrics, :unresolved, 0) > 0)
    |> maybe_state(:ready_to_apply, row_count > 0 and Map.get(metrics, :unresolved, 0) == 0)
  end

  defp states(:analysis_result, metrics, _metadata, row_count) do
    []
    |> maybe_state(:needs_review, Map.get(metrics, :unresolved, 0) > 0)
    |> maybe_state(:ready_to_apply, row_count > 0 and Map.get(metrics, :unresolved, 0) == 0)
  end

  defp states(_kind, _metrics, _metadata, _row_count), do: []

  defp actions(:skill_library, metrics, state, row_count, metadata) do
    [:export]
    |> maybe_action(:save_draft, row_count > 0)
    |> maybe_action(:generate_levels, Map.get(metrics, :missing_levels, 0) > 0)
    |> maybe_action(:suggest_skills, row_count > 0)
    |> maybe_action(:publish, :saved in state or truthy?(metadata[:persisted?]))
    |> maybe_action(:fork, truthy?(metadata[:persisted?]))
    |> maybe_action(:dedup, truthy?(metadata[:persisted?]))
    |> Enum.reverse()
  end

  defp actions(:role_profile, _metrics, _state, row_count, metadata) do
    []
    |> maybe_action(:save_role_profile, row_count > 0)
    |> maybe_action(
      :map_to_framework,
      present?(metadata[:linked_library_table]) or present?(metadata[:library_id])
    )
    |> maybe_action(:review_gaps, row_count > 0)
    |> maybe_action(:export, row_count > 0)
    |> Enum.reverse()
  end

  defp actions(:role_candidates, metrics, _state, _row_count, _metadata) do
    selected = Map.get(metrics, :selected, 0)

    []
    |> maybe_action(:seed_framework_from_selected, selected > 0)
    |> maybe_action(:clone_selected_role, selected == 1)
    |> maybe_action(:clear_selection, selected > 0)
    |> Enum.reverse()
  end

  defp actions(:combine_preview, metrics, _state, row_count, _metadata) do
    []
    |> maybe_action(:resolve_conflicts, Map.get(metrics, :unresolved, 0) > 0)
    |> maybe_action(
      :create_merged_library,
      row_count > 0 and Map.get(metrics, :unresolved, 0) == 0
    )
    |> maybe_action(:export_review, row_count > 0)
    |> Enum.reverse()
  end

  defp actions(:dedup_preview, metrics, _state, row_count, _metadata) do
    []
    |> maybe_action(:resolve_duplicates, Map.get(metrics, :unresolved, 0) > 0)
    |> maybe_action(:apply_cleanup, row_count > 0 and Map.get(metrics, :unresolved, 0) == 0)
    |> maybe_action(
      :save_cleaned_framework,
      row_count > 0 and Map.get(metrics, :unresolved, 0) == 0
    )
    |> maybe_action(:export_review, row_count > 0)
    |> Enum.reverse()
  end

  defp actions(:analysis_result, metrics, _state, row_count, _metadata) do
    []
    |> maybe_action(:review_findings, Map.get(metrics, :unresolved, 0) > 0)
    |> maybe_action(
      :apply_recommendations,
      row_count > 0 and Map.get(metrics, :unresolved, 0) == 0
    )
    |> maybe_action(:export_review, row_count > 0)
    |> Enum.reverse()
  end

  defp actions(_kind, _metrics, _state, row_count, _metadata) do
    if row_count > 0, do: [:export], else: []
  end

  defp workflow_summary(nil, _artifacts, _metadata, _active_table), do: nil

  defp workflow_summary(active_artifact, artifacts, metadata, active_table) do
    id = active_artifact.workflow || metadata[:workflow]

    %WorkflowSummary{
      id: id,
      title: workflow_title(id),
      source_label: active_artifact.source_label,
      artifact_tables: Enum.map(artifacts, & &1.table_name),
      active_table: active_table,
      summary: workflow_text(id),
      next_actions: active_artifact.actions
    }
  end

  defp title(:skill_library, name, metadata, _row_count) do
    cond do
      present?(metadata[:title]) -> metadata[:title]
      present?(metadata[:library_name]) -> "#{metadata[:library_name]} Skill Framework"
      starts_with?(name, "library:") -> "#{String.trim_leading(name, "library:")} Skill Framework"
      true -> "Skill Framework"
    end
  end

  defp title(:role_profile, _name, metadata, _row_count) do
    cond do
      present?(metadata[:title]) -> metadata[:title]
      present?(metadata[:role_name]) -> "#{metadata[:role_name]} Role Requirements"
      true -> "Role Requirements"
    end
  end

  defp title(:role_candidates, _name, metadata, _row_count), do: metadata[:title] || "Candidate Roles"
  defp title(:combine_preview, _name, metadata, _row_count), do: metadata[:title] || "Combine Libraries"
  defp title(:dedup_preview, _name, metadata, _row_count), do: metadata[:title] || "Duplicate Review"
  defp title(:analysis_result, _name, metadata, _row_count), do: metadata[:title] || "Gap Review"

  defp title(:generic_table, "main", metadata, row_count) do
    cond do
      present?(metadata[:title]) -> metadata[:title]
      row_count > 0 -> "Scratch Table"
      true -> "Artifact Workbench"
    end
  end

  defp title(_kind, name, metadata, _row_count),
    do: metadata[:title] || humanize_name(name || "data_table")

  defp subtitle(:skill_library, _name, metadata, _row_count),
    do: metadata[:subtitle] || "Reusable skill taxonomy"

  defp subtitle(:role_profile, _name, metadata, _row_count),
    do: metadata[:subtitle] || "Demand profile for a role"

  defp subtitle(:role_candidates, _name, metadata, _row_count),
    do: metadata[:subtitle] || "Picker for selecting source roles"

  defp subtitle(:combine_preview, _name, metadata, _row_count),
    do: metadata[:subtitle] || "Review conflicts before creating a merged library"

  defp subtitle(:dedup_preview, _name, metadata, _row_count),
    do: metadata[:subtitle] || "Review likely duplicate skills"

  defp subtitle(:analysis_result, _name, metadata, _row_count),
    do: metadata[:subtitle] || "Review recommendations before applying changes"

  defp subtitle(:generic_table, "main", metadata, 0),
    do: metadata[:subtitle] || "Start a workflow to create a skill framework or review artifact"

  defp subtitle(:generic_table, "main", metadata, _row_count),
    do: metadata[:subtitle] || "Ad hoc rows that are not attached to a named workflow artifact"

  defp subtitle(_kind, _name, metadata, _row_count), do: metadata[:subtitle]

  defp selected_preview(_kind, _rows, []), do: []

  defp selected_preview(kind, rows, selected_ids) do
    rows_by_id = Map.new(rows, fn row -> {fetch(row, :id), row} end)

    selected_ids
    |> Enum.take(10)
    |> Enum.map(fn id ->
      row = Map.get(rows_by_id, id, %{})
      %{id: id, label: preview_label(kind, row), detail: preview_detail(kind, row)}
    end)
  end

  defp preview_label(kind, row) when kind in [:skill_library, :role_profile],
    do: fetch(row, :skill_name) || "(unnamed skill)"

  defp preview_label(:role_candidates, row), do: fetch(row, :role_name) || "(unnamed role)"

  defp preview_label(kind, row) when kind in [:combine_preview, :dedup_preview] do
    [fetch(row, :skill_a_name), fetch(row, :skill_b_name)]
    |> Enum.filter(&present?/1)
    |> Enum.join(" / ")
    |> case do
      "" -> "(unlabeled pair)"
      label -> label
    end
  end

  defp preview_label(:analysis_result, row),
    do:
      fetch(row, :recommendation) || fetch(row, :finding) || fetch(row, :skill_name) ||
        fetch(row, :title) || "(finding)"

  defp preview_label(_kind, row),
    do: fetch(row, :name) || fetch(row, :title) || fetch(row, :id) || "(row)"

  defp preview_detail(:skill_library, row) do
    levels = length(list_value(row, :proficiency_levels))
    [fetch(row, :category), fetch(row, :cluster), "#{levels} levels"] |> compact_join(", ")
  end

  defp preview_detail(:role_profile, row) do
    required = if fetch(row, :required), do: "required", else: "optional"
    compact_join([required, "level #{fetch(row, :required_level)}", fetch(row, :priority)], ", ")
  end

  defp preview_detail(:role_candidates, row) do
    compact_join(
      [fetch(row, :role_family), fetch(row, :seniority_label), "rank #{fetch(row, :rank)}"],
      ", "
    )
  end

  defp preview_detail(kind, row) when kind in [:combine_preview, :dedup_preview] do
    compact_join([fetch(row, :confidence), fetch(row, :resolution) || "unresolved"], ", ")
  end

  defp preview_detail(:analysis_result, row) do
    compact_join([fetch(row, :severity), fetch(row, :priority), fetch(row, :status)], ", ")
  end

  defp preview_detail(_kind, _row), do: nil

  defp metric_summary(%ArtifactSummary{kind: :skill_library, metrics: m}) do
    "#{m.skills} skills, #{m.categories} categories, #{m.proficiency_levels} proficiency levels, #{m.missing_levels} need levels"
  end

  defp metric_summary(%ArtifactSummary{kind: :role_profile, metrics: m}) do
    "#{m.required_skills} required skills, #{m.required} required, #{m.optional} optional, #{m.missing_required_levels} missing levels"
  end

  defp metric_summary(%ArtifactSummary{kind: :role_candidates, metrics: m}) do
    "#{m.candidates} candidates, #{m.queries} queries, #{m.selected} selected"
  end

  defp metric_summary(%ArtifactSummary{kind: kind, metrics: m})
       when kind in [:combine_preview, :dedup_preview] do
    clean = if is_integer(m[:clean]), do: ", #{m.clean} clean", else: ""
    "#{m.pairs} pairs#{clean}, #{m.unresolved} unresolved, #{m.resolved} resolved"
  end

  defp metric_summary(%ArtifactSummary{kind: :analysis_result, metrics: m}) do
    "#{m.recommendations} recommendations, #{m.high_priority} high priority, #{m.unresolved} unresolved"
  end

  defp metric_summary(%ArtifactSummary{row_count: row_count}), do: "#{row_count} rows"

  defp render_selected_markdown(nil), do: ""
  defp render_selected_markdown(%ArtifactSummary{selected_preview: []}), do: ""

  defp render_selected_markdown(%ArtifactSummary{} = artifact) do
    rows =
      artifact.selected_preview
      |> Enum.map(fn preview ->
        detail = if present?(preview.detail), do: " #{preview.detail}", else: ""
        "- #{preview.id} #{preview.label}#{detail}"
      end)
      |> then(fn rows ->
        rest = artifact.selected_count - length(rows)
        if rest > 0, do: rows ++ ["- ... + #{rest} more selected"], else: rows
      end)
      |> Enum.join("\n")

    "\nSelected rows in #{artifact.table_name}:\n#{rows}\n"
  end

  defp render_selected_xml(nil), do: ""
  defp render_selected_xml(%ArtifactSummary{selected_preview: []}), do: ""

  defp render_selected_xml(%ArtifactSummary{} = artifact) do
    rows =
      Enum.map_join(artifact.selected_preview, "\n", fn preview ->
        ~s(    <row id="#{escape_xml(preview.id)}" label="#{escape_xml(preview.label)}" detail="#{escape_xml(preview.detail || "")}" />)
      end)

    """
      <selected_rows table="#{escape_xml(artifact.table_name)}">
    #{rows}
      </selected_rows>\
    """
  end

  defp selected_count_line(%ArtifactSummary{selected_count: 0}), do: ""
  defp selected_count_line(%ArtifactSummary{selected_count: count}), do: "\n  selected: #{count}"

  defp ordered_tables(tables, []), do: tables

  defp ordered_tables(tables, order) do
    by_name = Map.new(tables, &{table_name(&1), &1})
    ordered = order |> Enum.filter(&by_name[&1]) |> Enum.map(&by_name[&1])
    extra = Enum.reject(tables, &(table_name(&1) in order))
    ordered ++ extra
  end

  defp rows_for(table, active_table, active_snapshot) do
    if table_name(table) == active_table do
      Map.get(active_snapshot || %{}, :rows, []) || []
    else
      []
    end
  end

  defp table_name(%{name: name}), do: name
  defp table_name(%{"name" => name}), do: name
  defp table_name(_), do: nil

  defp table_schema(%{schema: schema}), do: schema
  defp table_schema(%{"schema" => schema}), do: schema
  defp table_schema(_), do: nil

  defp table_row_count(table, rows) do
    cond do
      is_integer(get_in_map(table, :row_count)) -> get_in_map(table, :row_count)
      rows != [] -> length(rows)
      true -> 0
    end
  end

  defp schema_name(%Schema{name: name}), do: name
  defp schema_name(%{name: name}), do: name
  defp schema_name(%{"name" => name}), do: name
  defp schema_name(_), do: nil

  defp column_names(%Schema{} = schema),
    do: Enum.map(Schema.column_names(schema), &Atom.to_string/1)

  defp column_names(_), do: []

  defp selected_ids(selections, table) do
    case Map.get(selections, table) || Map.get(selections, to_string(table || "")) do
      %MapSet{} = set -> MapSet.to_list(set)
      ids when is_list(ids) -> ids
      _ -> []
    end
  end

  defp metadata_for_table(metadata, table, active_table) do
    if table == active_table, do: metadata, else: %{}
  end

  defp normalize_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn {key, value} ->
      normalized =
        cond do
          is_atom(key) -> key
          is_binary(key) -> safe_existing_atom(key) || key
          true -> key
        end

      {normalized, value}
    end)
  end

  defp normalize_metadata(_), do: %{}

  defp first_metadata(metadata, keys) do
    Enum.find_value(keys, fn key ->
      value = metadata[key]
      if present?(value), do: value
    end)
  end

  defp linked(metadata) do
    metadata
    |> Map.take([
      :linked_library_table,
      :linked_role_table,
      :source_upload_id,
      :source_library_ids,
      :source_role_profile_ids,
      :output_table
    ])
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp fetch(row, key) when is_map(row),
    do: Map.get(row, key) || Map.get(row, Atom.to_string(key))

  defp fetch(_, _), do: nil

  defp get_in_map(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp get_in_map(_, _), do: nil

  defp list_value(row, key) do
    case fetch(row, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp unique_count(rows, key) do
    rows
    |> Enum.map(&fetch(&1, key))
    |> Enum.reject(&blank?/1)
    |> MapSet.new()
    |> MapSet.size()
  end

  defp unique_pair_count(rows, key_a, key_b) do
    rows
    |> Enum.map(fn row -> {fetch(row, key_a), fetch(row, key_b)} end)
    |> Enum.reject(fn {a, b} -> blank?(a) and blank?(b) end)
    |> MapSet.new()
    |> MapSet.size()
  end

  defp unverified?(row) do
    value = fetch(row, :verification)
    blank?(value) or String.downcase(to_string(value)) not in ["accepted", "verified", "ok"]
  end

  defp unresolved?(row) do
    value = fetch(row, :resolution)
    blank?(value) or String.downcase(to_string(value)) == "unresolved"
  end

  defp unresolved_finding?(row) do
    value = fetch(row, :status) || fetch(row, :decision) || fetch(row, :resolution)
    blank?(value) or String.downcase(to_string(value)) in ["open", "unresolved", "pending"]
  end

  defp high_priority?(row) do
    value = fetch(row, :severity) || fetch(row, :priority)
    String.downcase(to_string(value)) in ["high", "critical", "urgent", "p1", "1"]
  end

  defp blank_or_zero?(0), do: true
  defp blank_or_zero?(value), do: blank?(value)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?([]), do: true
  defp blank?(_), do: false

  defp present?(value), do: not blank?(value)
  defp truthy?(value), do: value in [true, "true", 1, "1"]
  defp starts_with?(value, prefix) when is_binary(value), do: String.starts_with?(value, prefix)
  defp starts_with?(_, _), do: false

  defp maybe_state(states, state, true), do: states ++ [state]
  defp maybe_state(states, _state, _), do: states

  defp maybe_action(actions, action, true), do: [action | actions]
  defp maybe_action(actions, _action, _), do: actions

  defp workflow_title(nil), do: nil
  defp workflow_title(:jd_extraction), do: "JD Extraction"
  defp workflow_title(:create_framework), do: "Create Framework"
  defp workflow_title(:import_upload), do: "Import Upload"
  defp workflow_title(:edit_existing), do: "Edit Existing"
  defp workflow_title(:extend_existing), do: "Extend Existing"
  defp workflow_title(:combine_libraries), do: "Combine Libraries"
  defp workflow_title(:dedup_library), do: "Deduplicate Library"
  defp workflow_title(:seed_from_roles), do: "Seed From Roles"
  defp workflow_title(:role_search), do: "Role Search"
  defp workflow_title(:role_profile_edit), do: "Role Profile Edit"
  defp workflow_title(other), do: humanize_name(to_string(other))

  defp workflow_text(:jd_extraction),
    do: "Extracted linked framework and role-requirement artifacts from a job description."

  defp workflow_text(:combine_libraries), do: "Review conflicts before creating a merged library."

  defp workflow_text(:dedup_library),
    do: "Review likely duplicate skills before applying cleanup."

  defp workflow_text(_), do: nil

  defp humanize_name(name) do
    name
    |> to_string()
    |> String.replace(~r/^library:/, "")
    |> String.replace(["_", ":", "-"], " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp compact_join(values, joiner) do
    values
    |> Enum.reject(&blank?/1)
    |> Enum.join(joiner)
  end

  defp escape_xml(nil), do: ""

  defp escape_xml(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp safe_existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end
end
