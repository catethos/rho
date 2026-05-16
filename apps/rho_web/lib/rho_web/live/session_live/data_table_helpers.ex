defmodule RhoWeb.SessionLive.DataTableHelpers do
  @moduledoc """
  Data table snapshot-cache helpers extracted from `RhoWeb.SessionLive`.

  Handles refreshing data table state in socket assigns via the
  `SignalRouter` workspace state mechanism.
  """
  import Phoenix.Component, only: [assign: 3]
  alias RhoWeb.Session.SignalRouter
  alias RhoWeb.Session.Shell
  alias RhoWeb.Workspace.Registry, as: WorkspaceRegistry

  @role_profile_table "role_profile"

  @doc """
  Refetch the session-level table list (tab strip) plus the active
  table's rows. Used on mount and on :table_created.
  """
  def refresh_data_table_session(socket) do
    sid = socket.assigns[:session_id]
    state = ensure_dt_keys(read_dt_state(socket))

    if is_nil(sid) do
      SignalRouter.write_ws_state(socket, :data_table, state)
    else
      state = merge_session_snapshot(sid, state)
      SignalRouter.write_ws_state(socket, :data_table, state)
    end
  end

  @doc "Refetch only the tab list (no active-table snapshot)."
  def refresh_data_table_tables(socket) do
    sid = socket.assigns[:session_id]
    state = ensure_dt_keys(read_dt_state(socket))

    if is_nil(sid) do
      socket
    else
      case Rho.Stdlib.DataTable.get_session_snapshot(sid) do
        %{tables: tables, table_order: order} ->
          SignalRouter.write_ws_state(socket, :data_table, %{
            state
            | tables: tables,
              table_order: order
          })

        _ ->
          socket
      end
    end
  end

  @doc """
  Refetch only the active table's rows (fastest path for frequent
  :table_changed events).
  """
  def refresh_data_table_active(socket, table_name) do
    sid = socket.assigns[:session_id]
    state = ensure_dt_keys(read_dt_state(socket))

    cond do
      is_nil(sid) ->
        socket

      state.active_table != table_name ->
        socket

      true ->
        socket = refresh_data_table_tables(socket)
        state = ensure_dt_keys(read_dt_state(socket))

        case Rho.Stdlib.DataTable.get_table_snapshot(sid, table_name) do
          {:ok, snap} ->
            new_state = %{state | active_snapshot: snap, active_version: snap.version, error: nil}
            SignalRouter.write_ws_state(socket, :data_table, new_state)

          {:error, :not_running} ->
            SignalRouter.write_ws_state(socket, :data_table, %{state | error: :not_running})

          {:error, :not_found} ->
            SignalRouter.write_ws_state(socket, :data_table, %{
              state
              | active_snapshot: nil,
                active_version: nil
            })

          _ ->
            socket
        end
    end
  end

  @doc """
  Handle a coarse invalidation event from the per-session DataTable
  server. `data` is a map with an `:event` key.
  """
  def apply_data_table_event(socket, data) when is_map(data) do
    case data[:event] do
      :table_changed ->
        handle_table_changed(socket, data)

      :table_created ->
        refresh_data_table_session(socket)

      :table_removed ->
        removed = data[:table_name]
        state = ensure_dt_keys(read_dt_state(socket))
        socket = refresh_data_table_tables(socket)

        if state.active_table == removed do
          new_state = ensure_dt_keys(read_dt_state(socket))
          fallback = pick_fallback_active_table(new_state)
          send(self(), {:data_table_switch_tab, fallback})
        end

        socket

      :view_change ->
        view_key = data[:view_key]
        mode_label = data[:mode_label]
        table_name = data[:table_name]
        state = ensure_dt_keys(read_dt_state(socket))

        if is_binary(table_name) and table_name != state.active_table do
          send(self(), {:data_table_switch_tab, table_name})
        end

        new_state = %{state | view_key: view_key, mode_label: mode_label}
        SignalRouter.write_ws_state(socket, :data_table, new_state)

      _ ->
        socket
    end
  end

  def apply_data_table_event(socket, _) do
    socket
  end

  defp handle_table_changed(socket, data) do
    table_name = data[:table_name]
    state = ensure_dt_keys(read_dt_state(socket))

    cond do
      is_nil(table_name) ->
        refresh_data_table_session(socket)

      table_name == state.active_table ->
        already_current? =
          is_integer(data[:version]) and is_integer(state.active_version) and
            data[:version] <= state.active_version

        if already_current? do
          socket
        else
          refresh_data_table_active(socket, table_name)
        end

      true ->
        refresh_data_table_tables(socket)
    end
  end

  @doc "Handle a workspace_open signal from the EffectDispatcher."
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
          nil -> socket
          ws_mod -> mount_workspace(socket, key, ws_mod)
        end
    end
  end

  def apply_open_workspace_event(socket, _) do
    socket
  end

  defp mount_workspace(socket, key, ws_mod) do
    shell = socket.assigns.shell |> Shell.add_workspace(key) |> Shell.show_chat()

    socket =
      socket
      |> assign(:workspaces, Map.put(socket.assigns.workspaces, key, ws_mod))
      |> assign(:ws_states, Map.put(socket.assigns.ws_states, key, ws_mod.projection().init()))
      |> assign(:active_workspace_id, key)
      |> assign(:shell, shell)

    if key == :data_table do
      refresh_data_table_session(socket)
    else
      socket
    end
  end

  @doc "Returns the initial data table projection state."
  def dt_initial_state do
    RhoWeb.Projections.DataTableProjection.init()
  end

  @doc """
  Backfill keys added after initial state shape so stale ws_state
  maps don't crash on struct-update syntax.
  """
  def ensure_dt_keys(state) do
    defaults = dt_initial_state()
    Map.merge(defaults, state)
  end

  def pick_fallback_active_table(%{table_order: order}) do
    cond do
      "main" in order -> "main"
      order != [] -> hd(order)
      true -> "main"
    end
  end

  @doc """
  Save the active data table rows back to their library.

  If a library record already exists for the extracted name and the user
  changed the name, renames the DB record + in-memory table first. If no
  library exists yet (newly-generated framework that was never persisted),
  delegates to `SaveFramework` which lookup-or-creates the library — so
  the first save out of the framework wizard doesn't error out with
  "library not found".
  """
  def handle_save(socket, table_name, save_params) do
    if table_name == @role_profile_table do
      handle_role_profile_save(socket, save_params)
    else
      handle_library_save(socket, table_name, save_params)
    end
  end

  defp handle_library_save(socket, table_name, new_name) do
    sid = socket.assigns[:session_id]
    org_id = get_in(socket.assigns, [:current_organization, Access.key(:id)])
    user_id = get_in(socket.assigns, [:current_user, Access.key(:id)])

    with {:ok, lib_name} <- extract_library_name(table_name),
         {:ok, effective_table, effective_name} <-
           prepare_library_for_save(lib_name, new_name, org_id, sid, table_name),
         rows when is_list(rows) and rows != [] <-
           Rho.Stdlib.DataTable.get_rows(sid, table: effective_table) do
      do_save_via_use_case(effective_name, effective_table, org_id, sid, user_id)
      socket
    else
      {:error, :not_library} ->
        send(self(), {:data_table_flash, "Save is only available for library tables."})
        socket

      {:error, :not_running} ->
        send(self(), {:data_table_flash, "Table server not running."})
        socket

      {:error, :rename_failed} ->
        send(self(), {:data_table_flash, "Failed to rename library."})
        socket

      [] ->
        send(self(), {:data_table_flash, "Table is empty — nothing to save."})
        socket

      _ ->
        send(self(), {:data_table_flash, "Save failed."})
        socket
    end
  end

  defp handle_role_profile_save(socket, save_params) do
    sid = socket.assigns[:session_id]
    org_id = get_in(socket.assigns, [:current_organization, Access.key(:id)])
    metadata = read_dt_state(socket).metadata || %{}
    role_name = effective_role_name(metadata[:role_name], save_name(save_params))
    role_family = effective_role_family(metadata, save_params)

    with rows when is_list(rows) and rows != [] <-
           Rho.Stdlib.DataTable.get_rows(sid, table: @role_profile_table),
         opts <- role_save_opts(metadata),
         attrs <- %{name: role_name, role_family: role_family},
         {:ok, %{role_profile: rp, role_skills: count}} <-
           RhoFrameworks.Roles.save_role_profile(org_id, attrs, rows, opts) do
      send(self(), {:data_table_flash, "Saved role '#{role_name}' — #{count} skill(s)."})

      socket
      |> update_role_profile_metadata(metadata, rp, role_family)
      |> update_role_group_options(role_family)
    else
      {:error, :not_running} ->
        send(self(), {:data_table_flash, "Table server not running."})
        socket

      [] ->
        send(self(), {:data_table_flash, "Role profile is empty — nothing to save."})
        socket

      {:error, step, changeset, _} ->
        send(self(), {:data_table_flash, "Save role failed at #{step}: #{inspect(changeset)}"})
        socket

      _ ->
        send(self(), {:data_table_flash, "Save role failed."})
        socket
    end
  end

  defp effective_role_name(current_name, new_name) do
    if is_binary(new_name) and String.trim(new_name) != "" do
      String.trim(new_name)
    else
      current_name || "New Role"
    end
  end

  defp save_name(%{name: name}), do: name
  defp save_name(name), do: name

  defp effective_role_family(_metadata, %{role_family: role_family}) do
    blank_to_nil(role_family)
  end

  defp effective_role_family(metadata, _save_params) do
    blank_to_nil(metadata[:role_family])
  end

  defp role_save_opts(metadata) do
    []
    |> maybe_resolve_library_id(metadata[:library_id])
    |> maybe_role_profile_id(metadata[:role_profile_id])
  end

  defp maybe_resolve_library_id(opts, library_id)
       when is_binary(library_id) and library_id != "" do
    Keyword.put(opts, :resolve_library_id, library_id)
  end

  defp maybe_resolve_library_id(opts, _library_id), do: opts

  defp maybe_role_profile_id(opts, role_profile_id)
       when is_binary(role_profile_id) and role_profile_id != "" do
    Keyword.put(opts, :role_profile_id, role_profile_id)
  end

  defp maybe_role_profile_id(opts, _role_profile_id), do: opts

  defp update_role_profile_metadata(socket, metadata, role_profile, role_family) do
    state = ensure_dt_keys(read_dt_state(socket))
    role_name = role_profile.name

    metadata =
      metadata
      |> Map.put(:role_name, role_name)
      |> Map.put(:role_profile_id, role_profile.id)
      |> Map.put(:title, role_requirements_title(role_name))
      |> Map.merge(%{persisted?: true})
      |> put_optional(:role_family, role_family)

    SignalRouter.write_ws_state(socket, :data_table, %{state | metadata: metadata})
  end

  defp put_optional(map, key, nil), do: Map.delete(map, key)
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp update_role_group_options(socket, nil), do: socket

  defp update_role_group_options(socket, role_family) do
    current = socket.assigns[:role_group_options] || []
    assign(socket, :role_group_options, Enum.sort(Enum.uniq([role_family | current])))
  end

  defp role_requirements_title(role_name) do
    trimmed = String.trim(role_name)

    cond do
      String.match?(trimmed, ~r/\brole\s+requirements\z/i) -> trimmed
      String.match?(trimmed, ~r/\brole\z/i) -> "#{trimmed} Requirements"
      true -> "#{trimmed} Role Requirements"
    end
  end

  defp prepare_library_for_save(lib_name, new_name, org_id, sid, table_name) do
    case RhoFrameworks.Library.resolve_library(org_id, lib_name) do
      nil ->
        effective_name = effective_save_name(lib_name, new_name)
        effective_table = rename_in_session_table(sid, table_name, lib_name, effective_name)
        {:ok, effective_table, effective_name}

      lib ->
        with {:ok, effective_table} <- maybe_rename_library(lib, new_name, sid, table_name) do
          effective_name = effective_save_name(lib.name, new_name)
          {:ok, effective_table, effective_name}
        end
    end
  end

  defp effective_save_name(current_name, new_name) do
    if is_binary(new_name) and String.trim(new_name) != "" and new_name != current_name do
      new_name
    else
      current_name
    end
  end

  defp rename_in_session_table(_sid, old_table, old_name, new_name) when old_name == new_name do
    old_table
  end

  defp rename_in_session_table(sid, old_table, _old_name, new_name) do
    new_table = "library:" <> new_name
    rename_data_table(sid, old_table, new_table)
    new_table
  end

  defp do_save_via_use_case(name, table_name, org_id, sid, user_id) do
    scope = %RhoFrameworks.Scope{
      organization_id: org_id,
      session_id: sid,
      user_id: user_id,
      source: :user,
      reason: "data_table:save"
    }

    input = %{name: name, table_name: table_name}

    case RhoFrameworks.UseCases.SaveFramework.run(input, scope) do
      {:ok, %{saved_count: count, library_name: name}} ->
        send(self(), {:data_table_flash, "Saved #{count} skill(s) to '#{name}'."})

      {:error, reason} ->
        send(self(), {:data_table_flash, "Save failed: #{inspect(reason)}"})
    end
  end

  @doc """
  Fork the current library into a mutable working copy.
  Auto-generates a name like "My <library_name>".
  """
  def handle_fork(socket, table_name) do
    org_id = get_in(socket.assigns, [:current_organization, Access.key(:id)])

    with {:ok, lib_name} <- extract_library_name(table_name),
         lib when not is_nil(lib) <- RhoFrameworks.Library.resolve_library(org_id, lib_name) do
      fork_name = "My #{lib.name}"

      case RhoFrameworks.Library.fork_library(org_id, lib.id, fork_name) do
        {:ok, %{library: forked, skills: count}} ->
          send(self(), {:data_table_flash, "Forked '#{forked.name}' — #{count} skills."})
          socket

        {:error, _step, reason, _} ->
          send(self(), {:data_table_flash, "Fork failed: #{inspect(reason)}"})
          socket
      end
    else
      {:error, :not_library} ->
        send(self(), {:data_table_flash, "Fork is only available for library tables."})
        socket

      nil ->
        send(self(), {:data_table_flash, "Library not found."})
        socket

      _ ->
        send(self(), {:data_table_flash, "Fork failed."})
        socket
    end
  end

  @doc "Set a transient flash message on the data table component."
  def set_flash(socket, message) do
    state = ensure_dt_keys(read_dt_state(socket))
    new_state = Map.put(state, :flash_message, message)
    SignalRouter.write_ws_state(socket, :data_table, new_state)
  end

  @doc """
  Publish the current draft library as an immutable versioned snapshot.
  Auto-saves in-memory rows first, optionally renames, then stamps a version tag.
  """
  def handle_publish(socket, table_name, new_name, version_tag) do
    sid = socket.assigns[:session_id]
    org_id = get_in(socket.assigns, [:current_organization, Access.key(:id)])

    with {:ok, lib_name} <- extract_library_name(table_name),
         lib when not is_nil(lib) <- RhoFrameworks.Library.resolve_library(org_id, lib_name),
         {:ok, effective_table} <- maybe_rename_library(lib, new_name, sid, table_name) do
      case Rho.Stdlib.DataTable.get_rows(sid, table: effective_table) do
        rows when is_list(rows) and rows != [] ->
          RhoFrameworks.Library.save_to_library(lib.id, rows)

        _ ->
          :ok
      end

      result = RhoFrameworks.Library.publish_version(org_id, lib.id, version_tag)

      case result do
        {:ok, published} ->
          send(
            self(),
            {:data_table_flash, "Published '#{published.name}' v#{published.version}."}
          )

          socket

        {:error, :already_published, msg} ->
          send(self(), {:data_table_flash, msg})
          socket

        {:error, :version_exists, msg} ->
          send(self(), {:data_table_flash, msg})
          socket

        {:error, :not_found} ->
          send(self(), {:data_table_flash, "Library not found for publishing."})
          socket

        {:error, reason} ->
          send(self(), {:data_table_flash, "Publish failed: #{inspect(reason)}"})
          socket

        other ->
          require Logger
          Logger.error("Unexpected publish result: #{inspect(other)}")
          send(self(), {:data_table_flash, "Publish failed unexpectedly."})
          socket
      end
    else
      {:error, :not_library} ->
        send(self(), {:data_table_flash, "Publish is only available for library tables."})
        socket

      {:error, :rename_failed} ->
        send(self(), {:data_table_flash, "Failed to rename library."})
        socket

      nil ->
        send(self(), {:data_table_flash, "Library not found."})
        socket

      _ ->
        send(self(), {:data_table_flash, "Publish failed."})
        socket
    end
  end

  defp extract_library_name("library:" <> name) do
    {:ok, name}
  end

  defp extract_library_name(_) do
    {:error, :not_library}
  end

  defp maybe_rename_library(%{name: current_name}, current_name, _sid, old_table_name) do
    {:ok, old_table_name}
  end

  defp maybe_rename_library(_lib, "", _sid, old_table_name) do
    {:ok, old_table_name}
  end

  defp maybe_rename_library(lib, new_name, sid, old_table_name) do
    case RhoFrameworks.Library.rename_library(lib.organization_id, lib.id, new_name) do
      {:ok, _} ->
        new_table_name = "library:" <> new_name
        rename_data_table(sid, old_table_name, new_table_name)
        {:ok, new_table_name}

      {:error, _} ->
        {:error, :rename_failed}
    end
  end

  defp rename_data_table(sid, old_name, new_name) when old_name != new_name do
    schema = RhoFrameworks.DataTableSchemas.library_schema()

    with rows when is_list(rows) <- Rho.Stdlib.DataTable.get_rows(sid, table: old_name),
         :ok <- Rho.Stdlib.DataTable.ensure_table(sid, new_name, schema),
         {:ok, _} <- Rho.Stdlib.DataTable.replace_all(sid, rows, table: new_name) do
      Rho.Stdlib.DataTable.drop_table(sid, old_name)
      send(self(), {:data_table_switch_tab, new_name})
      :ok
    else
      _ -> :ok
    end
  end

  defp rename_data_table(_, _, _) do
    :ok
  end

  defp read_dt_state(socket) do
    SignalRouter.read_ws_state(socket, :data_table) || dt_initial_state()
  end

  defp merge_session_snapshot(sid, state) do
    case Rho.Stdlib.DataTable.get_session_snapshot(sid) do
      %{tables: tables, table_order: order} ->
        state = %{state | tables: tables, table_order: order, error: nil}
        state = maybe_adopt_default_active(state)
        apply_active_table_snapshot(sid, state)

      {:error, :not_running} ->
        %{state | error: :not_running}

      _ ->
        state
    end
  end

  defp apply_active_table_snapshot(sid, state) do
    case Rho.Stdlib.DataTable.get_table_snapshot(sid, state.active_table) do
      {:ok, snap} ->
        %{state | active_snapshot: snap, active_version: snap.version}

      {:error, :not_running} ->
        %{state | active_snapshot: nil, active_version: nil, error: :not_running}

      _ ->
        state
    end
  end

  defp maybe_adopt_default_active(%{active_table: active, table_order: order} = state) do
    cond do
      is_binary(active) and active in order -> state
      "main" in order -> %{state | active_table: "main"}
      order != [] -> %{state | active_table: hd(order)}
      true -> state
    end
  end

  defp map_key?(map, key) do
    case Map.fetch(map, key) do
      {:ok, _} -> true
      :error -> false
    end
  end
end
