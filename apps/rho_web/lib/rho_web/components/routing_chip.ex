defmodule RhoWeb.Components.RoutingChip do
  @moduledoc """
  Phase 5 — surfaces the BAML router's choice on `:auto` nodes with a
  one-line "why" and an Override pill.

  Stateless function component. Inputs:

    * `:decision` — `%{node_id, target, reason, confidence, allowed}` set
      by `RhoWeb.FlowLive.advance_step/1` after the Hybrid policy returns.
      `nil` → chip does not render.
    * `:expanded?` — when true, render the row of allowed edges as
      override buttons.
    * `:current_node_id` — the runner's current node id; used so the
      parent can hide the chip after the user has advanced past the
      destination ("only-while-fresh" — see §3.3).

  Override scope (v1, per swappable-decision-policy-plan §3.3):
    The chip is interactive only while the runner is still at the
    just-decided destination (`current_node_id == decision.target`). The
    parent LV is responsible for cancelling any in-flight worker and
    walking the runner back to `decision.node_id` before re-running
    `choose_next`. Once the user has advanced past the destination, the
    parent should clear `:last_decision` and the chip disappears.

  Events posted:

    * `phx-click="routing_chip_toggle"` (no value) — flips the expanded view.
    * `phx-click="override_edge"` with `phx-value-node` (the auto node id)
      and `phx-value-edge` (the edge target id, both strings).
  """
  use Phoenix.Component

  attr(:decision, :map, default: nil)
  attr(:expanded?, :boolean, default: false)
  attr(:current_node_id, :atom, required: true)

  def routing_chip(assigns) do
    decision = assigns.decision

    cond do
      is_nil(decision) ->
        ~H""

      decision.target != assigns.current_node_id ->
        # Stale — runner has moved past the auto-decided destination.
        ~H""

      true ->
        assigns =
          assigns
          |> assign(:target_label, edge_label(decision.allowed, decision.target))
          |> assign(:confidence_class, confidence_class(decision.confidence))

        ~H"""
        <div class="routing-chip">
          <div class="routing-chip-row">
            <span class={"routing-chip-dot " <> @confidence_class} aria-hidden="true"></span>
            <span class="routing-chip-headline">
              Next: <strong><%= @target_label %></strong>
              <span :if={@decision.confidence} class="routing-chip-confidence">
                · <%= confidence_pct(@decision.confidence) %>% confident
              </span>
            </span>
            <button
              type="button"
              class="routing-chip-override"
              phx-click="routing_chip_toggle"
              aria-expanded={if @expanded?, do: "true", else: "false"}
            >
              <%= if @expanded?, do: "Cancel", else: "Override" %>
            </button>
          </div>
          <p :if={@decision.reason} class="routing-chip-reason">
            ↳ <%= @decision.reason %>
          </p>
          <div :if={@expanded?} class="routing-chip-options">
            <%= for edge <- @decision.allowed do %>
              <button
                type="button"
                class={"routing-chip-option " <> active_class(edge, @decision)}
                phx-click="override_edge"
                phx-value-node={Atom.to_string(@decision.node_id)}
                phx-value-edge={Atom.to_string(edge.to)}
                disabled={edge.to == @decision.target}
              >
                <%= Map.get(edge, :label) || Atom.to_string(edge.to) %>
              </button>
            <% end %>
          </div>
        </div>
        """
    end
  end

  defp edge_label(allowed, target) when is_list(allowed) do
    case Enum.find(allowed, fn e -> e.to == target end) do
      %{label: label} when is_binary(label) and label != "" -> label
      _ -> Atom.to_string(target)
    end
  end

  defp edge_label(_allowed, target), do: Atom.to_string(target)

  defp confidence_class(nil), do: "routing-chip-dot-unknown"
  defp confidence_class(c) when is_number(c) and c >= 0.85, do: "routing-chip-dot-high"
  defp confidence_class(c) when is_number(c) and c >= 0.6, do: "routing-chip-dot-mid"
  defp confidence_class(_), do: "routing-chip-dot-low"

  defp confidence_pct(c) when is_number(c), do: round(c * 100)
  defp confidence_pct(_), do: 0

  defp active_class(edge, decision) do
    if edge.to == decision.target, do: "routing-chip-option-active", else: ""
  end
end
