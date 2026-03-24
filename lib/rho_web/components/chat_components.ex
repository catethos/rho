defmodule RhoWeb.ChatComponents do
  @moduledoc """
  Chat panel components: feed, message rows, tool call blocks, delegation cards.
  """
  use Phoenix.Component

  import RhoWeb.CoreComponents

  attr :messages, :list, required: true
  attr :session_id, :string, required: true
  attr :inflight, :map, required: true
  attr :active_tab, :string, default: ""
  attr :user_avatar, :string, default: nil
  attr :agent_avatar, :string, default: nil
  attr :pending, :boolean, default: false

  def chat_feed(assigns) do
    ~H"""
    <div class="chat-feed" id={"chat-feed-#{@active_tab}"} phx-hook="AutoScroll">
      <div :if={@messages == [] and map_size(@inflight) == 0 and not @pending} class="chat-empty">
        <div class="empty-state">
          <div class="empty-state-icon">&#961;</div>
          <h2 class="empty-state-title">What can I help with?</h2>
          <p class="empty-state-hint">Send a message to get started</p>
        </div>
      </div>

      <div id={"messages-#{@active_tab}"}>
        <div :for={msg <- @messages} id={msg.id} class="message-wrapper">
          <.message_row message={msg} user_avatar={@user_avatar} agent_avatar={@agent_avatar} />
        </div>
      </div>

      <div :if={@pending and map_size(@inflight) == 0} class="message-wrapper">
        <div class="message message-assistant">
          <%= if @agent_avatar do %>
            <img src={@agent_avatar} class="message-avatar avatar-assistant avatar-img" />
          <% else %>
            <div class="message-avatar avatar-assistant">R</div>
          <% end %>
          <div class="message-content">
            <div class="message-body pending-indicator">
              <span class="pending-dots"><span>.</span><span>.</span><span>.</span></span>
            </div>
          </div>
        </div>
      </div>

      <div :for={{agent_id, inflight} <- @inflight} id={"streaming-#{agent_id}"}>
        <div class="message-wrapper">
          <div class="message message-assistant streaming">
            <%= if @agent_avatar do %>
              <img src={@agent_avatar} class="message-avatar avatar-assistant avatar-img" title={inflight.agent_id} />
            <% else %>
              <div class="message-avatar avatar-assistant" title={inflight.agent_id}>R</div>
            <% end %>
            <div class="message-content">
              <div class="message-body" id={"stream-body-#{agent_id}"} phx-update="ignore" phx-hook="StreamingText">
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :message, :map, required: true
  attr :user_avatar, :string, default: nil
  attr :agent_avatar, :string, default: nil

  def message_row(assigns) do
    ~H"""
    <div class={"message message-#{@message.role} #{if @message[:from_agent], do: "message-from-agent", else: ""}"}>
      <%= cond do %>
        <% @message[:from_agent] -> %>
          <div class="message-avatar avatar-agent-msg" title={"From #{@message.from_agent}"}>
            <%= String.first(to_string(@message.from_agent)) |> String.upcase() %>
          </div>
        <% @message.role == :user and @user_avatar != nil -> %>
          <img src={@user_avatar} class="message-avatar avatar-user avatar-img" />
        <% @message.role != :user and @agent_avatar != nil -> %>
          <img src={@agent_avatar} class="message-avatar avatar-assistant avatar-img" />
        <% true -> %>
          <div class={"message-avatar avatar-#{@message.role}"}>
            <%= if @message.role == :user, do: "Y", else: "R" %>
          </div>
      <% end %>
      <div class="message-content">
      <%= if @message[:from_agent] do %>
        <div class="message-sender-label">from <strong><%= @message.from_agent %></strong></div>
      <% end %>
      <div class="message-body">
        <%= case @message.type do %>
          <% :tool_call -> %>
            <.tool_call_row call={@message} />
          <% :thinking -> %>
            <.thinking_block content={@message.content} msg_id={@message.id} />
          <% :delegation -> %>
            <.delegation_card delegation={@message} />
          <% :image -> %>
            <div class="message-images">
              <img :for={src <- @message.images} src={src} style="max-width:100%;border-radius:6px;margin:8px 0;" />
            </div>
          <% :ui -> %>
            <.ui_block message={@message} />
          <% :error -> %>
            <div class="message-error">
              <span class="error-icon">!</span>
              <span class="error-text"><%= @message.content %></span>
            </div>
          <% _ -> %>
            <div class="message-text markdown-body" id={"md-#{@message.id}"} phx-hook="Markdown" data-md={@message.content}></div>
        <% end %>
      </div>
      </div>
    </div>
    """
  end

  attr :call, :map, required: true

  def tool_call_row(assigns) do
    assigns = assign(assigns, :formatted_args, format_tool_args(assigns.call.name, assigns.call[:args]))

    ~H"""
    <details class="tool-call">
      <summary class="tool-call-summary">
        <span class={"tool-status tool-status-#{@call[:status] || :pending}"}>
          <%= tool_icon(@call[:status]) %>
        </span>
        <span class="tool-name"><%= @call.name %></span>
      </summary>
      <div class="tool-call-detail">
        <div :if={@call[:args]} class="tool-args">
          <%= for {label, code, lang} <- @formatted_args do %>
            <div :if={label} class="tool-args-label" style="font-size:0.6875rem;color:var(--text-secondary);margin-bottom:0.25rem;margin-top:0.5rem;"><%= label %></div>
            <pre class={"tool-args-code#{if lang, do: " language-#{lang}", else: ""}"}><%= code %></pre>
          <% end %>
        </div>
        <div :if={@call[:output]} class="tool-output">
          <%= for segment <- split_image_segments(@call.output) do %>
            <%= case segment do %>
              <% {:image, data_uri} -> %>
                <img src={data_uri} class="tool-output-image" style="max-width:100%;border-radius:6px;margin:8px 0;" />
              <% {:text, text} -> %>
                <pre><%= truncate(text, 2000) %></pre>
            <% end %>
          <% end %>
        </div>
      </div>
    </details>
    """
  end

  attr :delegation, :map, required: true

  def delegation_card(assigns) do
    ~H"""
    <div class={"delegation-card delegation-#{@delegation[:status] || :pending}"}>
      <div class="delegation-header">
        <span class="delegation-icon">&#x2192;</span>
        <span>Delegated to <strong><%= @delegation[:target_role] || @delegation[:agent_id] %></strong></span>
        <.status_dot status={@delegation[:status] || :pending} />
      </div>
      <div :if={@delegation[:task]} class="delegation-task"><%= @delegation.task %></div>
      <div :if={@delegation[:result]} class="delegation-result">
        <pre><%= truncate(@delegation.result, 500) %></pre>
      </div>
    </div>
    """
  end

  attr :content, :string, required: true
  attr :msg_id, :string, required: true

  def thinking_block(assigns) do
    parsed = parse_thinking(assigns.content)
    assigns = assign(assigns, :parsed, parsed)

    ~H"""
    <details class="thinking-block">
      <summary class="thinking-summary">
        <%= case @parsed do %>
          <% {:json, map} -> %>
            <%= truncate_summary(Map.get(map, "thinking")) || Map.get(map, "action", "Thinking") %>
          <% {:text, _} -> %>
            Thinking
        <% end %>
      </summary>
      <div class="thinking-content">
        <%= case @parsed do %>
          <% {:json, map} -> %>
            <div :if={map["thinking"]} class="thinking-reasoning markdown-body"
              id={"think-md-#{@msg_id}"} phx-hook="Markdown" data-md={map["thinking"]}></div>
            <div :if={map["action"]} class="thinking-action">
              <span class="thinking-label">Action:</span>
              <code><%= map["action"] %></code>
            </div>
            <pre :if={map["action_input"]} class="thinking-args"
              id={"think-json-#{@msg_id}"} phx-hook="JsonPretty"
              data-json={Jason.encode!(map["action_input"])}></pre>
          <% {:text, text} -> %>
            <div class="thinking-plain markdown-body"
              id={"think-txt-#{@msg_id}"} phx-hook="Markdown" data-md={text}></div>
        <% end %>
      </div>
    </details>
    """
  end

  attr :message, :map, required: true

  def ui_block(assigns) do
    ~H"""
    <div class="ui-block">
      <div :if={@message[:title]} class="ui-block-title"><%= @message.title %></div>
      <%= if valid_spec?(@message[:spec]) do %>
        <div data-lr-ui>
          <LiveRender.render
            spec={@message.spec}
            catalog={LiveRender.StandardCatalog}
            streaming={@message[:streaming] || false}
            id={"lr-#{@message.id}"}
          />
        </div>
      <% else %>
        <div class="ui-block-fallback">
          <details>
            <summary>UI render error — click to see raw spec</summary>
            <pre><%= Jason.encode!(@message[:spec] || %{}, pretty: true) %></pre>
          </details>
        </div>
      <% end %>
    </div>
    """
  end

  defp valid_spec?(nil), do: false
  defp valid_spec?(spec) when is_map(spec) do
    is_binary(spec["root"]) and is_map(spec["elements"])
  end
  defp valid_spec?(_), do: false

  defp tool_icon(:ok), do: "✓"
  defp tool_icon(:error), do: "✗"
  defp tool_icon(_), do: "⋯"

  # Format tool args with special handling for tools with code fields
  defp format_tool_args(tool_name, args) when is_map(args) and tool_name in ["python", "bash"] do
    code = args["code"] || args[:code] || args["command"] || args[:command]
    rest = args |> Map.drop(["code", :code, "command", :command])

    code_parts = if code, do: [{nil, code, tool_name}], else: []
    rest_parts = if rest != %{}, do: [{nil, Jason.encode!(rest, pretty: true), nil}], else: []

    case code_parts ++ rest_parts do
      [] -> [{nil, format_args(args), nil}]
      parts -> parts
    end
  end

  defp format_tool_args(_tool_name, args) do
    [{nil, format_args(args), nil}]
  end

  defp format_args(args) when is_map(args), do: Jason.encode!(args, pretty: true)
  defp format_args(args) when is_binary(args), do: args
  defp format_args(args), do: inspect(args)

  defp truncate(text, max) when byte_size(text) > max do
    String.slice(text, 0, max) <> "\n…(truncated)"
  end
  defp truncate(text, _max), do: text

  @image_pattern ~r/!\[.*?\]\((data:image\/[^;]+;base64,[A-Za-z0-9+\/=]+)\)/
  @file_image_pattern ~r/\[Plot saved: ([^\]]+\.png)\]/

  @doc "Extract data URIs from markdown image tags or file-based plot references in text."
  def extract_image_uris(text) when is_binary(text) do
    inline = Regex.scan(@image_pattern, text) |> Enum.map(fn [_full, uri] -> uri end)
    from_files = Regex.scan(@file_image_pattern, text)
      |> Enum.flat_map(fn [_full, path] ->
        case File.read(path) do
          {:ok, data} -> ["data:image/png;base64," <> Base.encode64(data)]
          _ -> []
        end
      end)
    inline ++ from_files
  end
  def extract_image_uris(_), do: []

  defp split_image_segments(output) when is_binary(output) do
    # Combined pattern for both inline base64 and file-based images
    combined = ~r/!\[.*?\]\(data:image\/[^;]+;base64,[A-Za-z0-9+\/=]+\)|\[Plot saved: [^\]]+\.png\]/

    parts = Regex.split(combined, output, include_captures: true, trim: true)

    Enum.map(parts, fn part ->
      cond do
        match = Regex.run(@image_pattern, part) ->
          [_full, data_uri] = match
          {:image, data_uri}

        match = Regex.run(@file_image_pattern, part) ->
          [_full, path] = match
          case File.read(path) do
            {:ok, data} -> {:image, "data:image/png;base64," <> Base.encode64(data)}
            _ -> {:text, part}
          end

        true ->
          {:text, part}
      end
    end)
    |> Enum.reject(fn
      {:text, t} -> String.trim(t) == ""
      _ -> false
    end)
  end

  defp split_image_segments(_), do: []

  defp truncate_summary(nil), do: nil
  defp truncate_summary(text) do
    if String.length(text) > 80, do: String.slice(text, 0, 80) <> "...", else: text
  end

  defp parse_thinking(content) do
    case Jason.decode(content) do
      {:ok, map} when is_map(map) -> {:json, map}
      _ -> {:text, content}
    end
  end
end
