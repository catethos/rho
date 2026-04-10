defmodule RhoFrameworks.Plugin do
  @moduledoc """
  Plugin that provides library-centric, role-centric, and lens-centric tools
  for the Prism skill assessment domain.

  Aggregates tools from domain-specific modules:
  - `RhoFrameworks.Tools.LibraryTools` — skill library CRUD, forking, dedup
  - `RhoFrameworks.Tools.RoleTools` — role profiles, gap analysis, career ladders
  - `RhoFrameworks.Tools.LensTools` — scoring, dashboard, lens switching
  - `RhoFrameworks.Tools.SharedTools` — cross-domain utilities
  """

  @behaviour Rho.Plugin

  alias RhoFrameworks.Tools.{LibraryTools, RoleTools, LensTools, SharedTools}

  @impl Rho.Plugin
  def tools(_mount_opts, %{organization_id: nil}), do: []
  def tools(_mount_opts, %{organization_id: _} = context), do: build_tools(context)
  def tools(_mount_opts, _context), do: []

  @impl Rho.Plugin
  def prompt_sections(_mount_opts, _context) do
    [
      """
      # Skill Library & Role Profile System

      You work with two modes:

      ## Library Mode (editing the skill catalog)
      Columns: category, cluster, skill_name, skill_description, level, level_name, level_description
      One row per skill×level. Use `save_to_library` to persist.

      ## Role Profile Mode (selecting skills + setting requirements)
      Columns: category, cluster, skill_name, required_level, required
      One row per skill. Use `save_role_profile` to persist.

      ## Workflow Rules
      - ALWAYS call `browse_library` before generating skills for a new role — reuse existing skill names
      - Call `find_similar_roles` before creating a new role — offer to clone from existing roles
      - When the user says "we use SFIA" or similar, use `load_template` first, then `fork_library`
      - Standard (immutable) libraries cannot be edited — fork them first
      - Draft skills (created via save_role_profile) need proficiency descriptions later

      ## Tool Reference — Libraries
      - `list_libraries` — list all org libraries
      - `create_library` — create a new mutable library
      - `browse_library` — list skills in a library (with filters)
      - `save_to_library` — save current data table rows to a library (status: published)
      - `load_template` — load a standard framework (e.g. SFIA v8) as immutable library
      - `load_library` — load a library into the data table as flat skill×level rows for editing
      - `fork_library` — fork an immutable library into a mutable working copy
      - `diff_library` — diff a fork against its source
      - `search_skills_cross_library` — search skills across all org libraries
      - `combine_libraries` — create a new library by copying skills from multiple sources (non-destructive)
      - `find_duplicates` — find duplicate skill pairs (supports deep LLM-based semantic matching)
      - `merge_skills` — absorb one skill into another, repoint all role references
      - `dismiss_duplicate` — mark two skills as intentionally different
      - `consolidate_library` — report: duplicates → drafts → orphans

      ## Tool Reference — Roles
      - `save_role_profile` — save data table rows as a role profile (auto-upserts skills as drafts)
      - `load_role_profile` — load a role profile into data table
      - `list_role_profiles` — list all role profiles
      - `find_similar_roles` — find roles by name/family similarity
      - `clone_role_skills` — copy skill selection from existing role(s) as starting template
      - `show_career_ladder` — show role progression for a role family
      - `gap_analysis` — individual or team gap analysis against a role profile

      ## Tool Reference — Data Table (from DataTable plugin)
      - `get_table_summary` / `get_table` / `add_rows` / `update_cells` / `delete_rows` / `replace_all`

      ## Tool Reference — Lenses
      - `score_role` — trigger LLM scoring of a role profile through a lens (default: ARIA)
      - `show_lens_dashboard` — open the lens dashboard panel with current scores
      - `switch_lens` — change the active lens in the dashboard

      ## Unchanged
      - `add_proficiency_levels` — batch-add proficiency levels (token-efficient)
      """
    ]
  end

  defp build_tools(context) do
    LibraryTools.__tools__(context) ++
      RoleTools.__tools__(context) ++
      LensTools.__tools__(context) ++
      SharedTools.__tools__(context)
  end
end
