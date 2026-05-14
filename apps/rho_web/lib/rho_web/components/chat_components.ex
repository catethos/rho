defmodule RhoWeb.ChatComponents do
  @moduledoc """
  Chat panel components: feed, message rows, tool call blocks, delegation cards.
  """
  use Phoenix.Component

  import RhoWeb.CoreComponents

  attr(:messages, :list, required: true)
  attr(:session_id, :string, required: true)
  attr(:inflight, :map, required: true)
  attr(:active_agent_id, :string, default: "")
  attr(:user_avatar, :string, default: nil)
  attr(:agent_avatar, :string, default: nil)
  attr(:pending, :boolean, default: false)
  attr(:active_step, :integer, default: nil)
  attr(:active_max_steps, :integer, default: nil)

  def chat_feed(assigns) do
    assigns = assign(assigns, :messages, normalize_messages(assigns.messages))

    ~H"""
    <div class="chat-feed" id={"chat-feed-#{@active_agent_id}"} phx-hook="AutoScroll">
      <div :if={@messages == [] and map_size(@inflight) == 0 and not @pending} class="chat-empty">
        <div class="empty-state">
          <div class="empty-state-icon">&#961;</div>
          <h2 class="empty-state-title">What can I help with?</h2>
          <p class="empty-state-hint">Send a message to get started</p>
        </div>
      </div>

      <div id={"messages-#{@active_agent_id}"}>
        <div :for={{msg, idx} <- Enum.with_index(@messages)} id={msg.id} class="message-wrapper">
          <.message_row message={msg} user_avatar={@user_avatar} agent_avatar={@agent_avatar} message_index={idx} />
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
              <span :if={@active_step} class="pending-step">step {@active_step}{if @active_max_steps, do: "/#{@active_max_steps}", else: ""}</span>
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
              <.envelope_preview :if={inflight[:envelope]} envelope={inflight.envelope} stream_id={agent_id} />
              <div style={if(inflight[:envelope], do: "display:none", else: "")}>
                <div
                  class="message-body"
                  id={"stream-body-#{agent_id}"}
                  phx-update="ignore"
                  phx-hook="StreamingText"
                >
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Normalizes persisted chat messages before render.

  Older snapshots can contain TypedStructured control-loop messages as plain
  assistant/user text. The reducer and trace projection now produce semantic
  tool rows, but this keeps already-saved UI snapshots from replaying raw JSON.
  """
  def normalize_messages(messages) when is_list(messages), do: do_normalize_messages(messages, [])
  def normalize_messages(_), do: []

  defp do_normalize_messages([], acc), do: Enum.reverse(acc)

  defp do_normalize_messages([msg, next | rest], acc) do
    case structured_tool_pair(msg, next) do
      {:tool_result, action, output} ->
        do_normalize_messages(rest, [tool_message(msg, action, output) | acc])

      :existing_tool_row ->
        do_normalize_messages(rest, normalize_message(next, acc))

      :none ->
        do_normalize_messages([msg], acc, [next | rest])
    end
  end

  defp do_normalize_messages([msg | rest], acc) do
    do_normalize_messages(rest, normalize_message(msg, acc))
  end

  defp do_normalize_messages([msg], acc, rest) do
    do_normalize_messages(rest, normalize_message(msg, acc))
  end

  defp normalize_message(msg, acc) do
    cond do
      assistant_text?(msg) or thinking_message?(msg) ->
        case structured_action(message_content(msg)) do
          {:ok, %{} = action} -> normalize_structured_action(msg, action, acc)
          _ -> [msg | acc]
        end

      tool_result_text?(message_content(msg)) ->
        {:ok, name, output} = tool_result_text(message_content(msg))
        [tool_result_message(msg, name, output) | acc]

      thought_noted?(message_content(msg)) ->
        acc

      true ->
        [msg | acc]
    end
  end

  defp normalize_structured_action(msg, action, acc) do
    case action_tool(action) do
      "respond" ->
        message = action["message"] || action["answer"] || ""

        if String.trim(to_string(message)) == "" do
          acc
        else
          [Map.merge(msg, %{type: :text, role: :assistant, content: to_string(message)}) | acc]
        end

      "think" ->
        acc

      tool when is_binary(tool) ->
        if thinking_message?(msg) do
          acc
        else
          [tool_message(msg, action, nil) | acc]
        end

      _ ->
        [msg | acc]
    end
  end

  defp structured_tool_pair(msg, next) do
    with true <- assistant_text?(msg) or thinking_message?(msg),
         {:ok, %{} = action} <- structured_action(message_content(msg)),
         tool when is_binary(tool) and tool not in ["respond", "think"] <- action_tool(action) do
      cond do
        match?({:ok, ^tool, _}, tool_result_text(message_content(next))) ->
          {:ok, _result_name, output} = tool_result_text(message_content(next))
          {:tool_result, action, output}

        next[:type] == :tool_call and next[:name] == tool ->
          :existing_tool_row

        true ->
          :none
      end
    else
      _ -> :none
    end
  end

  defp assistant_text?(msg), do: msg[:role] == :assistant and msg[:type] == :text
  defp thinking_message?(msg), do: msg[:role] == :assistant and msg[:type] == :thinking
  defp message_content(msg), do: msg[:content] || ""

  defp structured_action(content) when is_binary(content) do
    case Rho.StructuredOutput.parse(content) do
      {:ok, %{} = map} ->
        if action_tool(map), do: {:ok, map}, else: :error

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp structured_action(_), do: :error

  defp action_tool(map), do: map["tool"] || map["action"] || map["tool_name"] || map["name"]

  defp tool_message(msg, action, output) do
    name = action_tool(action)

    Map.merge(msg, %{
      role: :assistant,
      type: :tool_call,
      name: name,
      args: action["args"] || action["action_input"] || %{},
      status: if(is_nil(output), do: :pending, else: :ok),
      output: output,
      content: "Tool: #{name || "unknown"}"
    })
    |> Map.put_new(:call_id, "structured-#{msg[:id] || System.unique_integer([:positive])}")
  end

  defp tool_result_message(msg, name, output) do
    Map.merge(msg, %{
      role: :assistant,
      type: :tool_call,
      name: name,
      args: %{},
      status: :ok,
      output: output,
      content: "Tool result: #{name || "unknown"}"
    })
    |> Map.put_new(:call_id, "synthetic-result-#{msg[:id] || System.unique_integer([:positive])}")
  end

  @tool_result_prefix ~r/^\[Tool Result: ([^\]]+)\]\n?(.*)$/s

  defp tool_result_text?(content), do: match?({:ok, _, _}, tool_result_text(content))

  defp tool_result_text(content) when is_binary(content) do
    case Regex.run(@tool_result_prefix, content) do
      [_, name, output] -> {:ok, name, output}
      _ -> :error
    end
  end

  defp tool_result_text(_), do: :error

  defp thought_noted?(content) when is_binary(content),
    do: String.starts_with?(content, "[System] Thought noted.")

  defp thought_noted?(_), do: false

  attr(:message, :map, required: true)
  attr(:user_avatar, :string, default: nil)
  attr(:agent_avatar, :string, default: nil)
  attr(:message_index, :integer, default: nil)

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
          <% :welcome -> %>
            <.welcome_card content={@message.content} msg_id={@message.id} animation_key={@message[:animation_key]} />
          <% :error -> %>
            <div class="message-error">
              <span class="error-icon">!</span>
              <span class="error-text"><%= @message.content %></span>
            </div>
          <% _ -> %>
            <div class="message-text markdown-body" id={"md-#{@message.id}"} phx-hook="Markdown" data-md={@message.content}></div>
        <% end %>
      </div>
      <button
        :if={@message.role == :user and @message[:tape_entry_id]}
        class="btn-fork-from-here"
        phx-click="fork_from_here"
        phx-value-entry_id={@message.tape_entry_id}
        title="Fork conversation from here"
      >
        Fork
      </button>
      </div>
    </div>
    """
  end

  attr(:call, :map, required: true)

  def tool_call_row(assigns) do
    assigns =
      assign(assigns, :formatted_args, format_tool_args(assigns.call.name, assigns.call[:args]))

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

  attr(:delegation, :map, required: true)

  def delegation_card(assigns) do
    ~H"""
    <div class={"delegation-card delegation-#{@delegation[:status] || :pending}"}>
      <div class="delegation-header">
        <span class="delegation-icon">&#x2192;</span>
        <span>Delegated to <strong><%= @delegation[:target_role] || @delegation[:agent_id] %></strong></span>
        <span :if={@delegation[:status] == :pending && @delegation[:step]} class="delegation-step">
          step <%= @delegation[:step] %>/<%= @delegation[:max_steps] %>
        </span>
        <.status_dot status={@delegation[:status] || :pending} />
      </div>
      <div :if={@delegation[:task]} class="delegation-task"><%= @delegation.task %></div>
      <div :if={@delegation[:result]} class="delegation-result">
        <pre><%= truncate(@delegation.result, 500) %></pre>
      </div>
    </div>
    """
  end

  attr(:content, :string, required: true)
  attr(:msg_id, :string, required: true)

  def thinking_block(assigns) do
    parsed = parse_thinking(assigns.content)
    assigns = assign(assigns, :parsed, parsed)

    ~H"""
    <%= case @parsed do %>
      <% {:json, %{"tool" => "respond"} = map} -> %>
        <details :if={map["thinking"]} class="thinking-block">
          <summary class="thinking-summary">Thinking</summary>
          <div class="thinking-content">
            <div class="thinking-reasoning markdown-body"
              id={"think-md-#{@msg_id}"} phx-hook="Markdown" data-md={map["thinking"]}></div>
          </div>
        </details>
        <div class="message-text markdown-body"
          id={"think-answer-#{@msg_id}"} phx-hook="Markdown"
          data-md={map["message"] || ""}></div>
      <% {:json, map} -> %>
        <% action = map["action"] || map["tool"] %>
        <details :if={map["thinking"] || action} class="thinking-block">
          <summary class="thinking-summary">
            <%= truncate_summary(Map.get(map, "thinking")) || action || "Thinking" %>
          </summary>
          <div class="thinking-content">
            <div :if={map["thinking"]} class="thinking-reasoning markdown-body"
              id={"think-md-#{@msg_id}"} phx-hook="Markdown" data-md={map["thinking"]}></div>
            <div :if={action} class="thinking-action">
              <span class="thinking-label">Action:</span>
              <code><%= action %></code>
            </div>
          </div>
        </details>
      <% {:raw_json, count} -> %>
        <details class="thinking-block">
          <summary class="thinking-summary">Raw JSON array (<%= count %> items) — not a valid action envelope</summary>
          <div class="thinking-content">
            <div class="thinking-plain markdown-body"
              id={"think-txt-#{@msg_id}"} phx-hook="Markdown" data-md={"```json\n" <> @content <> "\n```"}></div>
          </div>
        </details>
      <% {:text, text} -> %>
        <details class="thinking-block">
          <summary class="thinking-summary">Thinking</summary>
          <div class="thinking-content">
            <div class="thinking-plain markdown-body"
              id={"think-txt-#{@msg_id}"} phx-hook="Markdown" data-md={text}></div>
          </div>
        </details>
    <% end %>
    """
  end

  attr(:content, :string, required: true)
  attr(:msg_id, :string, required: true)
  attr(:animation_key, :string, default: nil)

  def welcome_card(assigns) do
    assigns =
      assign(
        assigns,
        :resolved_animation_key,
        assigns.animation_key || "welcome:#{assigns.msg_id}"
      )

    ~H"""
    <div class="welcome-card" id={"welcome-#{@msg_id}"} tabindex="0">
      <div class="welcome-pill">
        <span class="welcome-pill-dot"></span>
        <span class="welcome-pill-label">Welcome</span>
      </div>
      <div
        class="welcome-body markdown-body"
        id={"welcome-md-#{@msg_id}"}
        phx-hook="WelcomeTypewriter"
        phx-update="ignore"
        data-welcome-key={@resolved_animation_key}
        data-md={@content}
      ></div>
      <span class="welcome-watermark" aria-hidden="true">&#961;</span>
    </div>
    """
  end

  attr(:message, :map, required: true)

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

  attr(:envelope, :map, required: true)
  attr(:stream_id, :string, required: true)

  @doc """
  Render of the in-flight assistant envelope while it streams in. Replaces
  the raw streaming JSON text in the chat bubble with a structured view:

    * `thinking` — shown as muted markdown-rendered prose.
    * `respond` — shown as the visible assistant prose, markdown-rendered.
    * any other action — shown as a "Calling <tool>" chip.

  Uses the existing `Markdown` JS hook (via `window.marked` + DOMPurify)
  so content renders with the same fidelity as finalized messages.
  Rendered on every re-assign of `inflight`, so the markdown output
  updates as new chunks arrive.
  """
  def envelope_preview(assigns) do
    ~H"""
    <div class="envelope-preview" style="font-size:0.875rem;line-height:1.65;color:var(--text-primary);">
      <div :if={@envelope[:thinking]}
        class="envelope-thinking markdown-body"
        id={"env-think-#{@stream_id}"}
        phx-hook="Markdown"
        data-md={to_string(@envelope.thinking)}
        style="color:var(--text-secondary);font-size:0.8125rem;margin-bottom:0.5rem;opacity:0.8;">
      </div>
      <%= cond do %>
        <% @envelope[:action] == "respond" -> %>
          <div class="envelope-answer markdown-body"
            id={"env-answer-#{@stream_id}"}
            phx-hook="Markdown"
            data-md={@envelope[:message] || ""}>
          </div>
        <% is_binary(@envelope[:action]) -> %>
          <div class="envelope-action">
            <span class="envelope-action-label" style="color:var(--text-secondary);">Calling</span>
            <code class="envelope-action-name"><%= @envelope.action %></code>
          </div>
        <% true -> %>
      <% end %>
    </div>
    """
  end

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

  defp format_tool_args(_tool_name, args) when is_map(args) do
    {inner_parts, rest} = RhoWeb.ArgFormatter.extract_inner_json(args)

    rest_part =
      if rest == %{}, do: [], else: [{nil, Jason.encode!(rest, pretty: true), nil}]

    case inner_parts ++ rest_part do
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

  defp truncate(text, max_value) when byte_size(text) > max_value do
    String.slice(text, 0, max_value) <> "\n…(truncated)"
  end

  defp truncate(text, _max_value), do: text

  @image_pattern ~r/!\[.*?\]\((data:image\/[^;]+;base64,[A-Za-z0-9+\/=]+)\)/
  @file_image_pattern ~r/\[Plot saved: ([^\]]+\.png)\]/

  @doc "Extract data URIs from markdown image tags or file-based plot references in text."
  def extract_image_uris(text) when is_binary(text) do
    inline = Regex.scan(@image_pattern, text) |> Enum.map(fn [_full, uri] -> uri end)

    from_files =
      Regex.scan(@file_image_pattern, text)
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
    combined =
      ~r/!\[.*?\]\(data:image\/[^;]+;base64,[A-Za-z0-9+\/=]+\)|\[Plot saved: [^\]]+\.png\]/

    parts = Regex.split(combined, output, include_captures: true, trim: true)

    Enum.map(parts, &classify_image_part/1)
    |> Enum.reject(fn
      {:text, t} -> String.trim(t) == ""
      _ -> false
    end)
  end

  defp split_image_segments(_), do: []

  defp classify_image_part(part) do
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
  end

  defp truncate_summary(nil), do: nil

  defp truncate_summary(text) do
    if String.length(text) > 80, do: String.slice(text, 0, 80) <> "...", else: text
  end

  defp parse_thinking(content) do
    # Use StructuredOutput.parse — it includes brace-scan extraction, so
    # `{valid json}<trailing prose>` responses still surface as `:json`
    # and render as a proper respond envelope rather than dumping
    # the raw stream (including duplicated thinking text) into the UI.
    case Rho.StructuredOutput.parse(content) do
      {:ok, map} when is_map(map) -> {:json, normalize_thinking_key(map)}
      {:ok, list} when is_list(list) -> {:raw_json, length(list)}
      _ -> {:text, content}
    end
  end

  # The think action uses "thought", but the UI renders "thinking".
  # Normalize so downstream rendering is consistent.
  defp normalize_thinking_key(%{"thought" => thought} = map) when is_binary(thought) do
    map
    |> Map.delete("thought")
    |> Map.put_new("thinking", thought)
  end

  defp normalize_thinking_key(map), do: map
end
