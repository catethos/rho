defmodule RhoWeb.AppLive.WorkbenchEvents do
  @moduledoc """
  Event handlers for AppLive workbench action modals and shortcuts.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [consume_uploaded_entries: 3]

  alias RhoWeb.AppLive
  alias RhoWeb.AppLive.DataTableEvents
  alias RhoWeb.Session.SessionCore
  alias RhoWeb.Session.SignalRouter
  alias RhoWeb.WorkbenchActions
  alias RhoWeb.WorkbenchActionRunner

  def handle_event("send_workbench_suggestion", %{"content" => content}, socket) do
    content = String.trim(content || "")

    if content == "" do
      {:noreply, socket}
    else
      {sid, socket, created?} = ensure_suggestion_session(socket)
      socket = AppLive.maybe_push_new_session_patch(socket, sid, created?)

      case SessionCore.send_message(socket, content) do
        {:noreply, socket} ->
          socket =
            socket
            |> AppLive.touch_active_conversation()
            |> AppLive.refresh_conversations()

          {:noreply, socket}
      end
    end
  end

  def handle_event("workbench_action_cancel", _params, socket) do
    {:noreply, close_action(socket)}
  end

  def handle_event("workbench_action_change", params, socket) do
    {:noreply,
     socket
     |> assign(:workbench_action_form, normalize_params(params))
     |> assign(:workbench_action_error, nil)}
  end

  def handle_event("workbench_action_submit", params, socket) do
    action_id = action_id(params)
    form = normalize_params(params)

    with %{} = action <- WorkbenchActions.get(action_id),
         {:ok, form, socket} <- prepare_form(socket, action.id, form),
         :ok <- WorkbenchActionRunner.validate(action.id, form) do
      run_action(socket, action, form)
    else
      nil ->
        {:noreply, assign(socket, :workbench_action_error, "Unknown Workbench action.")}

      {:error, %Phoenix.LiveView.Socket{} = socket, message} ->
        {:noreply, action_error(socket, form, message)}

      {:error, message} ->
        {:noreply, action_error(socket, form, message)}
    end
  end

  def handle_info({:workbench_action_open, action_id}, socket) do
    case WorkbenchActions.get(action_id) do
      nil ->
        {:noreply, socket}

      action ->
        {:noreply,
         socket
         |> assign(:workbench_action_modal, action)
         |> assign(:workbench_action_form, default_form(action.id))
         |> assign(:workbench_action_error, nil)
         |> assign(:workbench_action_busy?, false)
         |> assign(:workbench_action_libraries, list_libraries(socket))}
    end
  end

  def run_action(socket, %{id: id}, form)
      when id in [:create_framework, :extract_jd, :import_library] do
    prompt = WorkbenchActionRunner.build_prompt(id, form)
    send_prompt(socket, prompt)
  end

  def run_action(socket, %{id: :load_library}, form) do
    {sid, socket} = ensure_session(socket)
    _ = Rho.Stdlib.DataTable.ensure_started(sid)

    socket =
      socket
      |> assign(:workbench_action_busy?, true)
      |> DataTableEvents.load_library_into_data_table(form["library_id"])
      |> close_action()

    {:noreply, socket}
  end

  def run_action(socket, %{id: :find_roles}, form) do
    case run_find_roles(socket, form) do
      {:ok, socket} ->
        {:noreply, close_action(socket)}

      {:error, socket, message} ->
        {:noreply, action_error(socket, form, message)}
    end
  end

  def default_form(:create_framework), do: %{"skill_count" => "12"}
  def default_form(:find_roles), do: %{"limit" => "10"}
  def default_form(_), do: %{}

  def normalize_params(params) do
    params
    |> Map.drop(["_target", "action"])
    |> Map.new(fn {key, value} -> {key, value} end)
  end

  def action_id(%{"action" => action}), do: action
  def action_id(_), do: nil

  def accepted_upload?(:extract_jd, filename) do
    (filename |> Path.extname() |> String.downcase()) in ~w(.pdf .docx .txt .md .markdown)
  end

  def accepted_upload?(:import_library, filename) do
    (filename |> Path.extname() |> String.downcase()) in ~w(.csv .xlsx)
  end

  def accepted_upload?(_, _), do: true

  def close_action(socket) do
    socket
    |> assign(:workbench_action_modal, nil)
    |> assign(:workbench_action_form, %{})
    |> assign(:workbench_action_error, nil)
    |> assign(:workbench_action_busy?, false)
  end

  defp send_prompt(socket, prompt) do
    {_sid, socket} = ensure_session(socket)
    socket = socket |> DataTableEvents.open_workspace() |> assign(:workbench_action_busy?, true)

    case SessionCore.send_message(socket, prompt) do
      {:noreply, socket} ->
        socket =
          socket
          |> AppLive.touch_active_conversation()
          |> AppLive.refresh_conversations()
          |> close_action()

        {:noreply, socket}
    end
  end

  defp run_find_roles(socket, form) do
    org = socket.assigns[:current_organization]
    user = socket.assigns[:current_user]

    if is_nil(org) do
      {:error, socket, "Find Roles needs an active organization."}
    else
      {sid, socket} = ensure_session(socket)
      {:ok, _pid} = Rho.Stdlib.DataTable.ensure_started(sid)

      queries = WorkbenchActionRunner.role_queries(form)
      limit = WorkbenchActionRunner.role_limit(form)
      library_id = blank_to_nil(form["library_id"])

      opts =
        [limit: limit]
        |> maybe_put_opt(:library_id, library_id)

      groups =
        Enum.map(queries, fn query ->
          {query, RhoFrameworks.Roles.find_similar_roles(org.id, query, opts)}
        end)

      scope = %RhoFrameworks.Scope{
        organization_id: org.id,
        session_id: sid,
        user_id: user && user.id,
        source: :user,
        reason: "workbench find_roles action"
      }

      case RhoFrameworks.Workbench.write_role_candidates(scope, groups) do
        {:ok, %{table_name: table_name, total: total, per_query: per_query}} ->
          metadata = WorkbenchActionRunner.role_candidates_metadata(per_query, total, queries)

          state =
            DataTableEvents.read_state(socket)
            |> Map.merge(%{
              active_table: table_name,
              view_key: :role_candidates,
              mode_label: "Candidate Roles",
              metadata: metadata,
              error: nil
            })

          DataTableEvents.publish_view_focus(sid, table_name)

          socket =
            socket
            |> DataTableEvents.open_workspace()
            |> SignalRouter.write_ws_state(:data_table, state)
            |> DataTableEvents.refresh_session()
            |> DataTableEvents.refresh_active(table_name)

          {:ok, socket}

        {:error, reason} ->
          {:error, socket, "Find Roles failed: #{inspect(reason)}"}
      end
    end
  end

  defp prepare_form(socket, action_id, form)
       when action_id in [:extract_jd, :import_library] do
    case register_uploads(socket, action_id) do
      {:ok, socket, []} -> {:ok, form, socket}
      {:ok, socket, [handle | _]} -> {:ok, Map.put(form, "upload_id", handle.id), socket}
      {:error, socket, message} -> {:error, socket, message}
    end
  end

  defp prepare_form(socket, _action_id, form), do: {:ok, form, socket}

  defp register_uploads(socket, action_id) do
    {sid, socket} = ensure_session(socket)
    {:ok, _pid} = Rho.Stdlib.Uploads.ensure_started(sid)

    results =
      consume_uploaded_entries(socket, :files, fn %{path: tmp_path}, entry ->
        if accepted_upload?(action_id, entry.client_name) do
          case Rho.Stdlib.Uploads.put(sid, %{
                 filename: entry.client_name,
                 mime: entry.client_type || "application/octet-stream",
                 tmp_path: tmp_path,
                 size: entry.client_size
               }) do
            {:ok, handle} -> {:ok, {:ok, handle}}
            {:error, reason} -> {:ok, {:error, "#{entry.client_name}: #{inspect(reason)}"}}
          end
        else
          {:ok, {:error, "#{entry.client_name} is not a supported file for this action."}}
        end
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, message} ->
        {:error, socket, message}

      nil ->
        handles =
          Enum.flat_map(results, fn
            {:ok, handle} -> [handle]
            _ -> []
          end)

        {:ok, socket, handles}
    end
  end

  defp ensure_suggestion_session(socket) do
    if socket.assigns.session_id do
      {socket.assigns.session_id, socket, false}
    else
      ensure_opts = AppLive.session_ensure_opts(socket.assigns.live_action)
      {new_sid, socket} = SessionCore.ensure_session(socket, nil, ensure_opts)
      socket = SessionCore.subscribe_and_hydrate(socket, new_sid, ensure_opts)
      {new_sid, socket, true}
    end
  end

  defp ensure_session(socket) do
    if socket.assigns.session_id do
      {socket.assigns.session_id, socket}
    else
      ensure_opts = AppLive.session_ensure_opts(:data_table)
      {sid, socket} = SessionCore.ensure_session(socket, nil, ensure_opts)
      socket = SessionCore.subscribe_and_hydrate(socket, sid, ensure_opts)
      socket = AppLive.maybe_push_new_session_patch(socket, sid, true)
      {sid, socket}
    end
  end

  defp list_libraries(socket) do
    case socket.assigns[:current_organization] do
      %{id: org_id} -> RhoFrameworks.Library.list_libraries(org_id)
      _ -> []
    end
  end

  defp action_error(socket, form, message) do
    socket
    |> assign(:workbench_action_form, form)
    |> assign(:workbench_action_error, message)
    |> assign(:workbench_action_busy?, false)
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
