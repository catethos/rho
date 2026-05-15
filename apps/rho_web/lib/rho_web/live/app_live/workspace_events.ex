defmodule RhoWeb.AppLive.WorkspaceEvents do
  @moduledoc """
  Event handlers for AppLive workspace shell interactions.

  This module owns chrome-level workspace operations while `AppLive` keeps the
  shared session state and rendering surface.
  """

  import Phoenix.Component, only: [assign: 3]

  alias RhoWeb.AppLive
  alias RhoWeb.AppLive.ChatEvents
  alias RhoWeb.AppLive.DataTableEvents
  alias RhoWeb.Session.Shell
  alias RhoWeb.Workspace.Registry, as: WorkspaceRegistry

  def handle_event("switch_workspace", %{"workspace" => ws}, socket) do
    key = safe_to_existing_atom(ws)

    if is_atom(key) and map_key?(socket.assigns.workspaces, key) do
      socket =
        socket
        |> assign(:active_workspace_id, key)
        |> assign(:shell, Shell.clear_activity(socket.assigns.shell, key))

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("collapse_workspace", %{"workspace" => ws}, socket) do
    key = safe_to_existing_atom(ws)

    if is_atom(key) and map_key?(socket.assigns.shell.workspaces, key) do
      chrome = get_in(socket.assigns.shell, [:workspaces, key])
      shell = Shell.set_collapsed(socket.assigns.shell, key, !chrome.collapsed)
      {:noreply, assign(socket, :shell, shell)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("pin_workspace", %{"workspace" => ws}, socket) do
    key = safe_to_existing_atom(ws)

    if is_atom(key) do
      ws_mod = WorkspaceRegistry.get(key)
      shell = socket.assigns.shell |> Shell.pin_workspace(key) |> Shell.show_chat()

      workspaces =
        if ws_mod && !map_key?(socket.assigns.workspaces, key) do
          Map.put(socket.assigns.workspaces, key, ws_mod)
        else
          socket.assigns.workspaces
        end

      socket =
        socket
        |> assign(:shell, shell)
        |> assign(:workspaces, workspaces)
        |> assign(:active_workspace_id, key)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("dismiss_overlay", %{"workspace" => ws}, socket) do
    key = safe_to_existing_atom(ws)

    if is_atom(key) do
      shell = Shell.dismiss_overlay(socket.assigns.shell, key)
      {:noreply, assign(socket, :shell, shell)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("add_workspace", %{"workspace" => ws}, socket) do
    key = safe_to_existing_atom(ws)

    cond do
      !is_atom(key) ->
        {:noreply, socket}

      map_key?(socket.assigns.workspaces, key) ->
        {:noreply, assign(socket, :active_workspace_id, key)}

      true ->
        case WorkspaceRegistry.get(key) do
          nil ->
            {:noreply, socket}

          ws_mod ->
            socket = AppLive.init_workspace(socket, key, ws_mod)
            {:noreply, AppLive.maybe_hydrate_workspace(socket, key, ws_mod)}
        end
    end
  end

  def handle_event("open_workbench_home", _params, socket) do
    key = :data_table

    case WorkspaceRegistry.get(key) do
      nil ->
        {:noreply, socket}

      ws_mod ->
        added? = !map_key?(socket.assigns.workspaces, key)

        socket =
          socket
          |> ensure_workspace(key, ws_mod)
          |> assign(:active_workspace_id, key)
          |> assign(:workbench_home_open?, true)

        socket =
          if added? do
            AppLive.maybe_hydrate_workspace(socket, key, ws_mod)
          else
            socket
          end

        {:noreply, socket}
    end
  end

  def handle_event("close_workspace", %{"workspace" => ws}, socket) do
    key = safe_to_existing_atom(ws)

    if is_atom(key) and map_key?(socket.assigns.workspaces, key) do
      new_workspaces = Map.delete(socket.assigns.workspaces, key)
      new_ws_states = Map.delete(socket.assigns.ws_states, key)

      active =
        if socket.assigns.active_workspace_id == key do
          new_workspaces |> Map.keys() |> List.first()
        else
          socket.assigns.active_workspace_id
        end

      socket =
        socket
        |> assign(:workspaces, new_workspaces)
        |> assign(:ws_states, new_ws_states)
        |> assign(:active_workspace_id, active)
        |> assign(:workbench_home_open?, false)
        |> assign(:shell, Shell.remove_workspace(socket.assigns.shell, key))

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_chat", _params, socket) do
    {:noreply, assign(socket, :shell, Shell.toggle_chat(socket.assigns.shell))}
  end

  def handle_event("close_drawer", _params, socket) do
    {:noreply, assign(socket, :drawer_open, false)}
  end

  def handle_event("toggle_timeline", _params, socket) do
    {:noreply, assign(socket, :timeline_open, !socket.assigns.timeline_open)}
  end

  def handle_event("toggle_debug", _params, socket) do
    {:noreply, assign(socket, :debug_mode, !socket.assigns.debug_mode)}
  end

  def handle_event("toggle_command_palette", _params, socket) do
    {:noreply, assign(socket, :command_palette_open, !socket.assigns.command_palette_open)}
  end

  def handle_event("escape_pressed", _params, socket) do
    shell = socket.assigns.shell

    socket =
      if shell.focus_workspace_id do
        assign(socket, :shell, Shell.exit_focus(shell))
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("enter_focus", _params, socket) do
    active = socket.assigns.active_workspace_id

    if active do
      {:noreply, assign(socket, :shell, Shell.enter_focus(socket.assigns.shell, active))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("exit_focus", _params, socket) do
    {:noreply, assign(socket, :shell, Shell.exit_focus(socket.assigns.shell))}
  end

  def handle_info({:command_palette_action, action_id}, socket) do
    socket = assign(socket, :command_palette_open, false)

    socket =
      case action_id do
        "toggle_chat" ->
          assign(socket, :shell, Shell.toggle_chat(socket.assigns.shell))

        "enter_focus" ->
          active = socket.assigns.active_workspace_id

          if active do
            assign(socket, :shell, Shell.enter_focus(socket.assigns.shell, active))
          else
            socket
          end

        "exit_focus" ->
          assign(socket, :shell, Shell.exit_focus(socket.assigns.shell))

        "open_workspace:" <> key_str ->
          key = safe_to_existing_atom(key_str)

          if is_atom(key) do
            assign(socket, :active_workspace_id, key)
          else
            socket
          end

        "switch_thread:" <> thread_id ->
          {:noreply, socket} =
            ChatEvents.handle_event("switch_thread", %{"thread_id" => thread_id}, socket)

          socket

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info(:close_command_palette, socket) do
    {:noreply, assign(socket, :command_palette_open, false)}
  end

  def apply_open_workspace_event(socket, data) when is_map(data) do
    key = data[:key]

    cond do
      not is_atom(key) or is_nil(key) ->
        socket

      map_key?(socket.assigns.workspaces, key) ->
        socket
        |> assign(:active_workspace_id, key)
        |> assign(:shell, Shell.clear_activity(socket.assigns.shell, key))

      true ->
        case WorkspaceRegistry.get(key) do
          nil ->
            socket

          ws_mod ->
            socket = AppLive.init_workspace(socket, key, ws_mod)

            if key == :data_table do
              DataTableEvents.refresh_session(socket)
            else
              socket
            end
        end
    end
  end

  def apply_open_workspace_event(socket, _) do
    socket
  end

  defp ensure_workspace(socket, key, ws_mod) do
    shell = socket.assigns.shell |> Shell.add_workspace(key) |> Shell.show_chat()

    workspaces =
      if map_key?(socket.assigns.workspaces, key) do
        socket.assigns.workspaces
      else
        Map.put(socket.assigns.workspaces, key, ws_mod)
      end

    ws_states =
      if map_key?(socket.assigns.ws_states, key) do
        socket.assigns.ws_states
      else
        Map.put(socket.assigns.ws_states, key, ws_mod.projection().init())
      end

    socket
    |> assign(:shell, shell)
    |> assign(:workspaces, workspaces)
    |> assign(:ws_states, ws_states)
  end

  defp safe_to_existing_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> str
  end

  defp safe_to_existing_atom(str) do
    str
  end

  defp map_key?(map, key) do
    case Map.fetch(map, key) do
      {:ok, _} -> true
      :error -> false
    end
  end
end
