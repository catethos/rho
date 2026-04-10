defmodule RhoFrameworks.Tools.LensTools do
  @moduledoc """
  Lens-related tools extracted from RhoFrameworks.Plugin.

  Uses the `Rho.Tool` DSL to define tools with minimal boilerplate.
  Provides tools for scoring role profiles through lenses, displaying the
  lens dashboard, and switching the active lens.
  """

  use Rho.Tool

  tool :score_role,
       "Score a role profile using a lens (default: ARIA AI Readiness). " <>
         "Triggers LLM-based scoring that evaluates the role across the lens dimensions. " <>
         "Results appear in the Lens Dashboard." do
    param(:role_profile_id, :string,
      required: true,
      doc: "ID of the role profile to score"
    )

    param(:lens_slug, :string, doc: "Lens slug (default: 'aria')")

    run(fn args, ctx ->
      rp_id = args[:role_profile_id]
      slug = args[:lens_slug] || "aria"

      lens =
        RhoFrameworks.Repo.get_by(RhoFrameworks.Frameworks.Lens,
          organization_id: ctx.organization_id,
          slug: slug
        )

      lens =
        case {lens, slug} do
          {nil, "aria"} ->
            {:ok, seeded} = RhoFrameworks.Lenses.seed_aria_lens(ctx.organization_id)
            seeded

          _ ->
            lens
        end

      case lens do
        nil ->
          {:error, "Lens '#{slug}' not found"}

        lens ->
          opts = [session_id: ctx.session_id, agent_id: ctx.agent_id]

          case RhoFrameworks.Lenses.score_via_llm(lens.id, %{role_profile_id: rp_id}, opts) do
            {:ok, score} ->
              {:ok,
               Jason.encode!(%{
                 status: "scored",
                 score_id: score.id,
                 classification: score.classification,
                 message: "Role scored via #{lens.name}"
               })}

            {:error, reason} ->
              {:error, "Scoring failed: #{inspect(reason)}"}
          end
      end
    end)
  end

  tool :show_lens_dashboard,
       "Open the Lens Dashboard panel showing scored roles on the active lens. " <>
         "Loads current scores and publishes them to the dashboard." do
    param(:lens_slug, :string, doc: "Lens slug (default: 'aria')")

    run(fn args, ctx ->
      slug = args[:lens_slug] || "aria"

      lens =
        RhoFrameworks.Repo.get_by(RhoFrameworks.Frameworks.Lens,
          organization_id: ctx.organization_id,
          slug: slug
        )

      lens =
        case {lens, slug} do
          {nil, "aria"} ->
            {:ok, seeded} = RhoFrameworks.Lenses.seed_aria_lens(ctx.organization_id)
            seeded

          _ ->
            lens
        end

      case lens do
        nil ->
          {:error, "Lens '#{slug}' not found"}

        lens ->
          full_lens = RhoFrameworks.Lenses.get_lens!(lens.id)
          scores = RhoFrameworks.Lenses.scores_with_axes(lens.id)
          summary = RhoFrameworks.Lenses.score_summary(lens.id)

          lens_data = serialize_lens(full_lens)

          topic = "rho.session.#{ctx.session_id}.events.lens_dashboard_init"

          Rho.Comms.publish(
            topic,
            %{lens: lens_data, scores: scores, summary: summary},
            source: "/system"
          )

          {:ok,
           Jason.encode!(%{
             status: "dashboard_opened",
             lens: full_lens.name,
             total_scores: summary.total
           })}
      end
    end)
  end

  tool :switch_lens,
       "Switch the active lens in the dashboard to a different one." do
    param(:lens_slug, :string, required: true, doc: "Slug of the lens to switch to")

    run(fn args, ctx ->
      slug = args[:lens_slug]

      lens =
        RhoFrameworks.Repo.get_by(RhoFrameworks.Frameworks.Lens,
          organization_id: ctx.organization_id,
          slug: slug
        )

      case lens do
        nil ->
          {:error, "Lens '#{slug}' not found"}

        lens ->
          full_lens = RhoFrameworks.Lenses.get_lens!(lens.id)
          scores = RhoFrameworks.Lenses.scores_with_axes(lens.id)
          summary = RhoFrameworks.Lenses.score_summary(lens.id)

          lens_data = serialize_lens(full_lens)

          topic = "rho.session.#{ctx.session_id}.events.lens_switch"

          Rho.Comms.publish(
            topic,
            %{lens: lens_data, scores: scores, summary: summary},
            source: "/system"
          )

          {:ok, Jason.encode!(%{status: "switched", lens: full_lens.name})}
      end
    end)
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp serialize_lens(full_lens) do
    %{
      id: full_lens.id,
      name: full_lens.name,
      slug: full_lens.slug,
      description: full_lens.description,
      axes:
        Enum.map(full_lens.axes, fn a ->
          %{
            name: a.name,
            short_name: a.short_name,
            sort_order: a.sort_order,
            band_thresholds: a.band_thresholds,
            band_labels: a.band_labels
          }
        end),
      classifications:
        Enum.map(full_lens.classifications, fn c ->
          %{
            axis_0_band: c.axis_0_band,
            axis_1_band: c.axis_1_band,
            label: c.label,
            color: c.color,
            description: c.description
          }
        end)
    }
  end
end
