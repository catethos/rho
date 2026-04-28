defmodule RhoWeb.Components.StepChat do
  @moduledoc """
  Per-step "Ask" escape hatch (Phase 8 of the swappable-decision-policy
  plan, §3.4).

  Stateless function component. Renders a small inline chat scoped to
  the current wizard step's UseCase: a textarea + submit, an optional
  pending-question callout from the agent's `clarify` tool, and a
  minimal streaming/tool-event log when the step-chat agent is running.

  No persisted history — each turn is independent. If the user wants a
  multi-turn conversation, they re-submit.

  ## Attrs

    * `:node` — the current step node map (uses `:label` for the prompt copy).
    * `:agent_id` — running step-chat agent's id, or `nil` when idle.
    * `:streaming_text` — partial assistant text for the current turn.
    * `:tool_events` — list of `%{phase, name, status, output}` events.
    * `:pending_question` — `nil`, or a string emitted by the agent's
      `clarify` tool. When present, renders above the textarea so the
      user knows the agent is asking back.
    * `:disabled?` — true while a fan-out / generation step is mid-flight.
      Disables submission so two BAML calls don't clobber the same table.

  ## Events emitted

    * `phx-submit="step_chat_submit"` — payload `%{"message" => binary}`.
  """
  use Phoenix.Component

  attr(:node, :map, required: true)
  attr(:agent_id, :string, default: nil)
  attr(:streaming_text, :string, default: "")
  attr(:tool_events, :list, default: [])
  attr(:pending_question, :string, default: nil)
  attr(:disabled?, :boolean, default: false)

  def step_chat(assigns) do
    assigns = assign(assigns, :running?, is_binary(assigns.agent_id))

    ~H"""
    <section class="step-chat" aria-label={"Ask about " <> @node.label}>
      <header class="step-chat-header">
        <span class="step-chat-title">Ask about this step</span>
        <span :if={@running?} class="step-chat-status">
          <span class="flow-spinner step-chat-spinner"></span>
          <span>working…</span>
        </span>
      </header>

      <div :if={@pending_question} class="step-chat-pending" role="status">
        <span class="step-chat-pending-label">The agent asks:</span>
        <p class="step-chat-pending-question"><%= @pending_question %></p>
      </div>

      <form phx-submit="step_chat_submit" class="step-chat-form">
        <textarea
          name="message"
          class="step-chat-textarea"
          rows="2"
          placeholder={placeholder(@node, @pending_question)}
          disabled={@disabled? or @running?}
          required
        ></textarea>
        <button
          type="submit"
          class="btn-secondary step-chat-submit"
          disabled={@disabled? or @running?}
        >
          <%= if @running?, do: "Sending…", else: "Send" %>
        </button>
      </form>

      <div :if={@streaming_text != ""} class="step-chat-stream">
        <%= @streaming_text %>
      </div>

      <ul :if={@tool_events != []} class="step-chat-tool-log" role="list">
        <li :for={event <- @tool_events} class={"step-chat-tool flow-tool-#{event.phase}"}>
          <span class="flow-tool-name"><%= event.name %></span>
          <span :if={event.phase == :start} class="flow-tool-phase">calling…</span>
          <span :if={event.phase == :result} class={"flow-tool-phase flow-tool-#{event.status}"}>
            <%= event.status %>
          </span>
        </li>
      </ul>
    </section>
    """
  end

  defp placeholder(_node, q) when is_binary(q) and q != "", do: "Answer the agent…"

  defp placeholder(node, _) do
    "e.g. \"regenerate with 8 skills\" or \"drop the security category\" — about: #{node.label}"
  end
end
