defmodule RhoWeb.AppLive.MessageEvents do
  @moduledoc """
  Event handlers for AppLive message submission and upload parsing.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [cancel_upload: 3, consume_uploaded_entries: 3]

  require Logger

  alias Rho.Stdlib.Uploads
  alias RhoWeb.AppLive
  alias RhoWeb.Session.SessionCore

  @inline_total_preview_chars 16000

  def handle_event("send_message", %{"content" => content}, socket) do
    content = String.trim(content)

    image_parts =
      consume_uploaded_entries(socket, :images, fn %{path: path}, entry ->
        binary = File.read!(path)
        media_type = entry.client_type || "image/png"
        {:ok, ReqLLM.Message.ContentPart.image(binary, media_type)}
      end)

    has_images = image_parts != []
    has_text = content != ""
    has_pending_files = socket.assigns.uploads.files.entries != []

    if not has_text and not has_images and not has_pending_files do
      {:noreply, socket}
    else
      {sid, socket, created?} = ensure_message_session(socket)
      socket = AppLive.maybe_push_new_session_patch(socket, sid, created?)
      {:ok, _pid} = Uploads.ensure_started(sid)

      file_handles =
        consume_uploaded_entries(socket, :files, fn %{path: tmp_path}, entry ->
          case Uploads.put(sid, %{
                 filename: entry.client_name,
                 mime: entry.client_type || "application/octet-stream",
                 tmp_path: tmp_path,
                 size: entry.client_size
               }) do
            {:ok, handle} -> {:ok, handle}
            {:error, reason} -> {:postpone, {:error, reason, entry.client_name}}
          end
        end)

      if file_handles == [] do
        submit_to_session(socket, content, image_parts, has_text)
      else
        arm_parse_tasks(socket, content, image_parts, has_text, file_handles)
      end
    end
  end

  def handle_event("validate_upload", _params, socket) do
    {:noreply, maybe_consume_avatar(socket)}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :images, ref)}
  end

  def handle_event("cancel_file", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :files, ref)}
  end

  def handle_info({ref, {handle, parse_result}}, socket) when is_reference(ref) do
    case socket.assigns.files_parsing do
      %{^ref => _} ->
        Process.demonitor(ref, [:flush])
        parsing = Map.delete(socket.assigns.files_parsing, ref)
        pending = socket.assigns.files_pending_send
        observations = Map.put(pending.observations, handle.id, {handle, parse_result})

        socket =
          socket
          |> assign(:files_parsing, parsing)
          |> assign(:files_pending_send, %{pending | observations: observations})

        if parsing == %{} do
          submit_with_uploads(socket)
        else
          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) when is_reference(ref) do
    case Map.pop(socket.assigns.files_parsing, ref) do
      {nil, _} ->
        {:noreply, socket}

      {%{handle_id: hid, filename: fname}, parsing} ->
        Logger.warning("Upload parse task crashed for #{fname}: #{inspect(reason)}")
        pending = socket.assigns.files_pending_send
        crash_result = {:error, {:parse_crashed, reason}}

        synth_handle = %Uploads.Handle{
          id: hid,
          filename: fname,
          session_id: socket.assigns.session_id
        }

        observations = Map.put(pending.observations, hid, {synth_handle, crash_result})

        socket =
          socket
          |> assign(:files_parsing, parsing)
          |> assign(:files_pending_send, %{pending | observations: observations})

        if parsing == %{} do
          submit_with_uploads(socket)
        else
          {:noreply, socket}
        end
    end
  end

  defp ensure_message_session(socket) do
    if socket.assigns.session_id do
      {socket.assigns.session_id, socket, false}
    else
      ensure_opts = AppLive.session_ensure_opts(socket.assigns.live_action)
      {new_sid, socket} = SessionCore.ensure_session(socket, nil, ensure_opts)
      socket = SessionCore.subscribe_and_hydrate(socket, new_sid, ensure_opts)
      {new_sid, socket, true}
    end
  end

  defp submit_to_session(socket, content, image_parts, has_text) do
    submit_content = build_submit_content(content, image_parts, has_text)
    display_text = build_display_text(content, image_parts, has_text)

    case SessionCore.send_message(socket, display_text, submit_content: submit_content) do
      {:noreply, socket} ->
        AppLive.touch_active_conversation(socket)
        {:noreply, AppLive.refresh_conversations(socket)}
    end
  end

  defp arm_parse_tasks(socket, content, image_parts, has_text, file_handles) do
    sid = socket.assigns.session_id

    {parse_handles, stored_handles} =
      Enum.split_with(file_handles, &Uploads.Observer.parse_now?(&1.path))

    stored_observations =
      stored_handles
      |> Enum.map(fn handle ->
        {handle.id, {handle, Uploads.Observer.observe(sid, handle.id)}}
      end)
      |> Map.new()

    parsing =
      parse_handles
      |> Enum.map(fn handle ->
        task =
          Task.Supervisor.async_nolink(Rho.TaskSupervisor, fn ->
            result = Uploads.Observer.observe(sid, handle.id)
            {handle, result}
          end)

        {task.ref, %{filename: handle.filename, handle_id: handle.id}}
      end)
      |> Map.new()

    pending = %{
      content: content,
      image_parts: image_parts,
      has_text: has_text,
      file_handles: file_handles,
      observations: stored_observations
    }

    socket = socket |> assign(:files_parsing, parsing) |> assign(:files_pending_send, pending)

    if parsing == %{} do
      submit_with_uploads(socket)
    else
      {:noreply, socket}
    end
  end

  defp submit_with_uploads(socket) do
    pending = socket.assigns.files_pending_send

    enriched_text =
      build_enriched_message(pending.content, pending.observations, pending.file_handles)

    enriched_has_text = enriched_text != ""
    socket = assign(socket, :files_pending_send, nil)
    submit_to_session(socket, enriched_text, pending.image_parts, enriched_has_text)
  end

  defp build_enriched_message(content, observations, file_handles) do
    {blocks, _remaining} =
      Enum.map_reduce(file_handles, @inline_total_preview_chars, fn handle, remaining ->
        case Map.get(observations, handle.id) do
          {^handle, {:ok, obs}} ->
            render_upload_block(handle, obs, remaining)

          {_handle, {:ok, obs}} ->
            render_upload_block(handle, obs, remaining)

          {_handle, {:error, reason}} ->
            {"[Upload error: #{handle.filename}: #{format_parse_error(reason)}]", remaining}

          nil ->
            {"[Upload error: #{handle.filename}: missing parse result]", remaining}
        end
      end)

    blocks = Enum.join(blocks, "\n\n")

    if content == "" do
      blocks
    else
      content <> "\n\n" <> blocks
    end
  end

  defp render_upload_block(handle, %{kind: :prose_text, summary_text: text}, remaining) do
    {head, preview} = split_preview_block(text)

    cond do
      preview == nil ->
        {text <> "\n[upload_id: #{handle.id}]", remaining}

      remaining <= 0 ->
        {head <> "\n[upload_id: #{handle.id}]", remaining}

      true ->
        preview_len = String.length(preview)
        visible = String.slice(preview, 0, remaining)

        suffix =
          if preview_len > remaining do
            "\n[Preview truncated.]"
          else
            ""
          end

        block =
          head <>
            "\n\n--- Document preview ---\n" <>
            visible <>
            suffix <>
            "\n--- End preview ---\n[upload_id: #{handle.id}]"

        {block, max(remaining - preview_len, 0)}
    end
  end

  defp render_upload_block(handle, %{summary_text: text}, remaining) do
    {text <> "\n[upload_id: #{handle.id}]", remaining}
  end

  defp split_preview_block(text) do
    case String.split(text, "\n\n--- Document preview ---\n", parts: 2) do
      [head, rest] ->
        case String.split(rest, "\n--- End preview ---", parts: 2) do
          [preview, _tail] -> {head, preview}
          _ -> {text, nil}
        end

      _ ->
        {text, nil}
    end
  end

  defp format_parse_error(:parse_timeout), do: "parsing exceeded 15s"

  defp format_parse_error({:parse_crashed, reason}) do
    "parser crashed (#{inspect(reason)})"
  end

  defp format_parse_error({:io_error, reason}) do
    "I/O error (#{inspect(reason)})"
  end

  defp format_parse_error(other), do: inspect(other)

  defp build_submit_content(content, image_parts, has_text) do
    if image_parts != [] do
      parts =
        if has_text do
          [ReqLLM.Message.ContentPart.text(content)]
        else
          []
        end

      parts ++ image_parts
    else
      content
    end
  end

  defp build_display_text(content, image_parts, has_text) do
    if image_parts != [] do
      img_label =
        "#{length(image_parts)} image#{if match?([_, _ | _], image_parts) do
          "s"
        end}"

      if has_text do
        "#{content}\n[#{img_label} attached]"
      else
        "[#{img_label} attached]"
      end
    else
      content
    end
  end

  defp maybe_consume_avatar(socket) do
    entry = List.first(socket.assigns.uploads.avatar.entries)

    if entry && entry.done? do
      [{binary, media_type}] =
        consume_uploaded_entries(socket, :avatar, fn %{path: path}, entry ->
          {:ok, {File.read!(path), entry.client_type || "image/png"}}
        end)

      SessionCore.save_user_avatar(socket, binary, media_type)
      data_uri = "data:#{media_type};base64,#{Base.encode64(binary)}"
      assign(socket, :user_avatar, data_uri)
    else
      socket
    end
  end
end
