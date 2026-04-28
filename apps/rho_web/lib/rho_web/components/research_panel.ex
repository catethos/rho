defmodule RhoWeb.Components.ResearchPanel do
  @moduledoc """
  Streaming findings panel for `:agent_loop` flow nodes whose UseCase
  writes rows into a named DataTable (e.g. `RhoFrameworks.UseCases.ResearchDomain`
  → `"research_notes"`).

  Stateless function component. Inputs:

    * `:rows` — pre-fetched row list from the named table (the parent LV
      reloads on `:data_table` invalidation events; this component just
      renders).
    * `:status` — `:running | :awaiting_user | :completed | :failed | :idle`.
      `:running` shows the spinner + "Continue early →" button.
      `:awaiting_user` (worker finished naturally) drops the spinner and
      shows "Continue →" so the user gets a chance to pin/unpin and add
      notes before the wizard advances.
    * `:error` — string, optional.
    * `:tool_events` / `:show_theater` — Phase 5: when `show_theater` is
      true, render the raw tool-call log alongside the findings. Findings
      themselves render in every mode.

  Pin/unpin toggles post `phx-click="research_toggle_pin"` with `phx-value-id`
  set to the row id. Add-note posts `phx-submit="research_add_note"` with
  a `note` text field. Continue posts `phx-click="research_continue"`.
  """
  use Phoenix.Component

  attr(:rows, :list, required: true)
  attr(:status, :atom, default: :running)
  attr(:error, :string, default: nil)
  attr(:tool_events, :list, default: [])
  attr(:show_theater, :boolean, default: false)

  def research_panel(assigns) do
    assigns =
      assigns
      |> assign(:pinned_count, Enum.count(assigns.rows, &pinned?/1))
      |> assign(:total_count, length(assigns.rows))

    ~H"""
    <div class="research-panel">
      <div class="research-panel-header">
        <div class="research-panel-title">
          <div :if={@status == :running} class="flow-spinner"></div>
          <span :if={@status == :running}>Researching domain</span>
          <span :if={@status == :awaiting_user}>Research complete — review and continue</span>
          <span :if={@status not in [:running, :awaiting_user]}>Researching domain</span>
          <span class="research-panel-counts">
            <%= @pinned_count %> pinned / <%= @total_count %> total
          </span>
        </div>
        <button
          :if={@status in [:running, :awaiting_user]}
          type="button"
          phx-click="research_continue"
          class="btn-secondary research-continue"
        >
          <%= if @status == :running, do: "Continue early →", else: "Continue →" %>
        </button>
      </div>

      <div :if={@error} class="research-error"><%= @error %></div>

      <div :if={@show_theater and @tool_events != []} class="research-tool-log flow-tool-log">
        <%= for event <- @tool_events do %>
          <div class={"flow-tool-event flow-tool-#{event.phase}"}>
            <span class="flow-tool-name"><%= event.name %></span>
            <span :if={event.phase == :start} class="flow-tool-phase">calling...</span>
            <span :if={event.phase == :result} class={"flow-tool-phase flow-tool-#{event.status}"}>
              <%= event.status %>
            </span>
          </div>
        <% end %>
      </div>

      <ul class="research-findings" role="list">
        <li :for={row <- @rows} class={"research-finding " <> finding_class(row)}>
          <button
            type="button"
            class={"research-pin " <> pin_class(row)}
            phx-click="research_toggle_pin"
            phx-value-id={row_id(row)}
            aria-label={if pinned?(row), do: "Unpin finding", else: "Pin finding"}
          >
            <%= if pinned?(row), do: "★", else: "☆" %>
          </button>
          <div class="research-finding-body">
            <p class="research-fact"><%= field(row, :fact) %></p>
            <div class="research-meta">
              <span :if={field(row, :tag) not in [nil, ""]} class="research-tag">
                <%= field(row, :tag) %>
              </span>
              <span class="research-source"><%= field(row, :source) %></span>
            </div>
          </div>
        </li>
        <li :if={@rows == []} class="research-empty">
          <span :if={@status == :running}>Waiting for findings…</span>
          <span :if={@status == :awaiting_user}>
            Research finished without findings — add your own notes below or continue.
          </span>
          <span :if={@status not in [:running, :awaiting_user]}>No findings yet.</span>
        </li>
      </ul>

      <form phx-submit="research_add_note" class="research-add-note">
        <input
          type="text"
          name="note"
          class="flow-input"
          placeholder="Add your own finding…"
          required
        />
        <button type="submit" class="btn-secondary">Add note</button>
      </form>
    </div>
    """
  end

  # ──────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────

  defp pinned?(row), do: truthy?(field(row, :pinned))

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp pin_class(row), do: if(pinned?(row), do: "research-pin-on", else: "research-pin-off")
  defp finding_class(row), do: if(pinned?(row), do: "research-finding-pinned", else: "")

  defp row_id(row), do: field(row, :id) || field(row, :_id) || ""

  defp field(row, key) when is_map(row) do
    Map.get(row, key) || Map.get(row, Atom.to_string(key))
  end
end
