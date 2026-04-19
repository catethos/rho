defmodule RhoFrameworks.Flows.CreateFramework do
  @moduledoc """
  Flow for creating a skill framework from scratch.

  Steps: intake (form) → similar_roles (select) → generate (action) →
  review (table_review) → confirm (manual action) → proficiency (fan_out) →
  save (action).
  """

  @behaviour RhoFrameworks.Flow

  alias RhoFrameworks.Library.{Editor, Proficiency}
  alias RhoFrameworks.Roles
  alias RhoFrameworks.SkeletonGenerator

  @impl true
  def id, do: "create-framework"

  @impl true
  def label, do: "Create Skill Framework"

  @impl true
  def steps do
    [
      %{
        id: :intake,
        label: "Define Framework",
        type: :form,
        run: nil,
        config: %{
          fields: [
            %{name: :name, label: "Framework Name", type: :text, required: true},
            %{name: :description, label: "Description", type: :textarea, required: true},
            %{
              name: :domain,
              label: "Domain",
              type: :text,
              placeholder: "e.g. Software Engineering"
            },
            %{
              name: :target_roles,
              label: "Target Roles",
              type: :tags,
              placeholder: "e.g. Backend Engineer, Tech Lead"
            },
            %{
              name: :skill_count,
              label: "Skill Count",
              type: :range,
              min: 8,
              max: 20,
              default: 12
            },
            %{
              name: :levels,
              label: "Proficiency Levels",
              type: :select,
              default: "5",
              options: [{"3 levels", "3"}, {"4 levels", "4"}, {"5 levels", "5"}]
            }
          ]
        }
      },
      %{
        id: :similar_roles,
        label: "Similar Roles",
        type: :select,
        run: nil,
        config: %{
          load: {__MODULE__, :load_similar_roles, []},
          display_fields: %{title: :name, subtitle: :role_family, detail: :skill_count},
          skippable: true
        }
      },
      %{
        id: :generate,
        label: "Generate Skills",
        type: :action,
        run: {SkeletonGenerator, :generate, []},
        config: %{}
      },
      %{
        id: :review,
        label: "Review Skills",
        type: :table_review,
        run: nil,
        config: %{}
      },
      %{
        id: :confirm,
        label: "Confirm",
        type: :action,
        run: nil,
        config: %{
          manual: true,
          message: "Review complete. Generate proficiency levels for these skills?"
        }
      },
      %{
        id: :proficiency,
        label: "Generate Proficiency Levels",
        type: :fan_out,
        run: {Proficiency, :start_fanout_from_table, []},
        config: %{}
      },
      %{
        id: :save,
        label: "Save to Library",
        type: :action,
        run: {Editor, :save_table, []},
        config: %{}
      }
    ]
  end

  @doc """
  Load similar roles based on intake data. Returns `{:ok, roles}` or
  `{:skip, reason}` if no matches found.
  """
  def load_similar_roles(params, runtime) do
    query = build_similarity_query(params)

    case Roles.find_similar_roles(runtime.organization_id, query, limit: 5) do
      [] -> {:skip, "No similar roles found — continuing to generation."}
      roles -> {:ok, roles}
    end
  end

  defp build_similarity_query(params) do
    parts =
      [params[:name], params[:domain], params[:target_roles]]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))

    Enum.join(parts, " ")
  end
end
