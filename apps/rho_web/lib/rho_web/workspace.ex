defmodule RhoWeb.Workspace do
  @moduledoc """
  Behaviour for self-contained workspace panels.

  Each workspace declares its metadata (key, label, icon), its projection
  module, its LiveComponent, and how to build the assigns that the component
  expects. SessionLive discovers workspaces via `RhoWeb.Workspace.Registry`
  and renders them generically.
  """

  @type shared_assigns :: %{
          session_id: String.t() | nil,
          agents: map(),
          streaming: boolean(),
          total_cost: float()
        }

  @doc "Unique atom key identifying this workspace (e.g. :data_table)."
  @callback key() :: atom()

  @doc "Human-readable label for tabs and headers."
  @callback label() :: String.t()

  @doc "Icon identifier for the workspace tab."
  @callback icon() :: String.t()

  @doc "Whether this workspace auto-opens as an overlay on signal activity."
  @callback auto_open?() :: boolean()

  @doc "Default surface when opened (:tab or :overlay)."
  @callback default_surface() :: :tab | :overlay

  @doc "Projection module implementing `RhoWeb.Projection`."
  @callback projection() :: module()

  @doc "LiveComponent module for rendering this workspace."
  @callback component() :: module()

  @doc """
  Build the assigns map to pass to the LiveComponent.

  Receives the workspace's projection state and a map of shared session-level
  assigns (session_id, agents, streaming, total_cost). Returns a keyword list
  or map that will be merged into the component's assigns.
  """
  @callback component_assigns(ws_state :: map() | nil, shared :: shared_assigns()) :: map()

  @doc """
  Handle a domain-specific message for this workspace.

  Called by SessionLive when it receives a message tagged for a specific workspace.
  Returns `{:noreply, new_ws_state}` to update the workspace's projection state,
  or `:skip` to indicate the message was not handled.

  The `context` map contains `:session_id` and `:socket` for cases that need
  session-level access (e.g. synchronous reads).
  """
  @callback handle_info(message :: term(), ws_state :: map() | nil, context :: map()) ::
              {:noreply, map()} | :skip

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour RhoWeb.Workspace
      @before_compile RhoWeb.Workspace
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    unless Module.defines?(env.module, {:component_assigns, 2}) do
      quote do
        @impl RhoWeb.Workspace
        def component_assigns(ws_state, _shared), do: %{state: ws_state}
      end
    end

    unless Module.defines?(env.module, {:handle_info, 3}) do
      quote do
        @impl RhoWeb.Workspace
        def handle_info(_message, _ws_state, _context), do: :skip
      end
    end
  end
end
