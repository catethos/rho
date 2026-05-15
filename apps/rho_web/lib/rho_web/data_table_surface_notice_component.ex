defmodule RhoWeb.DataTableSurfaceNoticeComponent do
  @moduledoc false

  use Phoenix.Component

  alias RhoWeb.DataTable.Artifacts

  attr(:artifact, :any, default: nil)
  attr(:selected_count, :integer, default: 0)
  attr(:surface, :atom, default: :artifact_summary)

  def notice(assigns) do
    assigns = assign(assigns, :metrics, Artifacts.surface_metrics(assigns.artifact))

    ~H"""
    <div :if={Artifacts.surface_notice?(@surface)} class={"dt-surface-notice dt-surface-#{@surface}"}>
      <%= case @surface do %>
        <% :linked_artifacts -> %>
          <div class="dt-surface-copy">
            <span class="dt-surface-label">Linked artifacts</span>
            <strong>Review the related workbench artifacts together</strong>
            <span><%= Artifacts.linked_summary(@artifact) %></span>
          </div>
        <% :role_candidate_picker -> %>
          <div class="dt-surface-copy">
            <span class="dt-surface-label">Picker</span>
            <strong>Choose source roles for the next framework</strong>
            <span><%= @metrics[:candidates] || 0 %> candidates across <%= @metrics[:queries] || 0 %> queries</span>
          </div>
          <div class="dt-surface-count">
            <strong><%= @selected_count %></strong>
            <span>selected</span>
          </div>
        <% :conflict_review -> %>
          <div class="dt-surface-copy">
            <span class="dt-surface-label">Decision queue</span>
            <strong>Resolve combine conflicts before creating the merged library</strong>
            <span><%= @metrics[:unresolved] || 0 %> unresolved, <%= @metrics[:resolved] || 0 %> resolved</span>
          </div>
          <div class={"dt-surface-state #{if (@metrics[:unresolved] || 0) == 0, do: "is-ready", else: "needs-work"}"}>
            <%= if (@metrics[:unresolved] || 0) == 0, do: "Ready to merge", else: "Needs decisions" %>
          </div>
        <% :dedup_review -> %>
          <div class="dt-surface-copy">
            <span class="dt-surface-label">Review queue</span>
            <strong>Decide which duplicate candidates should be merged or kept</strong>
            <span><%= @metrics[:unresolved] || 0 %> unresolved, <%= @metrics[:resolved] || 0 %> resolved</span>
          </div>
          <div class={"dt-surface-state #{if (@metrics[:unresolved] || 0) == 0, do: "is-ready", else: "needs-work"}"}>
            <%= if (@metrics[:unresolved] || 0) == 0, do: "Ready to apply", else: "Needs review" %>
          </div>
        <% :gap_review -> %>
          <div class="dt-surface-copy">
            <span class="dt-surface-label">Recommendations</span>
            <strong>Review proposed changes before applying them to the artifact</strong>
            <span>
              <%= @metrics[:recommendations] || @metrics[:rows] || 0 %> findings,
              <%= @metrics[:high_priority] || 0 %> high priority,
              <%= @metrics[:unresolved] || 0 %> unresolved
            </span>
          </div>
          <div class={"dt-surface-state #{if (@metrics[:unresolved] || 0) == 0, do: "is-ready", else: "needs-work"}"}>
            <%= if (@metrics[:unresolved] || 0) == 0, do: "Ready to apply", else: "Needs review" %>
          </div>
        <% _ -> %>
      <% end %>
    </div>
    """
  end
end
