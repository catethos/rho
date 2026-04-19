defmodule RhoWeb.FlowComponents do
  @moduledoc """
  Function components for step-by-step wizard flows.
  """
  use Phoenix.Component

  # -------------------------------------------------------------------
  # Step indicator
  # -------------------------------------------------------------------

  attr(:steps, :list, required: true)
  attr(:current_step, :atom, required: true)
  attr(:completed_steps, :list, default: [])

  def step_indicator(assigns) do
    ~H"""
    <div class="flow-stepper">
      <%= for {step, idx} <- Enum.with_index(@steps) do %>
        <div class={step_class(step.id, @current_step, @completed_steps)}>
          <div class="flow-step-number">
            <%= if step.id in @completed_steps do %>
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3">
                <polyline points="20 6 9 17 4 12" />
              </svg>
            <% else %>
              <%= idx + 1 %>
            <% end %>
          </div>
          <span class="flow-step-label"><%= step.label %></span>
        </div>
        <div :if={idx < length(@steps) - 1} class="flow-step-connector"></div>
      <% end %>
    </div>
    """
  end

  defp step_class(id, current, completed) do
    cond do
      id == current -> "flow-step flow-step-active"
      id in completed -> "flow-step flow-step-completed"
      true -> "flow-step flow-step-pending"
    end
  end

  # -------------------------------------------------------------------
  # Form step
  # -------------------------------------------------------------------

  attr(:fields, :list, required: true)
  attr(:form, :map, required: true)
  attr(:step_id, :atom, required: true)

  def form_step(assigns) do
    ~H"""
    <form phx-submit="submit_form" class="flow-form">
      <input type="hidden" name="step_id" value={@step_id} />
      <%= for field <- @fields do %>
        <div class="flow-field">
          <label class="flow-label" for={field.name}>
            <%= field.label %>
            <span :if={field[:required]} class="flow-required">*</span>
          </label>
          <.form_field field={field} form={@form} />
        </div>
      <% end %>
      <button type="submit" class="btn-primary flow-submit">Continue</button>
    </form>
    """
  end

  attr(:field, :map, required: true)
  attr(:form, :map, required: true)

  defp form_field(%{field: %{type: :textarea}} = assigns) do
    ~H"""
    <textarea
      id={@field.name}
      name={@field.name}
      class="flow-input flow-textarea"
      required={@field[:required]}
      rows="4"
    ><%= @form[@field.name] || "" %></textarea>
    """
  end

  defp form_field(%{field: %{type: :range}, form: form} = assigns) do
    field = assigns.field

    assigns =
      assign(assigns, :value, form[field.name] || to_string(field[:default] || field[:min] || 8))

    ~H"""
    <div class="flow-range-wrap">
      <input
        type="range"
        id={@field.name}
        name={@field.name}
        class="flow-range"
        min={@field[:min] || 1}
        max={@field[:max] || 100}
        value={@value}
        oninput={"document.getElementById('#{@field.name}_val').textContent = this.value"}
      />
      <span class="flow-range-value" id={"#{@field.name}_val"}><%= @value %></span>
    </div>
    """
  end

  defp form_field(%{field: %{type: :select}} = assigns) do
    field = assigns.field
    assigns = assign(assigns, :value, assigns.form[field.name] || field[:default] || "")

    ~H"""
    <select id={@field.name} name={@field.name} class="flow-input flow-select">
      <%= for {label, val} <- @field[:options] || [] do %>
        <option value={val} selected={val == @value}><%= label %></option>
      <% end %>
    </select>
    """
  end

  defp form_field(%{field: %{type: :tags}} = assigns) do
    ~H"""
    <input
      type="text"
      id={@field.name}
      name={@field.name}
      class="flow-input"
      placeholder={@field[:placeholder] || ""}
      value={@form[@field.name] || ""}
    />
    """
  end

  defp form_field(assigns) do
    ~H"""
    <input
      type="text"
      id={@field.name}
      name={@field.name}
      class="flow-input"
      required={@field[:required]}
      placeholder={@field[:placeholder] || ""}
      value={@form[@field.name] || ""}
    />
    """
  end

  # -------------------------------------------------------------------
  # Action step
  # -------------------------------------------------------------------

  attr(:step_status, :atom, required: true)
  attr(:step_label, :string, required: true)
  attr(:step_error, :string, default: nil)
  attr(:streaming_text, :string, default: "")
  attr(:tool_events, :list, default: [])

  def action_step(assigns) do
    ~H"""
    <div class="flow-action-status">
      <div :if={@step_status == :running} class="flow-action-running">
        <div class="flow-action-header">
          <div class="flow-spinner"></div>
          <span><%= @step_label %>...</span>
        </div>
        <div :if={@tool_events != []} class="flow-tool-log">
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
        <div :if={@streaming_text != ""} class="flow-stream-output">
          <pre class="flow-stream-text"><%= @streaming_text %></pre>
        </div>
      </div>
      <div :if={@step_status == :completed} class="flow-action-complete">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="var(--green)" stroke-width="2.5">
          <circle cx="12" cy="12" r="10" />
          <polyline points="16 9 10.5 14.5 8 12" />
        </svg>
        <span><%= @step_label %> — Done</span>
        <button phx-click="continue" class="btn-primary flow-submit">Continue</button>
      </div>
      <div :if={@step_status == :failed} class="flow-action-error">
        <span class="flow-error-icon">!</span>
        <span>Failed: <%= @step_error || "Unknown error" %></span>
        <button phx-click="retry_step" class="btn-secondary">Retry</button>
      </div>
    </div>
    """
  end

  # -------------------------------------------------------------------
  # Table review step
  # -------------------------------------------------------------------

  attr(:dt_snapshot, :list, default: [])
  attr(:dt_schema, :map, default: nil)
  attr(:session_id, :string, required: true)
  attr(:table_name, :string, required: true)

  def table_review_step(assigns) do
    ~H"""
    <div class="flow-table-review">
      <div :if={@dt_schema && @dt_snapshot != []} class="flow-table-wrap">
        <.live_component
          module={RhoWeb.DataTableComponent}
          id="flow-data-table"
          rows={@dt_snapshot}
          schema={@dt_schema}
          session_id={@session_id}
          table_name={@table_name}
          class=""
          error={nil}
          tables={[]}
          table_order={[]}
          active_table={@table_name}
          streaming={false}
          total_cost={0.0}
        />
      </div>
      <div :if={!@dt_schema || @dt_snapshot == []} class="flow-table-empty">
        No table data available yet.
      </div>
      <button :if={@dt_snapshot != []} phx-click="continue" class="btn-primary flow-submit">
        Looks Good — Continue
      </button>
    </div>
    """
  end

  # -------------------------------------------------------------------
  # Fan-out step
  # -------------------------------------------------------------------

  attr(:workers, :list, default: [])
  attr(:step_status, :atom, required: true)

  def fan_out_step(assigns) do
    ~H"""
    <div class="flow-fan-out">
      <div :if={@step_status == :idle} class="flow-fan-out-start">
        <button phx-click="start_fan_out" class="btn-primary flow-submit">
          Start Generation
        </button>
      </div>
      <div :if={@step_status in [:running, :completed]} class="flow-worker-grid">
        <%= for w <- @workers do %>
          <.progress_card worker={w} />
        <% end %>
      </div>
      <div :if={@step_status == :completed} class="flow-fan-out-done">
        <button phx-click="continue" class="btn-primary flow-submit">Continue</button>
      </div>
    </div>
    """
  end

  attr(:worker, :map, required: true)

  defp progress_card(assigns) do
    ~H"""
    <div class={"flow-progress-card flow-progress-#{@worker.status}"}>
      <div class="flow-progress-header">
        <span class="flow-progress-category"><%= @worker.category %></span>
        <span class="flow-progress-count"><%= @worker.count %> skills</span>
      </div>
      <div class="flow-progress-status">
        <%= case @worker.status do %>
          <% :pending -> %>
            <span class="flow-status-dot flow-status-pending"></span> Queued
          <% :running -> %>
            <div class="flow-spinner-sm"></div> Running
          <% :completed -> %>
            <span class="flow-status-dot flow-status-completed"></span> Done
          <% :failed -> %>
            <span class="flow-status-dot flow-status-failed"></span> Failed
          <% _ -> %>
            <span class="flow-status-dot flow-status-pending"></span> Unknown
        <% end %>
      </div>
    </div>
    """
  end

  # -------------------------------------------------------------------
  # Select step
  # -------------------------------------------------------------------

  attr(:items, :list, default: [])
  attr(:selected, :list, default: [])
  attr(:display_fields, :map, required: true)
  attr(:step_status, :atom, required: true)
  attr(:skippable, :boolean, default: true)

  def select_step(assigns) do
    ~H"""
    <div class="flow-select-step">
      <div :if={@step_status == :loading} class="flow-select-loading">
        <div class="flow-spinner"></div>
        <span>Finding similar roles...</span>
      </div>
      <div :if={@step_status == :idle && @items != []} class="flow-select-cards">
        <p class="flow-select-hint">
          Select roles to draw skills from, or skip to generate from scratch.
        </p>
        <div class="flow-select-grid">
          <%= for item <- @items do %>
            <.select_card
              item={item}
              display_fields={@display_fields}
              selected={item_id(item) in @selected}
            />
          <% end %>
        </div>
        <div class="flow-select-actions">
          <button phx-click="confirm_selection" class="btn-primary flow-submit">
            Continue with <%= length(@selected) %> selected
          </button>
          <button :if={@skippable} phx-click="skip_select" class="btn-secondary flow-skip">
            Skip
          </button>
        </div>
      </div>
      <div :if={@step_status == :idle && @items == []} class="flow-select-empty">
        <span>No matches found.</span>
      </div>
    </div>
    """
  end

  attr(:item, :map, required: true)
  attr(:display_fields, :map, required: true)
  attr(:selected, :boolean, default: false)

  defp select_card(assigns) do
    ~H"""
    <div
      class={"flow-select-card #{if @selected, do: "flow-select-card-active", else: ""}"}
      phx-click="toggle_selection"
      phx-value-id={item_id(@item)}
    >
      <div class="flow-select-card-check">
        <div class={"flow-checkbox #{if @selected, do: "flow-checkbox-checked"}"}>
          <svg
            :if={@selected}
            width="12"
            height="12"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="3"
          >
            <polyline points="20 6 9 17 4 12" />
          </svg>
        </div>
      </div>
      <div class="flow-select-card-body">
        <span class="flow-select-card-title">
          <%= Map.get(@item, @display_fields[:title], "") %>
        </span>
        <span :if={@display_fields[:subtitle]} class="flow-select-card-subtitle">
          <%= Map.get(@item, @display_fields[:subtitle], "") %>
        </span>
        <span :if={@display_fields[:detail]} class="flow-select-card-detail">
          <%= format_detail(@item, @display_fields[:detail]) %>
        </span>
      </div>
    </div>
    """
  end

  defp item_id(item) do
    to_string(item[:id] || item["id"] || :erlang.phash2(item))
  end

  defp format_detail(item, field) do
    case Map.get(item, field) do
      n when is_integer(n) -> "#{n} skills"
      v -> to_string(v || "")
    end
  end

  # -------------------------------------------------------------------
  # Manual action (confirm) step
  # -------------------------------------------------------------------

  attr(:message, :string, required: true)
  attr(:step_label, :string, required: true)

  def confirm_step(assigns) do
    ~H"""
    <div class="flow-confirm">
      <p class="flow-confirm-message"><%= @message %></p>
      <button phx-click="confirm_manual" class="btn-primary flow-submit">
        <%= @step_label %>
      </button>
    </div>
    """
  end
end
