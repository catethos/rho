defmodule RhoFrameworks.Lenses do
  @moduledoc "Context for lens CRUD, scoring engine, and ARIA seed."

  import Ecto.Query
  alias RhoFrameworks.Repo

  alias RhoFrameworks.Frameworks.{
    Lens,
    LensAxis,
    LensVariable,
    LensClassification,
    LensScore,
    LensAxisScore,
    LensVariableScore,
    WorkActivityTag
  }

  # --- CRUD ---

  def create_lens(org_id, attrs) do
    %Lens{}
    |> Lens.changeset(Map.put(attrs, :organization_id, org_id))
    |> Repo.insert()
  end

  def create_axis(lens_id, attrs) do
    %LensAxis{}
    |> LensAxis.changeset(Map.put(attrs, :lens_id, lens_id))
    |> Repo.insert()
  end

  def create_variables(axis_id, var_attrs_list) do
    results =
      Enum.map(var_attrs_list, fn attrs ->
        %LensVariable{}
        |> LensVariable.changeset(Map.put(attrs, :axis_id, axis_id))
        |> Repo.insert()
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      {:ok, Enum.map(results, fn {:ok, v} -> v end)}
    else
      {:error, errors}
    end
  end

  def create_classification(lens_id, attrs) do
    %LensClassification{}
    |> LensClassification.changeset(Map.put(attrs, :lens_id, lens_id))
    |> Repo.insert()
  end

  def get_lens!(lens_id) do
    Repo.get!(Lens, lens_id)
    |> Repo.preload(axes: {from(a in LensAxis, order_by: a.sort_order), :variables})
    |> Repo.preload(:classifications)
  end

  # --- Scoring Engine ---

  def score(lens_id, target, variable_scores, opts \\ []) do
    lens = get_lens!(lens_id)

    axis_results =
      lens.axes
      |> Enum.sort_by(& &1.sort_order)
      |> Enum.map(fn axis ->
        vars =
          Enum.map(axis.variables, fn var ->
            raw = Map.fetch!(variable_scores, var.key)
            adjusted = if var.inverse, do: 100.0 - raw, else: raw
            weighted = adjusted * var.weight

            %{
              variable_id: var.id,
              raw_score: raw,
              adjusted_score: adjusted,
              weighted_score: weighted
            }
          end)

        composite = vars |> Enum.map(& &1.weighted_score) |> Enum.sum()
        band = classify_band(composite, axis.band_thresholds)

        %{axis_id: axis.id, composite: composite, band: band, variable_scores: vars}
      end)

    classification = classify_matrix(lens, axis_results)

    case persist_score(lens, target, axis_results, classification) do
      {:ok, lens_score} = result ->
        maybe_publish_score_update(lens_score, lens, opts)
        result

      error ->
        error
    end
  end

  defp classify_band(composite, thresholds) do
    thresholds
    |> Enum.sort()
    |> Enum.reduce(0, fn threshold, acc ->
      if composite >= threshold, do: acc + 1, else: acc
    end)
  end

  defp classify_matrix(lens, axis_results) do
    case axis_results do
      [a0, a1] ->
        case Repo.get_by(LensClassification,
               lens_id: lens.id,
               axis_0_band: a0.band,
               axis_1_band: a1.band
             ) do
          nil -> nil
          c -> c.label
        end

      _ ->
        nil
    end
  end

  defp persist_score(lens, target, axis_results, classification) do
    target_attrs = target_to_attrs(target)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(
      :lens_score,
      LensScore.changeset(
        %LensScore{},
        %{
          scored_at: DateTime.utc_now() |> DateTime.truncate(:second),
          scoring_method: lens.scoring_method || "manual",
          classification: classification,
          lens_id: lens.id
        }
        |> Map.merge(target_attrs)
      )
    )
    |> Ecto.Multi.run(:axis_scores, fn repo, %{lens_score: lens_score} ->
      results =
        Enum.map(axis_results, fn axis_result ->
          {:ok, axis_score} =
            repo.insert(
              LensAxisScore.changeset(%LensAxisScore{}, %{
                composite: axis_result.composite,
                band: axis_result.band,
                lens_score_id: lens_score.id,
                axis_id: axis_result.axis_id
              })
            )

          Enum.each(axis_result.variable_scores, fn vs ->
            repo.insert!(
              LensVariableScore.changeset(%LensVariableScore{}, %{
                raw_score: vs.raw_score,
                adjusted_score: vs.adjusted_score,
                weighted_score: vs.weighted_score,
                axis_score_id: axis_score.id,
                variable_id: vs.variable_id
              })
            )
          end)

          axis_score
        end)

      {:ok, results}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{lens_score: lens_score}} ->
        {:ok, Repo.preload(lens_score, axis_scores: :variable_scores)}

      {:error, _step, changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp target_to_attrs(%{skill_id: id}), do: %{skill_id: id}
  defp target_to_attrs(%{role_profile_id: id}), do: %{role_profile_id: id}

  # --- LLM Scoring ---

  @doc """
  Score a target via LLM. Builds a prompt from the lens's variable descriptions
  and the target's data, asks the LLM to analyze and return structured scores.

  For ARIA lenses (score_target: "role_profile"), the LLM also infers work
  activities, tags each one, and persists tags to `work_activity_tags`.

  Options:
    * `:model` - LLM model spec (default: from agent config)
    * `:gen_opts` - additional options passed to ReqLLM (default: from agent config provider)
    * `:session_id` - session for signal publishing
    * `:agent_id` - agent for signal publishing
  """
  def score_via_llm(lens_id, target, opts \\ []) do
    config = Rho.Config.agent_config()
    model = Keyword.get(opts, :model, config.model)
    gen_opts = Keyword.get(opts, :gen_opts, build_gen_opts(config[:provider]))
    lens = get_lens!(lens_id)

    with {:ok, llm_result} <- call_llm_for_scores(lens, target, model, gen_opts),
         :ok <- persist_activity_tags(lens, target, llm_result),
         variable_scores <- extract_variable_scores(lens, llm_result) do
      score(lens.id, target, variable_scores, opts)
    end
  end

  defp build_gen_opts(nil), do: []

  defp build_gen_opts(provider) do
    [provider_options: [openrouter_provider: provider]]
  end

  defp call_llm_for_scores(lens, target, model, gen_opts) do
    system_prompt = build_scoring_system_prompt(lens)
    user_prompt = build_scoring_user_prompt(lens, target)

    schema = build_llm_response_schema(lens)

    messages = [
      ReqLLM.Context.system(system_prompt),
      ReqLLM.Context.user(user_prompt)
    ]

    llm_opts = Keyword.merge(gen_opts, max_tokens: 4096)

    case ReqLLM.generate_object(model, messages, schema, llm_opts) do
      {:ok, response} -> {:ok, ReqLLM.Response.object(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_scoring_system_prompt(lens) do
    axis_descriptions =
      lens.axes
      |> Enum.sort_by(& &1.sort_order)
      |> Enum.map(fn axis ->
        var_lines =
          Enum.map(axis.variables, fn var ->
            inverse_note =
              if var.inverse, do: " (inverse: higher raw = lower contribution)", else: ""

            "  - #{var.key} (#{var.name}, weight: #{var.weight}#{inverse_note}): #{var.description}"
          end)
          |> Enum.join("\n")

        "Axis: #{axis.name} (#{axis.short_name})\n#{var_lines}"
      end)
      |> Enum.join("\n\n")

    """
    You are a workforce analyst scoring targets using the "#{lens.name}" lens.

    #{lens.description}

    Scoring dimensions:
    #{axis_descriptions}

    For each variable, provide a score from 0 to 100 with a brief rationale.
    If the lens targets role profiles, first infer the role's key work activities \
    and classify each as: automatable, augmentable, human_essential, or data_dependent.
    Then use those classifications to inform your variable scores.

    Be precise and evidence-based. Use the role's skills, description, and context to justify scores.
    """
  end

  defp build_scoring_user_prompt(lens, %{role_profile_id: rp_id})
       when lens.score_target == "role_profile" do
    rp =
      Repo.get!(RhoFrameworks.Frameworks.RoleProfile, rp_id)
      |> Repo.preload(role_skills: :skill)

    skills_text =
      rp.role_skills
      |> Enum.map(fn rs ->
        "- #{rs.skill.name} (#{rs.skill.category}/#{rs.skill.cluster}) — required level: #{rs.min_expected_level}"
      end)
      |> Enum.join("\n")

    """
    Score this role profile:

    Name: #{rp.name}
    #{if rp.description, do: "Description: #{rp.description}\n", else: ""}#{if rp.purpose, do: "Purpose: #{rp.purpose}\n", else: ""}#{if rp.accountabilities, do: "Accountabilities: #{rp.accountabilities}\n", else: ""}#{if rp.role_family, do: "Role Family: #{rp.role_family}\n", else: ""}#{if rp.seniority_label, do: "Seniority: #{rp.seniority_label}\n", else: ""}
    Skills:
    #{skills_text}
    """
  end

  defp build_scoring_user_prompt(_lens, %{skill_id: skill_id}) do
    skill = Repo.get!(RhoFrameworks.Frameworks.Skill, skill_id)

    """
    Score this skill:

    Name: #{skill.name}
    Category: #{skill.category}
    Cluster: #{skill.cluster}
    #{if skill.description, do: "Description: #{skill.description}\n", else: ""}
    """
  end

  defp build_llm_response_schema(lens) do
    score_entry_schema =
      {:map,
       [
         key: [type: :string, required: true, doc: "Variable key"],
         score: [type: :float, required: true, doc: "Score 0-100"],
         rationale: [type: :string, required: true, doc: "Brief justification"]
       ]}

    base = [
      variable_scores: [
        type: {:list, score_entry_schema},
        required: true,
        doc: "One entry per variable key: " <> variable_keys_doc(lens)
      ]
    ]

    if lens.score_target == "role_profile" do
      activity_schema =
        {:map,
         [
           activity: [type: :string, required: true, doc: "Description of the work activity"],
           tag: [
             type: :string,
             required: true,
             doc: "One of: automatable, augmentable, human_essential, data_dependent"
           ],
           confidence: [type: :float, required: true, doc: "Confidence in tag 0.0-1.0"]
         ]}

      [
        {:work_activities,
         [
           type: {:list, activity_schema},
           required: true,
           doc: "Inferred work activities with AI-readiness tags"
         ]}
        | base
      ]
    else
      base
    end
  end

  defp variable_keys_doc(lens) do
    lens.axes
    |> Enum.sort_by(& &1.sort_order)
    |> Enum.flat_map(fn axis -> Enum.map(axis.variables, & &1.key) end)
    |> Enum.join(", ")
  end

  defp persist_activity_tags(lens, %{role_profile_id: rp_id}, %{"work_activities" => activities})
       when is_list(activities) do
    Enum.each(activities, fn activity ->
      %WorkActivityTag{}
      |> WorkActivityTag.changeset(%{
        tag: activity["tag"],
        confidence: activity["confidence"],
        activity_description: activity["activity"],
        role_profile_id: rp_id,
        lens_id: lens.id
      })
      |> Repo.insert(on_conflict: :nothing)
    end)

    :ok
  end

  defp persist_activity_tags(_lens, _target, _llm_result), do: :ok

  defp extract_variable_scores(_lens, %{"variable_scores" => vs}) when is_list(vs) do
    Map.new(vs, fn %{"key" => key, "score" => score} -> {key, score / 1} end)
  end

  # --- ARIA Seed ---

  def seed_aria_lens(org_id) do
    {:ok, lens} =
      create_lens(org_id, %{
        name: "ARIA — AI Readiness Impact Assessment",
        slug: "aria",
        description: "Evaluates roles on AI disruption potential and organizational adaptability",
        status: "active",
        score_target: "role_profile",
        scoring_method: "hybrid"
      })

    # X-axis: AI Impact
    {:ok, x_axis} =
      create_axis(lens.id, %{
        sort_order: 0,
        name: "AI Impact",
        short_name: "AII",
        band_thresholds: [40.0, 70.0],
        band_labels: ["low", "medium", "high"]
      })

    {:ok, _} =
      create_variables(x_axis.id, [
        %{
          key: "at",
          name: "Automatable Task %",
          weight: 0.30,
          description:
            "Percentage of role's work activities classifiable as automatable by current/near-term AI"
        },
        %{
          key: "td",
          name: "Tool Displacement Risk",
          weight: 0.25,
          description: "Likelihood existing tools/processes will be replaced by AI alternatives"
        },
        %{
          key: "dr",
          name: "Data Routine Intensity",
          weight: 0.25,
          description: "Degree to which role involves repetitive data processing"
        },
        %{
          key: "os",
          name: "Output Standardization",
          weight: 0.20,
          description: "How standardized/templated are the role's deliverables"
        }
      ])

    # Y-axis: Adaptability
    {:ok, y_axis} =
      create_axis(lens.id, %{
        sort_order: 1,
        name: "Adaptability",
        short_name: "ADP",
        band_thresholds: [40.0, 70.0],
        band_labels: ["low", "medium", "high"]
      })

    {:ok, _} =
      create_variables(y_axis.id, [
        %{
          key: "tla",
          name: "Technical Learning Agility",
          weight: 0.30,
          description: "Role's required ability to learn and adopt new technical tools"
        },
        %{
          key: "atp",
          name: "AI Tool Proficiency",
          weight: 0.25,
          description: "Current AI/ML tool usage in role's skill requirements"
        },
        %{
          key: "cfb",
          name: "Cross-functional Breadth",
          weight: 0.25,
          description: "Breadth of collaboration across teams and disciplines"
        },
        %{
          key: "csr",
          name: "Creative/Strategic Ratio",
          weight: 0.20,
          description: "Proportion of work requiring creative judgment vs routine execution"
        }
      ])

    # Classifications (3 bands per axis = 9 cells)
    classifications = [
      %{
        axis_0_band: 2,
        axis_1_band: 2,
        label: "Transform",
        color: "#3B82F6",
        description: "Role will change significantly but can adapt"
      },
      %{
        axis_0_band: 2,
        axis_1_band: 0,
        label: "Restructure",
        color: "#EF4444",
        description: "Role at risk, needs intervention"
      },
      %{
        axis_0_band: 0,
        axis_1_band: 2,
        label: "Leverage",
        color: "#10B981",
        description: "Well-positioned to adopt AI tools proactively"
      },
      %{
        axis_0_band: 0,
        axis_1_band: 0,
        label: "Maintain",
        color: "#6B7280",
        description: "Low urgency, continue current path"
      },
      %{axis_0_band: 1, axis_1_band: 2, label: "Transform", color: "#3B82F6"},
      %{axis_0_band: 2, axis_1_band: 1, label: "Restructure", color: "#EF4444"},
      %{axis_0_band: 1, axis_1_band: 0, label: "Maintain", color: "#6B7280"},
      %{axis_0_band: 0, axis_1_band: 1, label: "Leverage", color: "#10B981"},
      %{
        axis_0_band: 1,
        axis_1_band: 1,
        label: "Monitor",
        color: "#F59E0B",
        description: "Moderate impact and adaptability — monitor and prepare"
      }
    ]

    Enum.each(classifications, &create_classification(lens.id, &1))

    {:ok, lens}
  end

  # --- Dashboard Data Queries ---

  @doc "Counts of latest scores grouped by classification label."
  def scores_by_classification(lens_id) do
    latest_scores_query(lens_id)
    |> group_by([s], s.classification)
    |> select([s], %{classification: s.classification, count: count(s.id)})
    |> Repo.all()
  end

  @doc "All latest scores with per-axis composites, for scatter/chart rendering."
  def scores_with_axes(lens_id) do
    scores =
      latest_scores_query(lens_id)
      |> preload(axis_scores: :variable_scores)
      |> Repo.all()

    lens = get_lens!(lens_id)
    axes_by_id = Map.new(lens.axes, &{&1.id, &1})

    Enum.map(scores, fn score ->
      axis_data =
        Enum.map(score.axis_scores, fn as ->
          axis = Map.get(axes_by_id, as.axis_id)

          %{
            axis_name: axis && axis.name,
            short_name: axis && axis.short_name,
            sort_order: axis && axis.sort_order,
            composite: as.composite,
            band: as.band
          }
        end)
        |> Enum.sort_by(& &1.sort_order)

      %{
        score_id: score.id,
        classification: score.classification,
        scored_at: score.scored_at,
        target: score_target_info(score),
        axes: axis_data
      }
    end)
  end

  @doc "Aggregate stats for metric cards: total scored, per-classification counts, averages."
  def score_summary(lens_id) do
    lens = get_lens!(lens_id)

    scores =
      latest_scores_query(lens_id)
      |> preload(:axis_scores)
      |> Repo.all()

    by_classification =
      scores
      |> Enum.group_by(& &1.classification)
      |> Map.new(fn {label, items} -> {label, length(items)} end)

    axes_sorted = Enum.sort_by(lens.axes, & &1.sort_order)

    axis_averages =
      Enum.map(axes_sorted, fn axis ->
        composites =
          scores
          |> Enum.flat_map(& &1.axis_scores)
          |> Enum.filter(&(&1.axis_id == axis.id))
          |> Enum.map(& &1.composite)

        avg = if composites == [], do: 0.0, else: Enum.sum(composites) / length(composites)

        %{axis_name: axis.name, short_name: axis.short_name, average: Float.round(avg, 1)}
      end)

    %{
      total: length(scores),
      by_classification: by_classification,
      axis_averages: axis_averages
    }
  end

  @doc "Full variable breakdown for a single lens score."
  def score_detail(lens_score_id) do
    score =
      Repo.get!(LensScore, lens_score_id)
      |> Repo.preload(axis_scores: [variable_scores: :variable])

    lens = get_lens!(score.lens_id)
    axes_by_id = Map.new(lens.axes, &{&1.id, &1})

    axes =
      score.axis_scores
      |> Enum.map(fn as ->
        axis = Map.get(axes_by_id, as.axis_id)

        variables =
          Enum.map(as.variable_scores, fn vs ->
            %{
              key: vs.variable.key,
              name: vs.variable.name,
              weight: vs.variable.weight,
              raw_score: vs.raw_score,
              adjusted_score: vs.adjusted_score,
              weighted_score: vs.weighted_score,
              rationale: vs.rationale
            }
          end)

        %{
          axis_name: axis && axis.name,
          short_name: axis && axis.short_name,
          sort_order: axis && axis.sort_order,
          composite: as.composite,
          band: as.band,
          band_label: band_label(axis, as.band),
          variables: variables
        }
      end)
      |> Enum.sort_by(& &1.sort_order)

    %{
      score_id: score.id,
      classification: score.classification,
      scoring_method: score.scoring_method,
      scored_at: score.scored_at,
      version: score.version,
      target: score_target_info(score),
      axes: axes
    }
  end

  @doc "List scores with optional filtering by classification or band."
  def list_scores(lens_id, opts \\ []) do
    query = latest_scores_query(lens_id)

    query =
      case Keyword.get(opts, :classification) do
        nil -> query
        label -> where(query, [s], s.classification == ^label)
      end

    query =
      case Keyword.get(opts, :band) do
        nil ->
          query

        {axis_sort_order, band_value} ->
          lens = get_lens!(lens_id)

          case Enum.find(lens.axes, &(&1.sort_order == axis_sort_order)) do
            nil ->
              query

            axis ->
              from(s in query,
                join: as in LensAxisScore,
                on: as.lens_score_id == s.id and as.axis_id == ^axis.id,
                where: as.band == ^band_value
              )
          end
      end

    query
    |> preload(:axis_scores)
    |> Repo.all()
  end

  @doc "Latest score for a specific target within a lens."
  def get_score(lens_id, target) do
    target_clause = target_where(target)

    from(s in LensScore,
      where: s.lens_id == ^lens_id,
      order_by: [desc: s.version],
      limit: 1
    )
    |> where(^target_clause)
    |> preload(axis_scores: :variable_scores)
    |> Repo.one()
  end

  # --- Query Helpers ---

  defp latest_scores_query(lens_id) do
    # SQLite doesn't support multi-column DISTINCT ON, so use a subquery
    # to find the max version per target, then join back.
    latest_versions =
      from(s in LensScore,
        where: s.lens_id == ^lens_id,
        group_by: [s.role_profile_id, s.skill_id],
        select: %{
          role_profile_id: s.role_profile_id,
          skill_id: s.skill_id,
          max_version: max(s.version)
        }
      )

    from(s in LensScore,
      join: lv in subquery(latest_versions),
      on:
        ((is_nil(s.role_profile_id) and is_nil(lv.role_profile_id)) or
           s.role_profile_id == lv.role_profile_id) and
          ((is_nil(s.skill_id) and is_nil(lv.skill_id)) or s.skill_id == lv.skill_id) and
          s.version == lv.max_version,
      where: s.lens_id == ^lens_id
    )
  end

  defp target_where(%{role_profile_id: id}), do: dynamic([s], s.role_profile_id == ^id)
  defp target_where(%{skill_id: id}), do: dynamic([s], s.skill_id == ^id)

  defp score_target_info(%{role_profile_id: id}) when not is_nil(id),
    do: %{type: :role_profile, id: id}

  defp score_target_info(%{skill_id: id}) when not is_nil(id),
    do: %{type: :skill, id: id}

  defp score_target_info(_), do: nil

  defp band_label(nil, _band), do: nil

  defp band_label(axis, band) do
    Enum.at(axis.band_labels || [], band)
  end

  # --- Signal Publishing ---

  defp maybe_publish_score_update(lens_score, lens, opts) do
    session_id = Keyword.get(opts, :session_id)
    agent_id = Keyword.get(opts, :agent_id)

    if session_id do
      score_data = score_detail(lens_score.id)

      topic = "rho.session.#{session_id}.events.lens_score_update"
      source = if agent_id, do: "/session/#{session_id}/agent/#{agent_id}", else: "/system"

      Rho.Comms.publish(topic, %{lens_id: lens.id, score: score_data}, source: source)
    end
  end
end
