defmodule RhoWeb.Session.WelcomeTest do
  use ExUnit.Case, async: true

  alias RhoWeb.Session.Welcome

  defp socket(assigns) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            session_id: "welcome_test_session",
            active_agent_id: "welcome_test_session/primary",
            agents: %{},
            agent_messages: %{},
            chat_context: %{},
            inflight: %{},
            signals: [],
            ui_streams: %{},
            debug_projections: %{},
            selected_agent_id: nil,
            total_input_tokens: 0,
            total_output_tokens: 0,
            total_cost: 0.0,
            total_cached_tokens: 0,
            total_reasoning_tokens: 0,
            step_input_tokens: 0,
            step_output_tokens: 0,
            next_id: 1
          },
          assigns
        )
    }
  end

  test "renders spreadsheet welcome for a primary agent selected as spreadsheet" do
    agent_id = "welcome_test_session/primary"

    socket =
      socket(%{
        agents: %{agent_id => %{role: :primary, agent_name: :spreadsheet}},
        agent_messages: %{
          agent_id => [
            %{id: "tape-1", role: :system, type: :anchor, content: "Session started."}
          ]
        }
      })

    socket = Welcome.maybe_render(socket)

    assert [
             %{type: :anchor},
             %{role: :assistant, type: :welcome, content: content, animation_key: animation_key}
           ] = socket.assigns.agent_messages[agent_id]

    assert content =~ "framework"
    assert animation_key == "welcome:welcome_test_session:welcome_test_session/primary"
  end

  test "does not render spreadsheet welcome for the general agent" do
    agent_id = "welcome_test_session/primary"

    socket =
      socket(%{
        agents: %{agent_id => %{role: :primary, agent_name: :default}},
        agent_messages: %{agent_id => []}
      })

    socket = Welcome.maybe_render(socket)

    assert socket.assigns.agent_messages[agent_id] == []
  end

  test "re-renders spreadsheet welcome when an empty chat is reopened" do
    agent_id = "welcome_test_session/primary"

    socket =
      socket(%{
        agents: %{agent_id => %{role: :primary, agent_name: :spreadsheet}},
        agent_messages: %{
          agent_id => [
            %{id: "tape-1", role: :system, type: :anchor, content: "Session started."}
          ]
        }
      })

    socket = Welcome.render_for_active_agent(socket)

    assert [
             %{type: :anchor},
             %{role: :assistant, type: :welcome, content: content, animation_key: animation_key}
           ] = socket.assigns.agent_messages[agent_id]

    assert content =~ "framework"
    assert animation_key == "welcome:welcome_test_session:welcome_test_session/primary"
  end
end
