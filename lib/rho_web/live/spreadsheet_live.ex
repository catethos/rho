defmodule RhoWeb.SpreadsheetLive do
  @moduledoc """
  Two-panel LiveView: streamed HTML table spreadsheet (left) + Rho agent chat (right).
  Interactive skill framework editor powered by an AI agent.

  Uses LiveView streams for progressive rendering — each rows_delta signal
  inserts rows via stream_insert, producing minimal DOM patches.
  """
  use Phoenix.LiveView

  import RhoWeb.CoreComponents
  import RhoWeb.ChatComponents

  alias RhoWeb.SessionProjection

  @impl true
  def mount(params, _session, socket) do
    session_id = params["session_id"]

    socket =
      socket
      |> assign(:session_id, session_id)
      |> assign(:rows_map, %{})
      |> assign(:next_id, 1)
      |> assign(:editing, nil)
      |> assign(:partial_streamed, %{})
      |> assign(:collapsed, MapSet.new())
      # Chat state (mirrors SessionLive's shape for SessionProjection compatibility)
      |> assign(:agents, %{})
      |> assign(:active_tab, nil)
      |> assign(:tab_order, [])
      |> assign(:inflight, %{})
      |> assign(:signals, [])
      |> assign(:agent_messages, %{})
      |> assign(:ui_streams, %{})
      |> assign(:pending_response, MapSet.new())
      |> assign(:total_input_tokens, 0)
      |> assign(:total_output_tokens, 0)
      |> assign(:total_cost, 0.0)
      |> assign(:total_cached_tokens, 0)
      |> assign(:total_reasoning_tokens, 0)
      |> assign(:step_input_tokens, 0)
      |> assign(:step_output_tokens, 0)
      |> assign(:parsed_files, %{})
      |> assign(:parsing_files, false)
      |> assign(:parsing_task_ref, nil)
      |> assign(:connected, connected?(socket))
      |> assign(:user_avatar, load_avatar("avatar"))
      |> assign(
        :agent_avatar,
        Rho.Config.load_avatar(:spreadsheet) || load_avatar("agent_avatar")
      )

    socket =
      if connected?(socket) do
        {sid, socket} = ensure_session(socket, session_id)

        socket
        |> assign(:session_id, sid)
        |> subscribe_and_hydrate(sid)
      else
        socket
      end

    socket =
      allow_upload(socket, :files,
        accept: ~w(.xlsx .csv .pdf .jpg .jpeg .png .webp),
        max_entries: 10,
        max_file_size: 10_000_000
      )

    {:ok, socket, layout: {RhoWeb.Layouts, :app}}
  end

  @impl true
  def handle_params(%{"session_id" => sid}, _uri, socket) do
    socket =
      if socket.assigns.session_id != sid && connected?(socket) do
        unsubscribe_current(socket)
        socket = assign(socket, :session_id, sid)
        subscribe_and_hydrate(socket, sid)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if sid = socket.assigns[:session_id] do
      Rho.Mounts.Spreadsheet.unregister(sid)
    end

    :ok
  end

  # --- Inline editing events ---

  @impl true
  def handle_event("start_edit", %{"id" => id, "field" => field}, socket) do
    {:noreply, assign(socket, :editing, {String.to_integer(id), field})}
  end

  def handle_event("save_edit", %{"row_id" => id, "field" => field, "value" => value}, socket) do
    row_id = String.to_integer(id)
    field_atom = String.to_existing_atom(field)
    rows_map = Map.update!(socket.assigns.rows_map, row_id, &Map.put(&1, field_atom, value))
    row = rows_map[row_id]

    socket =
      socket
      |> assign(:rows_map, rows_map)
      |> assign(:editing, nil)
      |> stream_insert(:rows, row)

    {:noreply, socket}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :editing, nil)}
  end

  def handle_event("toggle_group", %{"group" => group_id}, socket) do
    collapsed = socket.assigns.collapsed

    collapsed =
      if MapSet.member?(collapsed, group_id),
        do: MapSet.delete(collapsed, group_id),
        else: MapSet.put(collapsed, group_id)

    {:noreply, assign(socket, :collapsed, collapsed)}
  end

  # --- Chat events ---

  def handle_event("send_message", %{"content" => content}, socket) do
    content = String.trim(content)
    has_files = socket.assigns.uploads.files.entries != []

    if content == "" and not has_files do
      {:noreply, socket}
    else
      do_send_with_files(content, socket)
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :files, ref)}
  end

  def handle_event("validate_upload", _params, socket) do
    total_size =
      Enum.reduce(socket.assigns.uploads.files.entries, 0, fn entry, acc ->
        entry.client_size + acc
      end)

    socket =
      if total_size > 50_000_000 do
        put_flash(socket, :error, "Total upload size exceeds 50MB.")
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("select_tab", %{"agent-id" => agent_id}, socket) do
    {:noreply, assign(socket, :active_tab, agent_id)}
  end

  # --- Messages from agent tools (synchronous reads only) ---

  @impl true
  def handle_info({:spreadsheet_get_table, {caller_pid, ref}, filter}, socket) do
    rows = socket.assigns.rows_map |> Map.values() |> filter_rows(filter)
    send(caller_pid, {ref, {:ok, rows}})
    {:noreply, socket}
  end

  # --- Signal bus events ---

  # --- File parsing results ---

  def handle_info({:files_parsed, content, file_results}, socket) do
    socket =
      socket
      |> assign(:parsing_files, false)
      |> assign(:parsing_task_ref, nil)

    # Store parsed data for get_uploaded_file tool
    parsed_files =
      Enum.reduce(file_results, socket.assigns.parsed_files, fn
        %{filename: name, result: {:structured, data}}, acc ->
          Map.put(acc, name, {:structured, data})

        %{filename: name, result: {:text, text}}, acc ->
          Map.put(acc, name, {:text, text})

        _, acc ->
          acc
      end)

    socket = assign(socket, :parsed_files, parsed_files)

    # Build enriched message
    {text_summary, image_parts} = build_file_context(file_results)

    display_text =
      case {content, text_summary} do
        {"", ""} -> "[Files uploaded]"
        {c, ""} -> c
        {"", s} -> s
        {c, s} -> c <> "\n\n" <> s
      end

    submit_content =
      if image_parts != [] do
        text_parts =
          if display_text != "",
            do: [ReqLLM.Message.ContentPart.text(display_text)],
            else: []

        text_parts ++ image_parts
      else
        display_text
      end

    do_send_message_with_display(submit_content, display_text, socket)
  end

  # Task completed successfully — clean up monitor
  def handle_info({ref, _result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, socket}
  end

  # Task crashed — reset parsing state and show error
  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    if ref == socket.assigns[:parsing_task_ref] do
      socket =
        socket
        |> assign(:parsing_files, false)
        |> assign(:parsing_task_ref, nil)
        |> put_flash(:error, "File parsing failed: #{inspect(reason)}")

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # --- Uploaded file tool reads ---

  def handle_info({:get_uploaded_file, {caller_pid, ref}, args}, socket) do
    filename = args["filename"] || ""
    sheet_name = args["sheet"]
    offset = args["offset"] || 0
    limit = args["limit"] || 200

    result =
      case Map.get(socket.assigns.parsed_files, filename) do
        nil ->
          available = socket.assigns.parsed_files |> Map.keys() |> Enum.join(", ")

          {:error, "No uploaded file found: \"#{filename}\". Available: #{available}"}

        {:structured, %{sheets: sheets}} ->
          sheet =
            if sheet_name do
              Enum.find(sheets, hd(sheets), &(&1.name == sheet_name))
            else
              hd(sheets)
            end

          paginated_rows = sheet.rows |> Enum.drop(offset) |> Enum.take(limit)
          total = sheet.row_count

          {:ok,
           %{
             name: sheet.name,
             columns: sheet.columns,
             rows: paginated_rows,
             row_count: length(paginated_rows),
             total_rows: total,
             offset: offset,
             has_more: offset + limit < total
           }}

        {:text, text} ->
          {:ok, %{type: "text", content: text, char_count: String.length(text)}}
      end

    send(caller_pid, {ref, result})
    {:noreply, socket}
  end

  # --- Signal bus events ---

  def handle_info({:signal, %Jido.Signal{type: type, data: data} = signal}, socket) do
    sid = socket.assigns.session_id

    if signal_for_session?(data, sid) do
      correlation_id = get_in(signal.extensions || %{}, ["correlation_id"])
      data = Map.put(data, :correlation_id, correlation_id)

      # Route spreadsheet signals directly; everything else goes through SessionProjection
      cond do
        String.contains?(type, ".spreadsheet_rows_delta") ->
          {:noreply, handle_rows_delta(socket, data)}

        String.contains?(type, ".spreadsheet_replace_all") ->
          {:noreply, handle_replace_all(socket)}

        String.contains?(type, ".spreadsheet_update_cells") ->
          {:noreply, handle_update_cells(socket, data)}

        String.contains?(type, ".spreadsheet_delete_rows") ->
          {:noreply, handle_delete_rows(socket, data)}

        String.contains?(type, ".structured_partial") ->
          {:noreply, handle_structured_partial(socket, data)}

        true ->
          {:noreply, SessionProjection.project(socket, %{type: type, data: data})}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:ui_spec_tick, message_id}, socket) do
    ui_streams = socket.assigns.ui_streams

    case Map.get(ui_streams, message_id) do
      %{queue: [spec | rest]} = stream ->
        socket = update_ui_message(socket, message_id, spec, true)
        stream = %{stream | queue: rest}

        if rest == [] and stream.final_spec do
          socket = update_ui_message(socket, message_id, stream.final_spec, false)
          {:noreply, assign(socket, :ui_streams, Map.delete(ui_streams, message_id))}
        else
          ui_streams = Map.put(ui_streams, message_id, stream)
          Process.send_after(self(), {:ui_spec_tick, message_id}, 40)
          {:noreply, assign(socket, :ui_streams, ui_streams)}
        end

      %{queue: [], final_spec: final} when not is_nil(final) ->
        socket = update_ui_message(socket, message_id, final, false)
        {:noreply, assign(socket, :ui_streams, Map.delete(ui_streams, message_id))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Spreadsheet signal handlers ---

  defp handle_rows_delta(socket, data) do
    new_rows = data[:rows] || data["rows"] || []
    new_rows = Enum.map(new_rows, &atomize_keys/1)

    # Skip rows already streamed via structured_partial (keyed by agent_id)
    agent_id = data[:agent_id] || data["agent_id"]
    already = Map.get(socket.assigns.partial_streamed, agent_id, 0)

    if already > 0 and length(new_rows) <= already do
      new_partial = Map.put(socket.assigns.partial_streamed, agent_id, already - length(new_rows))
      assign(socket, :partial_streamed, new_partial)
    else
      to_skip = min(already, length(new_rows))
      remaining = Enum.drop(new_rows, to_skip)
      {rows, next_id} = assign_ids(remaining, socket.assigns.next_id)

      rows_map = Enum.reduce(rows, socket.assigns.rows_map, fn r, m -> Map.put(m, r.id, r) end)

      new_partial =
        if already > 0,
          do: Map.delete(socket.assigns.partial_streamed, agent_id),
          else: socket.assigns.partial_streamed

      socket
      |> assign(:rows_map, rows_map)
      |> assign(:next_id, next_id)
      |> assign(:partial_streamed, new_partial)
    end
  end

  defp handle_replace_all(socket) do
    socket
    |> assign(:rows_map, %{})
    |> assign(:next_id, 1)
    |> assign(:partial_streamed, %{})
  end

  defp handle_update_cells(socket, data) do
    changes = data[:changes] || data["changes"] || []
    rows_map = apply_cell_changes_to_map(socket.assigns.rows_map, changes)
    assign(socket, :rows_map, rows_map)
  end

  defp handle_delete_rows(socket, data) do
    ids = data[:ids] || data["ids"] || []
    rows_map = Map.drop(socket.assigns.rows_map, ids)
    assign(socket, :rows_map, rows_map)
  end

  # --- Structured partial handler (progressive row streaming) ---

  defp handle_structured_partial(socket, data) do
    parsed = data[:parsed] || data["parsed"]
    agent_id = data[:agent_id] || data["agent_id"]

    case parsed do
      %{"action" => "add_rows", "action_input" => %{"rows_json" => partial_json}}
      when is_binary(partial_json) ->
        stream_partial_rows(socket, partial_json, agent_id)

      %{"action" => "replace_all", "action_input" => %{"rows_json" => partial_json}}
      when is_binary(partial_json) ->
        stream_partial_rows(socket, partial_json, agent_id)

      _ ->
        socket
    end
  end

  defp stream_partial_rows(socket, partial_json, agent_id) do
    case extract_complete_rows(partial_json) do
      rows when is_list(rows) and rows != [] ->
        already_streamed = Map.get(socket.assigns.partial_streamed, agent_id, 0)
        new_count = length(rows)

        if new_count > already_streamed do
          # Only stream the newly completed rows
          new_rows =
            rows
            |> Enum.drop(already_streamed)
            |> Enum.map(&atomize_keys/1)

          {id_rows, next_id} = assign_ids(new_rows, socket.assigns.next_id)

          rows_map =
            Enum.reduce(id_rows, socket.assigns.rows_map, fn r, m -> Map.put(m, r.id, r) end)

          new_partial = Map.put(socket.assigns.partial_streamed, agent_id, new_count)

          socket
          |> assign(:rows_map, rows_map)
          |> assign(:next_id, next_id)
          |> assign(:partial_streamed, new_partial)
        else
          socket
        end

      _ ->
        socket
    end
  end

  # Extract complete JSON objects from a potentially incomplete JSON array string.
  # e.g. "[{...}, {...}, {..." → [{...}, {...}] (drops the incomplete last object)
  defp extract_complete_rows(partial_json) do
    trimmed = String.trim(partial_json)

    # Try parsing as-is first (complete JSON)
    case Jason.decode(trimmed) do
      {:ok, rows} when is_list(rows) ->
        rows

      _ ->
        # Try auto-closing: find last complete object by scanning for matching braces
        extract_complete_objects(trimmed)
    end
  end

  defp extract_complete_objects(text) do
    # Strip leading [ if present
    inner =
      case text do
        "[" <> rest -> rest
        other -> other
      end

    # Walk through and extract complete {...} objects
    do_extract_objects(inner, 0, "", [])
  end

  defp do_extract_objects("", _depth, _acc, found), do: Enum.reverse(found)

  defp do_extract_objects(<<"{", rest::binary>>, 0, _acc, found) do
    # Start of a new object
    do_extract_objects(rest, 1, "{", found)
  end

  defp do_extract_objects(<<"{", rest::binary>>, depth, acc, found) when depth > 0 do
    do_extract_objects(rest, depth + 1, acc <> "{", found)
  end

  defp do_extract_objects(<<"}", rest::binary>>, 1, acc, found) do
    # Completed an object at depth 0
    obj_str = acc <> "}"

    case Jason.decode(obj_str) do
      {:ok, obj} when is_map(obj) ->
        do_extract_objects(rest, 0, "", [obj | found])

      _ ->
        # Malformed object, skip it
        do_extract_objects(rest, 0, "", found)
    end
  end

  defp do_extract_objects(<<"}", rest::binary>>, depth, acc, found) when depth > 1 do
    do_extract_objects(rest, depth - 1, acc <> "}", found)
  end

  defp do_extract_objects(<<"\"", rest::binary>>, depth, acc, found) when depth > 0 do
    # Inside a string — skip to end of string (handle escapes)
    {string_content, remaining} = skip_json_string(rest, "")
    do_extract_objects(remaining, depth, acc <> "\"" <> string_content <> "\"", found)
  end

  defp do_extract_objects(<<c, rest::binary>>, depth, acc, found) when depth > 0 do
    do_extract_objects(rest, depth, acc <> <<c>>, found)
  end

  defp do_extract_objects(<<_c, rest::binary>>, 0, acc, found) do
    # Outside any object, skip (commas, whitespace, etc.)
    do_extract_objects(rest, 0, acc, found)
  end

  # Skip through a JSON string, handling escape sequences
  defp skip_json_string("", acc), do: {acc, ""}

  defp skip_json_string(<<"\\", c, rest::binary>>, acc),
    do: skip_json_string(rest, acc <> "\\" <> <<c>>)

  defp skip_json_string(<<"\"", rest::binary>>, acc), do: {acc, rest}
  defp skip_json_string(<<c, rest::binary>>, acc), do: skip_json_string(rest, acc <> <<c>>)

  # --- Render ---

  @impl true
  def render(assigns) do
    active_tab = assigns.active_tab
    active_messages = Map.get(assigns.agent_messages, active_tab, [])

    active_inflight =
      if active_tab do
        Map.take(assigns.inflight, [active_tab])
      else
        primary_id = primary_agent_id(assigns.session_id)
        Map.take(assigns.inflight, [primary_id])
      end

    grouped = group_rows(assigns.rows_map)

    assigns =
      assigns
      |> assign(:active_messages, active_messages)
      |> assign(:active_inflight, active_inflight)
      |> assign(:grouped, grouped)

    ~H"""
    <div class="spreadsheet-layout">
      <div class="spreadsheet-panel">
        <div class="spreadsheet-toolbar">
          <h2 class="spreadsheet-title">Skill Framework Editor</h2>
          <span class="ss-row-count"><%= map_size(@rows_map) %> rows</span>
          <span :if={MapSet.size(@pending_response) > 0} class="spreadsheet-streaming">
            streaming...
          </span>
          <span :if={@total_cost > 0} class="spreadsheet-cost">
            $<%= :erlang.float_to_binary(@total_cost / 1, decimals: 4) %>
          </span>
        </div>

        <div class="ss-table-wrap">
          <%= if @grouped == [] do %>
            <div class="ss-empty">No data — ask the assistant to generate a skill framework</div>
          <% else %>
            <%= for {category, clusters} <- @grouped do %>
              <% cat_id = "cat-" <> slug(category) %>
              <div id={cat_id} class={"ss-group ss-cat-group" <> if(MapSet.member?(@collapsed, cat_id), do: " ss-collapsed", else: "")}>
                <div class="ss-group-header ss-cat-header" phx-click="toggle_group" phx-value-group={cat_id}>
                  <span class="ss-chevron"></span>
                  <span class="ss-group-name"><%= category %></span>
                  <span class="ss-group-count"><%= count_group_rows(clusters) %> rows</span>
                </div>
                <div class={"ss-group-content" <> if(MapSet.member?(@collapsed, cat_id), do: " ss-hidden", else: "")}>
                  <%= for {cluster, rows} <- clusters do %>
                    <% cluster_id = "cluster-" <> slug(category) <> "-" <> slug(cluster) %>
                    <div id={cluster_id} class={"ss-group ss-cluster-group" <> if(MapSet.member?(@collapsed, cluster_id), do: " ss-collapsed", else: "")}>
                      <div class="ss-group-header ss-cluster-header" phx-click="toggle_group" phx-value-group={cluster_id}>
                        <span class="ss-chevron"></span>
                        <span class="ss-group-name"><%= cluster %></span>
                        <span class="ss-group-count"><%= length(rows) %> rows</span>
                      </div>
                      <div class={"ss-group-content" <> if(MapSet.member?(@collapsed, cluster_id), do: " ss-hidden", else: "")}>
                        <table class="ss-table">
                          <thead>
                            <tr>
                              <th class="ss-th ss-th-id">ID</th>
                              <th class="ss-th ss-th-skill">Skill</th>
                              <th class="ss-th ss-th-desc">Description</th>
                              <th class="ss-th ss-th-lvl">Lvl</th>
                              <th class="ss-th ss-th-lvlname">Level Name</th>
                              <th class="ss-th ss-th-lvldesc">Level Description</th>
                            </tr>
                          </thead>
                          <tbody>
                            <tr :for={row <- rows} id={"row-#{row.id}"} class="ss-row">
                              <td class="ss-td ss-td-id"><%= row.id %></td>
                              <.editable_cell row={row} field={:skill_name} editing={@editing} />
                              <.editable_cell row={row} field={:skill_description} editing={@editing} type="textarea" />
                              <.editable_cell row={row} field={:level} editing={@editing} type="number" />
                              <.editable_cell row={row} field={:level_name} editing={@editing} />
                              <.editable_cell row={row} field={:level_description} editing={@editing} type="textarea" />
                            </tr>
                          </tbody>
                        </table>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>

      <div class="spreadsheet-chat-panel">
        <div class="spreadsheet-chat-header">
          <span class="spreadsheet-chat-title">Assistant</span>
          <.status_dot :if={chat_status(assigns) != :idle} status={chat_status(assigns)} />
        </div>

        <.chat_feed
          messages={@active_messages}
          session_id={@session_id || ""}
          inflight={@active_inflight}
          active_tab={@active_tab || ""}
          user_avatar={@user_avatar}
          agent_avatar={@agent_avatar}
          pending={MapSet.member?(@pending_response, @active_tab || primary_agent_id(@session_id))}
        />

        <div class="chat-input-area">
          <div :if={@uploads.files.entries != []} class="file-chips">
            <%= for entry <- @uploads.files.entries do %>
              <div class={"file-chip" <> if(!entry.valid?, do: " file-chip-error", else: "")}>
                <span class="file-chip-icon"><%= file_type_icon(entry.client_type) %></span>
                <span class="file-chip-name"><%= entry.client_name %></span>
                <span
                  :if={entry.progress > 0 and entry.progress < 100}
                  class="file-chip-progress"
                >
                  <%= entry.progress %>%
                </span>
                <span
                  :for={err <- upload_errors(@uploads.files, entry)}
                  class="file-chip-err"
                >
                  <%= humanize_upload_error(err) %>
                </span>
                <button
                  type="button"
                  phx-click="cancel_upload"
                  phx-value-ref={entry.ref}
                  class="file-chip-remove"
                >
                  &times;
                </button>
              </div>
            <% end %>
            <span :for={err <- upload_errors(@uploads.files)} class="file-chips-err">
              <%= humanize_upload_error(err) %>
            </span>
          </div>

          <div :if={@parsing_files} class="parsing-indicator">
            Parsing files...
          </div>

          <form
            id="chat-input-form"
            phx-submit="send_message"
            phx-change="validate_upload"
            class="chat-input-form"
          >
            <.live_file_input upload={@uploads.files} class="file-input-hidden" />
            <label for={@uploads.files.ref} class="btn-attach" title="Attach files">
              <svg
                width="18"
                height="18"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
              >
                <path d="M21.44 11.05l-9.19 9.19a6 6 0 01-8.49-8.49l9.19-9.19a4 4 0 015.66 5.66l-9.2 9.19a2 2 0 01-2.83-2.83l8.49-8.48" />
              </svg>
            </label>
            <textarea
              name="content"
              id="chat-input"
              placeholder="Ask to generate skills, import files, edit rows..."
              rows="1"
              phx-hook="AutoResize"
            ></textarea>
            <button type="submit" class="btn-send">Send</button>
          </form>
        </div>
      </div>
    </div>
    """
  end

  # --- editable_cell component ---

  defp editable_cell(assigns) do
    editing? = assigns.editing == {assigns.row.id, Atom.to_string(assigns.field)}
    value = Map.get(assigns.row, assigns.field, "")
    type = Map.get(assigns, :type, "input")

    assigns = assign(assigns, editing?: editing?, value: value, input_type: type)

    ~H"""
    <td
      class={"ss-td ss-td-#{@field}"}
      phx-click="start_edit"
      phx-value-id={@row.id}
      phx-value-field={@field}
    >
      <%= if @editing? do %>
        <form phx-submit="save_edit" phx-click-away="cancel_edit">
          <input type="hidden" name="row_id" value={@row.id} />
          <input type="hidden" name="field" value={@field} />
          <%= if @input_type == "textarea" do %>
            <textarea
              name="value"
              class="ss-cell-input"
              phx-hook="AutoFocus"
              id={"edit-#{@row.id}-#{@field}"}
              phx-keydown="cancel_edit"
              phx-key="Escape"
            ><%= @value %></textarea>
          <% else %>
            <input
              type={if @input_type == "number", do: "number", else: "text"}
              name="value"
              value={@value}
              class="ss-cell-input"
              phx-hook="AutoFocus"
              id={"edit-#{@row.id}-#{@field}"}
              phx-blur="save_edit"
              phx-value-id={@row.id}
              phx-value-field={@field}
              phx-keydown="cancel_edit"
              phx-key="Escape"
            />
          <% end %>
        </form>
      <% else %>
        <span class="ss-cell-text"><%= @value %></span>
      <% end %>
    </td>
    """
  end

  # --- Private helpers ---

  defp do_send_message(content, socket) do
    sid = socket.assigns.session_id

    {sid, socket} =
      if sid do
        {sid, socket}
      else
        {new_sid, sock} = ensure_session(socket, nil)
        sock = subscribe_and_hydrate(sock, new_sid)
        {new_sid, assign(sock, :session_id, new_sid)}
      end

    target_id = socket.assigns.active_tab

    user_msg = %{
      id: "user_#{System.unique_integer([:positive])}",
      role: :user,
      type: :text,
      content: content,
      agent_id: target_id
    }

    socket = SessionProjection.append_message(socket, user_msg)

    result =
      if target_id do
        case Rho.Agent.Worker.whereis(target_id) do
          nil -> {:error, "Agent not found"}
          pid -> Rho.Agent.Worker.submit(pid, content)
        end
      else
        Rho.Session.submit(sid, content)
      end

    case result do
      {:ok, _turn_id} ->
        pending_id = target_id || primary_agent_id(sid)
        pending = MapSet.put(socket.assigns.pending_response, pending_id)
        {:noreply, assign(socket, :pending_response, pending)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to send: #{inspect(reason)}")}
    end
  end

  defp do_send_with_files(content, socket) do
    file_entries =
      consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
        stable_path =
          Path.join(
            System.tmp_dir!(),
            "rho_upload_#{System.unique_integer([:positive])}_#{entry.client_name}"
          )

        File.cp!(path, stable_path)
        {:ok, %{filename: entry.client_name, path: stable_path, mime: entry.client_type}}
      end)

    if file_entries == [] do
      do_send_message(content, socket)
    else
      parent = self()

      task =
        Task.Supervisor.async_nolink(Rho.TaskSupervisor, fn ->
          results =
            Enum.map(file_entries, fn entry ->
              result =
                try do
                  Rho.FileParser.parse(entry.path, entry.mime)
                rescue
                  e -> {:error, "Parse failed: #{Exception.message(e)}"}
                end

              File.rm(entry.path)
              %{filename: entry.filename, result: result}
            end)

          send(parent, {:files_parsed, content, results})
        end)

      {:noreply,
       socket
       |> assign(:parsing_files, true)
       |> assign(:parsing_task_ref, task.ref)}
    end
  end

  defp do_send_message_with_display(submit_content, display_text, socket) do
    sid = socket.assigns.session_id

    {sid, socket} =
      if sid do
        {sid, socket}
      else
        {new_sid, sock} = ensure_session(socket, nil)
        sock = subscribe_and_hydrate(sock, new_sid)
        {new_sid, assign(sock, :session_id, new_sid)}
      end

    target_id = socket.assigns.active_tab

    user_msg = %{
      id: "user_#{System.unique_integer([:positive])}",
      role: :user,
      type: :text,
      content: display_text,
      agent_id: target_id
    }

    socket = SessionProjection.append_message(socket, user_msg)

    result =
      if target_id do
        case Rho.Agent.Worker.whereis(target_id) do
          nil -> {:error, "Agent not found"}
          pid -> Rho.Agent.Worker.submit(pid, submit_content)
        end
      else
        Rho.Session.submit(sid, submit_content)
      end

    case result do
      {:ok, _turn_id} ->
        pending_id = target_id || primary_agent_id(sid)
        pending = MapSet.put(socket.assigns.pending_response, pending_id)
        {:noreply, assign(socket, :pending_response, pending)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to send: #{inspect(reason)}")}
    end
  end

  defp build_file_context(file_results) do
    {summaries, images} =
      Enum.reduce(file_results, {[], []}, fn result, {summ, imgs} ->
        case result do
          %{filename: name, result: {:structured, %{sheets: sheets}}} ->
            sheet_info =
              Enum.map_join(sheets, "\n", fn s ->
                sample =
                  s.rows
                  |> Enum.take(3)
                  |> Enum.with_index(1)
                  |> Enum.map_join("\n", fn {row, i} ->
                    "  Row #{i}: #{Jason.encode!(row)}"
                  end)

                "  Sheet \"#{s.name}\": #{s.row_count} rows, #{length(s.columns)} columns (#{Enum.join(s.columns, ", ")})\n#{sample}"
              end)

            summary =
              "- #{name}:\n#{sheet_info}\n  Use get_uploaded_file(\"#{name}\") to read all rows."

            {[summary | summ], imgs}

          %{filename: name, result: {:text, text}} ->
            summary =
              "- #{name}: Extracted text (#{String.length(text)} chars). Prose content.\n  Use get_uploaded_file(\"#{name}\") to read full text."

            {[summary | summ], imgs}

          %{filename: _name, result: {:image, base64, media_type}} ->
            image_part =
              ReqLLM.Message.ContentPart.image(Base.decode64!(base64), media_type)

            {summ, [image_part | imgs]}

          %{filename: name, result: {:error, message}} ->
            summary = "- #{name}: ERROR — #{message}"
            {[summary | summ], imgs}

          _ ->
            {summ, imgs}
        end
      end)

    text =
      if summaries != [] do
        "[Uploaded files]\n" <> Enum.join(Enum.reverse(summaries), "\n")
      else
        ""
      end

    {text, Enum.reverse(images)}
  end

  defp ensure_session(socket, nil) do
    new_sid = "sheet_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Rho.Session.ensure_started(new_sid, agent_name: :spreadsheet)
    {new_sid, assign(socket, :session_id, new_sid)}
  end

  defp ensure_session(socket, sid) do
    {:ok, _pid} = Rho.Session.ensure_started(sid, agent_name: :spreadsheet)
    {sid, socket}
  end

  defp subscribe_and_hydrate(socket, session_id) do
    {:ok, sub1} = Rho.Comms.subscribe("rho.session.#{session_id}.events.*")
    {:ok, sub2} = Rho.Comms.subscribe("rho.agent.*")
    {:ok, sub3} = Rho.Comms.subscribe("rho.task.*")

    agents =
      Rho.Agent.Registry.list_all(session_id)
      |> Enum.map(fn info ->
        {info.agent_id,
         %{
           agent_id: info.agent_id,
           session_id: info.session_id,
           role: info.role,
           status: info.status,
           depth: info.depth,
           parent_id: info.parent_agent_id,
           capabilities: info.capabilities,
           model: nil,
           step: nil,
           max_steps: nil
         }}
      end)
      |> Map.new()

    primary_id = primary_agent_id(session_id)
    agent_ids = Map.keys(agents)
    tab_order = [primary_id | agent_ids -- [primary_id]]
    agent_messages = Map.new(agent_ids, fn id -> {id, []} end)

    # Register our pid so the Spreadsheet mount can find us
    Rho.Mounts.Spreadsheet.register(session_id, self())

    socket
    |> assign(:agents, agents)
    |> assign(:tab_order, tab_order)
    |> assign(:agent_messages, agent_messages)
    |> assign(:active_tab, primary_id)
    |> assign(:connected, true)
    |> assign(:bus_subs, [sub1, sub2, sub3])
  end

  defp unsubscribe_current(socket) do
    for sub <- socket.assigns[:bus_subs] || [] do
      Rho.Comms.unsubscribe(sub)
    end

    socket
  end

  defp signal_for_session?(data, session_id) do
    data_sid = data[:session_id] || data["session_id"]
    is_nil(data_sid) or data_sid == session_id
  end

  defp primary_agent_id(nil), do: nil
  defp primary_agent_id(session_id), do: "primary_#{session_id}"

  defp chat_status(assigns) do
    if MapSet.size(assigns.pending_response) > 0 or map_size(assigns.inflight) > 0 do
      :busy
    else
      :idle
    end
  end

  # --- Grouping helpers ---

  defp group_rows(rows_map) when map_size(rows_map) == 0, do: []

  defp group_rows(rows_map) do
    # Sort by ID (insertion order) to preserve streaming sequence
    rows_map
    |> Map.values()
    |> Enum.sort_by(& &1[:id])
    |> group_preserving_order()
  end

  # Groups rows by category → cluster while preserving the order of first appearance
  defp group_preserving_order(rows) do
    {categories, _seen} =
      Enum.reduce(rows, {[], %{}}, fn row, {cats, seen} ->
        cat = row[:category] || ""
        cluster = row[:cluster] || ""
        key = {cat, cluster}

        case Map.get(seen, key) do
          nil ->
            # First time seeing this category/cluster
            cat_entry =
              case List.keyfind(cats, cat, 0) do
                nil -> {cat, [{cluster, [row]}]}
                {^cat, clusters} -> {cat, clusters ++ [{cluster, [row]}]}
              end

            cats = List.keystore(cats, cat, 0, cat_entry)
            {cats, Map.put(seen, key, true)}

          _exists ->
            # Append row to existing cluster
            cats =
              Enum.map(cats, fn
                {^cat, clusters} ->
                  clusters =
                    Enum.map(clusters, fn
                      {^cluster, existing_rows} -> {cluster, existing_rows ++ [row]}
                      other -> other
                    end)

                  {cat, clusters}

                other ->
                  other
              end)

            {cats, seen}
        end
      end)

    categories
  end

  defp count_group_rows(clusters) do
    Enum.reduce(clusters, 0, fn {_cluster, rows}, acc -> acc + length(rows) end)
  end

  defp slug(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp slug(_), do: "unknown"

  # --- Upload UI helpers ---

  defp file_type_icon(mime_type) do
    cond do
      String.contains?(mime_type || "", "spreadsheet") or
          String.contains?(mime_type || "", "csv") ->
        "XLS"

      String.contains?(mime_type || "", "pdf") ->
        "PDF"

      String.starts_with?(mime_type || "", "image/") ->
        "IMG"

      true ->
        "FILE"
    end
  end

  defp humanize_upload_error(:too_large), do: "Too large (max 10MB)"
  defp humanize_upload_error(:not_accepted), do: "Type not supported"
  defp humanize_upload_error(:too_many_files), do: "Too many files (max 10)"
  defp humanize_upload_error(err), do: inspect(err)

  # --- Table data helpers ---

  @known_fields ~w(id category cluster skill_name skill_description level level_name level_description)

  defp atomize_keys(row) when is_map(row) do
    Map.new(row, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when k in @known_fields -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp assign_ids(rows, start_id) do
    {rows, next_id} =
      Enum.map_reduce(rows, start_id, fn row, id ->
        {Map.put(row, :id, id), id + 1}
      end)

    {rows, next_id}
  end

  defp filter_rows(rows, nil), do: rows
  defp filter_rows(rows, %{}), do: rows

  defp filter_rows(rows, filter) when is_map(filter) do
    Enum.filter(rows, fn row ->
      Enum.all?(filter, fn {k, v} ->
        key = if is_binary(k), do: String.to_existing_atom(k), else: k
        Map.get(row, key) == v
      end)
    end)
  end

  defp apply_cell_changes_to_map(rows_map, changes) do
    Enum.reduce(changes, rows_map, fn change, map ->
      id = change["id"]
      field = String.to_existing_atom(change["field"])
      value = change["value"]

      case Map.get(map, id) do
        nil -> map
        row -> Map.put(map, id, Map.put(row, field, value))
      end
    end)
  end

  defp get_changed_rows(rows_map, changes) do
    ids = MapSet.new(changes, & &1["id"])

    rows_map
    |> Enum.filter(fn {id, _row} -> MapSet.member?(ids, id) end)
    |> Enum.map(fn {_id, row} -> row end)
  end

  defp update_ui_message(socket, msg_id, spec, streaming?) do
    agent_messages = socket.assigns.agent_messages

    updated =
      Map.new(agent_messages, fn {agent_id, msgs} ->
        {agent_id,
         Enum.map(msgs, fn msg ->
           if msg.id == msg_id do
             %{msg | spec: spec, streaming: streaming?}
           else
             msg
           end
         end)}
      end)

    assign(socket, :agent_messages, updated)
  end

  @avatar_dir Path.expand("~/.rho")

  defp load_avatar(prefix) do
    path =
      Path.wildcard(Path.join(@avatar_dir, "#{prefix}.*"))
      |> Enum.find(&(Path.extname(&1) in ~w(.png .jpg .jpeg .gif .webp)))

    case path do
      nil ->
        nil

      path ->
        binary = File.read!(path)
        ext = Path.extname(path) |> String.trim_leading(".")

        media =
          case ext do
            "jpg" -> "image/jpeg"
            "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "gif" -> "image/gif"
            "webp" -> "image/webp"
            _ -> "image/png"
          end

        "data:#{media};base64,#{Base.encode64(binary)}"
    end
  rescue
    _ -> nil
  end
end
