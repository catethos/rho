defmodule RhoWeb.CoreComponents do
  @moduledoc """
  Shared UI primitives for the Rho LiveView UI.
  """
  use Phoenix.Component

  attr(:flash, :map, required: true)

  def flash_group(assigns) do
    ~H"""
    <div class="flash-container">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end

  attr(:kind, :atom, required: true)
  attr(:flash, :map, required: true)

  def flash(assigns) do
    msg = Phoenix.Flash.get(assigns.flash, assigns.kind)
    assigns = assign(assigns, :msg, msg)

    ~H"""
    <div :if={@msg} class={"flash flash-#{@kind}"} phx-click="lv:clear-flash" phx-value-key={@kind}>
      <%= @msg %>
    </div>
    """
  end

  attr(:class, :string, default: "")
  attr(:rest, :global)

  slot(:inner_block, required: true)

  def badge(assigns) do
    ~H"""
    <span class={"badge #{@class}"} {@rest}><%= render_slot(@inner_block) %></span>
    """
  end

  attr(:status, :atom, required: true)

  def status_dot(assigns) do
    ~H"""
    <span class={"status-dot status-#{@status}"}></span>
    """
  end

  attr(:class, :string, default: "")
  slot(:inner_block, required: true)

  def page_shell(assigns) do
    ~H"""
    <div class={"page-shell #{@class}"}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:subtitle, :string, default: nil)
  slot(:actions)

  def page_header(assigns) do
    ~H"""
    <div class="page-header">
      <div class="page-header-text">
        <h1 class="page-title"><%= @title %></h1>
        <p :if={@subtitle} class="page-subtitle"><%= @subtitle %></p>
      </div>
      <div :if={@actions != []} class="page-header-actions">
        <%= render_slot(@actions) %>
      </div>
    </div>
    """
  end

  attr(:class, :string, default: "")
  slot(:inner_block, required: true)

  def card(assigns) do
    ~H"""
    <div class={"rho-card #{@class}"}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  slot(:inner_block, required: true)

  def empty_state(assigns) do
    ~H"""
    <div class="empty-state">
      <%= render_slot(@inner_block) %>
    </div>
    """
  end
end
