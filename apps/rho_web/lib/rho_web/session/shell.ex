defmodule RhoWeb.Session.Shell do
  @moduledoc """
  UI chrome state — panel modes, workspace activity indicators, surface
  types (tab vs overlay), and visibility. Kept separate from projection
  state (which is signal-derived).
  """
  @type panel_mode :: :expanded | :collapsed | :hidden
  @type workspace_chrome :: %{
          open?: boolean(),
          surface: :tab | :overlay,
          collapsed: boolean(),
          pulse: boolean(),
          unseen_count: non_neg_integer(),
          last_activity_at: integer() | nil,
          dismissed_correlation_id: String.t() | nil
        }
  @type t :: %{
          chat_mode: panel_mode(),
          focus_workspace_id: atom() | nil,
          workspaces: %{atom() => workspace_chrome()}
        }
  @doc "Initialize shell state for the given open workspace keys + full registry keys."
  def init(open_keys, all_keys \\ []) do
    has_workspaces = open_keys != []
    all = Enum.uniq(open_keys ++ all_keys)

    %{
      chat_mode:
        if has_workspaces do
          :expanded
        else
          :hidden
        end,
      focus_workspace_id: nil,
      workspaces:
        Map.new(all, fn key ->
          is_open = key in open_keys

          {key,
           %{
             open?: is_open,
             surface:
               if is_open do
                 :tab
               else
                 :overlay
               end,
             collapsed: false,
             pulse: false,
             unseen_count: 0,
             last_activity_at: nil,
             dismissed_correlation_id: nil
           }}
        end)
    }
  end

  @doc "Toggle chat between expanded and collapsed. Hidden stays hidden."
  def toggle_chat(%{chat_mode: :expanded} = shell) do
    %{shell | chat_mode: :collapsed}
  end

  def toggle_chat(%{chat_mode: :collapsed} = shell) do
    %{shell | chat_mode: :expanded}
  end

  def toggle_chat(shell) do
    shell
  end

  @doc "Show chat panel (set to expanded if currently hidden)."
  def show_chat(shell) do
    %{shell | chat_mode: :expanded}
  end

  @doc "Hide chat panel."
  def hide_chat(shell) do
    %{shell | chat_mode: :hidden}
  end

  @doc """
  Maybe auto-open a workspace as an overlay based on signal activity.
  Returns `{shell, opened?}` where `opened?` indicates if it was newly opened.

  Won't open if:
  - already open
  - dismissed for this correlation_id
  """
  def maybe_auto_open(shell, key, correlation_id) do
    case get_in(shell, [:workspaces, key]) do
      nil ->
        {shell, false}

      %{open?: true} ->
        {shell, false}

      %{dismissed_correlation_id: cid} when cid == correlation_id and not is_nil(cid) ->
        {shell, false}

      chrome ->
        updated = %{chrome | open?: true, surface: :overlay, collapsed: false}
        {put_in(shell, [:workspaces, key], updated), true}
    end
  end

  @doc "Pin an overlay workspace into a tab."
  def pin_workspace(shell, key) do
    case get_in(shell, [:workspaces, key]) do
      nil -> shell
      chrome -> put_in(shell, [:workspaces, key], %{chrome | surface: :tab})
    end
  end

  @doc "Dismiss an overlay workspace. Records the correlation_id to suppress re-open."
  def dismiss_overlay(shell, key, correlation_id \\ nil) do
    case get_in(shell, [:workspaces, key]) do
      nil ->
        shell

      chrome ->
        put_in(shell, [:workspaces, key], %{
          chrome
          | open?: false,
            surface: :overlay,
            dismissed_correlation_id: correlation_id
        })
    end
  end

  @doc "Record activity on a workspace (for badge/pulse indicators)."
  def record_activity(shell, key, active_workspace_id) do
    case get_in(shell, [:workspaces, key]) do
      nil ->
        shell

      chrome ->
        is_visible = chrome.open? and key == active_workspace_id and not chrome.collapsed
        now = System.system_time(:millisecond)

        updated = %{
          chrome
          | pulse: true,
            last_activity_at: now,
            unseen_count:
              if is_visible do
                0
              else
                chrome.unseen_count + 1
              end
        }

        put_in(shell, [:workspaces, key], updated)
    end
  end

  @doc "Clear activity indicators for a workspace (when it becomes visible)."
  def clear_activity(shell, key) do
    case get_in(shell, [:workspaces, key]) do
      nil -> shell
      chrome -> put_in(shell, [:workspaces, key], %{chrome | pulse: false, unseen_count: 0})
    end
  end

  @doc "Set collapsed state for a workspace panel."
  def set_collapsed(shell, key, collapsed?) do
    case get_in(shell, [:workspaces, key]) do
      nil -> shell
      chrome -> put_in(shell, [:workspaces, key], %{chrome | collapsed: collapsed?})
    end
  end

  @doc "Clear pulse flag (called after animation timeout)."
  def clear_pulse(shell, key) do
    case get_in(shell, [:workspaces, key]) do
      nil -> shell
      chrome -> put_in(shell, [:workspaces, key], %{chrome | pulse: false})
    end
  end

  @doc "Add a workspace to the shell state as an open tab."
  def add_workspace(shell, key) do
    case get_in(shell, [:workspaces, key]) do
      nil ->
        put_in(shell, [:workspaces, key], %{
          open?: true,
          surface: :tab,
          collapsed: false,
          pulse: false,
          unseen_count: 0,
          last_activity_at: nil,
          dismissed_correlation_id: nil
        })

      chrome ->
        put_in(shell, [:workspaces, key], %{chrome | open?: true, surface: :tab})
    end
  end

  @doc "Remove a workspace from the shell state (close tab)."
  def remove_workspace(shell, key) do
    case get_in(shell, [:workspaces, key]) do
      nil ->
        shell

      chrome ->
        updated = put_in(shell, [:workspaces, key], %{chrome | open?: false, surface: :overlay})
        has_open = Enum.any?(updated.workspaces, fn {_k, c} -> c.open? end)

        if has_open do
          updated
        else
          %{updated | chat_mode: :hidden}
        end
    end
  end

  @doc "Return keys of workspaces that are open as tabs."
  def tab_keys(shell) do
    shell.workspaces
    |> Enum.filter(fn {_k, c} -> c.open? and c.surface == :tab end)
    |> Enum.map(fn {k, _c} -> k end)
  end

  @doc "Enter focus mode — fullscreen the given workspace, collapse chat."
  def enter_focus(shell, key) do
    %{shell | focus_workspace_id: key, chat_mode: :collapsed}
  end

  @doc "Exit focus mode — restore chat to expanded."
  def exit_focus(shell) do
    %{shell | focus_workspace_id: nil, chat_mode: :expanded}
  end

  @doc "Total unseen message count across all workspaces (for floating pill)."
  def total_unseen_chat_count(shell) do
    Enum.reduce(
      shell.workspaces,
      0,
      fn {_k, chrome}, acc -> acc + chrome.unseen_count end
    )
  end

  @doc "Return keys of workspaces that are open as overlays."
  def overlay_keys(shell) do
    shell.workspaces
    |> Enum.filter(fn {_k, c} -> c.open? and c.surface == :overlay end)
    |> Enum.map(fn {k, _c} -> k end)
  end
end