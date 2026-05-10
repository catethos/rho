defmodule RhoWeb.Session.Welcome do
  @moduledoc """
  Empty-state greeting for the spreadsheet agent.

  When a fresh chat session opens against the `:spreadsheet` agent with
  no prior messages and no chat-context intent, this module appends a
  templated assistant message that lists the user's saved libraries and
  the available capabilities. No LLM turn is consumed.

  Idempotent: re-renders on remount only when the chat is genuinely
  empty (no replayed events, no snapshot to restore).
  """

  alias RhoFrameworks.Library
  alias RhoWeb.Session.SignalRouter

  @doc """
  Append the welcome message for the active agent when conditions match.

  Used from `mount/3` after hydrate. Includes a session-level EventLog
  check so we don't stomp a resumed session that has activity but no
  snapshot. Skips silently otherwise.
  """
  def maybe_render(socket) do
    agent_id = socket.assigns[:active_agent_id]

    if agent_id != nil and
         spreadsheet?(socket.assigns[:agents], agent_id) and
         empty_messages?(socket.assigns[:agent_messages], agent_id) and
         empty_chat_context?(socket.assigns[:chat_context]) and
         empty_event_log?(socket.assigns[:session_id]) do
      do_render(socket, agent_id)
    else
      socket
    end
  end

  @doc """
  Append the welcome message for an agent we just spawned.

  Used from the `create_agent` handler. The caller has already verified
  the agent is brand-new, so the session-level EventLog check is
  skipped (other agents in the same session may have prior activity).
  """
  def render_for_new_agent(socket, agent_id) do
    if agent_id != nil and
         spreadsheet?(socket.assigns[:agents], agent_id) and
         empty_messages?(socket.assigns[:agent_messages], agent_id) do
      do_render(socket, agent_id)
    else
      socket
    end
  end

  defp empty_event_log?(nil), do: false

  defp empty_event_log?(session_id) when is_binary(session_id) do
    case Rho.Agent.EventLog.read(session_id, limit: 1) do
      {[], _} -> true
      _ -> false
    end
  end

  defp spreadsheet?(%{} = agents, agent_id) do
    case Map.get(agents, agent_id) do
      %{role: :spreadsheet} -> true
      _ -> false
    end
  end

  defp spreadsheet?(_, _), do: false

  defp empty_messages?(%{} = agent_messages, agent_id) do
    case Map.get(agent_messages, agent_id) do
      [] -> true
      nil -> true
      _ -> false
    end
  end

  defp empty_messages?(_, _), do: true

  defp empty_chat_context?(nil), do: true
  defp empty_chat_context?(ctx) when is_map(ctx), do: map_size(ctx) == 0
  defp empty_chat_context?(_), do: true

  defp do_render(socket, agent_id) do
    org_id = get_in(socket.assigns, [:current_organization, Access.key(:id)])

    libraries =
      case org_id do
        nil -> []
        id -> Library.list_libraries(id)
      end

    msg = %{
      id: "welcome_#{System.unique_integer([:positive])}",
      role: :assistant,
      type: :welcome,
      content: render_text(libraries),
      agent_id: agent_id
    }

    SignalRouter.append_message(socket, msg)
  end

  defp render_text([]) do
    Enum.random(empty_variants()) |> String.trim()
  end

  defp render_text(libraries) do
    bullets =
      libraries
      |> Enum.map(&format_bullet/1)
      |> Enum.join("\n")

    populated_variants(bullets)
    |> Enum.random()
    |> String.trim()
  end

  defp empty_variants do
    [
      """
      Hi! I'm the skill framework editor. Your org doesn't have any saved libraries yet — let's build one. I can:

      1. **Create a new framework** from scratch (or seeded by similar role profiles)
      2. **Import a framework** from an Excel/CSV file or a built-in template (sfia_v8)

      What would you like to do?
      """,
      """
      Hey — looks like a blank slate. Nothing saved for your org yet, so we're starting from zero. Two quick paths:

      - **Build one from scratch** — I can scaffold a framework around a role or domain you describe
      - **Import one** — drop in an .xlsx or .csv, or use a built-in template like SFIA v8

      Which sounds right?
      """,
      """
      Welcome. Your org has no skill libraries yet. To get started I can:

      - Create a new framework (from scratch, or seeded by a similar role)
      - Import from a file (.xlsx, .csv) or a built-in template (sfia_v8)

      What's the goal?
      """
    ]
  end

  defp populated_variants(bullets) do
    [
      """
      Hi! Here's what's saved in your org:

      #{bullets}

      I can:
      1. **Load** one of these to view or edit
      2. **Create a new framework** (from scratch, similar-role-seeded, or using one of these as reference)
      3. **Import a framework** from an Excel/CSV file or a built-in template (sfia_v8)
      4. **Combine** two or more libraries into a new one
      5. **Set the default version** of a published library

      What would you like to do?
      """,
      """
      Hey! Quick look at what your org has on hand:

      #{bullets}

      A few directions we could take:
      - Open one to **view or edit**
      - **Build a new framework** (from scratch, seeded from similar roles, or using one of these as reference)
      - **Import** from .xlsx or .csv, or a built-in template (sfia_v8)
      - **Merge** two or more into a new library
      - Promote a draft to **published**, or change which version is the **default**

      What sounds useful?
      """,
      """
      Welcome back. Your library shelf:

      #{bullets}

      Common moves from here:
      1. **Load** one to edit
      2. **Spin up a new framework** — scratch, similar-role-seeded, or referencing an existing one
      3. **Import** from a file (.xlsx, .csv) or a template (sfia_v8)
      4. **Combine** several into one
      5. **Publish** a draft as a new version, or **set a default**

      Where to?
      """
    ]
  end

  defp format_bullet(lib) do
    version = if lib.version, do: "v#{lib.version}", else: "draft"
    flags = if lib.immutable, do: ", immutable", else: ""
    "- **#{lib.name}** — #{lib.skill_count} skills, #{version}#{flags}"
  end
end
