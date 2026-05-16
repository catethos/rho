defmodule RhoWeb.ChatComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RhoWeb.ChatComponents
  alias RhoWeb.FlowChat.{Action, Message}

  test "normalize_messages converts persisted typed structured tool text to a tool row" do
    messages = [
      %{
        id: "1",
        role: :assistant,
        type: :text,
        content: ~s({"args":{"upload_id":"upl_123"},"tool":"extract_role_from_jd"})
      },
      %{
        id: "2",
        role: :user,
        type: :text,
        content: "[Tool Result: extract_role_from_jd]\nExtracted 12 skill(s)."
      }
    ]

    assert [
             %{
               role: :assistant,
               type: :tool_call,
               name: "extract_role_from_jd",
               args: %{"upload_id" => "upl_123"},
               status: :ok,
               output: "Extracted 12 skill(s)."
             }
           ] = ChatComponents.normalize_messages(messages)
  end

  test "normalize_messages hides persisted think bookkeeping" do
    messages = [
      %{
        id: "1",
        role: :assistant,
        type: :text,
        content: ~s({"tool":"think","thought":"Check the extracted rows."})
      },
      %{
        id: "2",
        role: :user,
        type: :text,
        content: "[System] Thought noted. Continue with your next action."
      }
    ]

    assert [] = ChatComponents.normalize_messages(messages)
  end

  test "normalize_messages drops raw streaming envelope before an existing tool row" do
    messages = [
      %{
        id: "1",
        role: :assistant,
        type: :thinking,
        content: ~s({"args":{"upload_id":"upl_123"},"tool":"extract_role_from_jd"})
      },
      %{
        id: "2",
        role: :assistant,
        type: :tool_call,
        name: "extract_role_from_jd",
        args: %{"upload_id" => "upl_123"},
        status: :ok,
        output: "Extracted 12 skill(s).",
        content: "Tool: extract_role_from_jd"
      }
    ]

    assert [%{id: "2", type: :tool_call, output: "Extracted 12 skill(s)."}] =
             ChatComponents.normalize_messages(messages)
  end

  test "chat_feed summarizes tool calls outside debug mode" do
    html =
      render_component(&ChatComponents.chat_feed/1,
        messages: [
          %{
            id: "1",
            role: :assistant,
            type: :tool_call,
            name: "extract_role_from_jd",
            args: %{"upload_id" => "upl_123"},
            status: :ok,
            output: "Extracted 12 skill(s)."
          }
        ],
        session_id: "s1",
        inflight: %{},
        active_agent_id: "agent-1"
      )

    assert html =~ "tool-call-compact"
    assert html =~ "extract_role_from_jd"
    assert html =~ "Extracted 12 skill"
    refute html =~ "upl_123"
    refute html =~ "tool-call-detail"
  end

  test "chat_feed restores raw tool detail in debug mode" do
    html =
      render_component(&ChatComponents.chat_feed/1,
        messages: [
          %{
            id: "1",
            role: :assistant,
            type: :tool_call,
            name: "extract_role_from_jd",
            args: %{"upload_id" => "upl_123"},
            status: :ok,
            output: "Extracted 12 skill(s)."
          }
        ],
        session_id: "s1",
        inflight: %{},
        active_agent_id: "agent-1",
        debug_mode: true
      )

    assert html =~ "tool-call-debug"
    assert html =~ "tool-call-detail"
    assert html =~ "upl_123"
  end

  test "chat_feed renders action-backed select steps as a dropdown form" do
    flow = %Message{
      kind: :flow_prompt,
      flow_id: "create-framework",
      node_id: :choose_starting_point,
      title: "Pick a Starting Point",
      body: "How would you like to start?",
      fields: [
        %{
          name: :starting_point,
          label: "How would you like to start?",
          type: :select,
          required: true,
          value: "from_template",
          options: [
            {"From a similar role", "from_template"},
            {"Start from scratch", "scratch"}
          ]
        }
      ],
      actions: [
        %Action{
          id: "scratch",
          label: "Start from scratch",
          payload: %{starting_point: "scratch"},
          event: :submit_form,
          variant: :primary
        }
      ]
    }

    html =
      render_component(&ChatComponents.chat_feed/1,
        messages: [
          %{
            id: "flow-1",
            role: :assistant,
            type: :flow_card,
            agent_id: "agent-1",
            content: flow.body,
            flow: flow,
            flow_status: :active
          }
        ],
        session_id: "s1",
        inflight: %{},
        active_agent_id: "agent-1"
      )

    assert html =~ "flow-chat-card"
    assert html =~ "Pick a Starting Point"
    assert html =~ "phx-submit=\"flow_card_form\""
    assert html =~ "flow-chat-choice-form"
    assert html =~ "<select"
    assert html =~ "name=\"starting_point\""
    assert html =~ "Start from scratch"
    assert html =~ "value=\"from_template\""
    refute html =~ "phx-click=\"flow_card_action\""
  end

  test "chat_feed renders flow card fields as an editable form" do
    flow = %Message{
      kind: :flow_prompt,
      flow_id: "create-framework",
      node_id: :intake_template,
      title: "Name Your Framework",
      body: "Fill in the fields for this step.",
      fields: [
        %{
          name: :name,
          label: "Framework Name",
          type: :text,
          required: true,
          value: nil,
          options: []
        },
        %{
          name: :description,
          label: "Description",
          type: :textarea,
          required: true,
          value: nil,
          options: []
        }
      ]
    }

    html =
      render_component(&ChatComponents.chat_feed/1,
        messages: [
          %{
            id: "flow-2",
            role: :assistant,
            type: :flow_card,
            agent_id: "agent-1",
            content: flow.body,
            flow: flow,
            flow_status: :active
          }
        ],
        session_id: "s1",
        inflight: %{},
        active_agent_id: "agent-1"
      )

    assert html =~ "phx-submit=\"flow_card_form\""
    assert html =~ "name=\"node-id\""
    assert html =~ "value=\"intake_template\""
    assert html =~ "name=\"name\""
    assert html =~ "name=\"description\""
    assert html =~ "rows=\"2\""
    assert html =~ "Continue"
  end

  test "chat_feed renders flow field descriptions and select option hints" do
    flow = %Message{
      kind: :flow_prompt,
      flow_id: "create-framework",
      node_id: :taxonomy_preferences,
      title: "Design Structure",
      body: "Choose the structure before taxonomy generation.",
      fields: [
        %{
          name: :taxonomy_size,
          label: "Structure Size",
          type: :select,
          required: true,
          value: "balanced",
          description: "Controls how much taxonomy the generator creates.",
          options: [{"Compact", "compact"}, {"Balanced", "balanced"}],
          option_descriptions: %{
            "compact" => "Fewer categories and clusters.",
            "balanced" => "A practical middle ground."
          }
        }
      ]
    }

    html =
      render_component(&ChatComponents.chat_feed/1,
        messages: [
          %{
            id: "flow-3",
            role: :assistant,
            type: :flow_card,
            agent_id: "agent-1",
            content: flow.body,
            flow: flow,
            flow_status: :active
          }
        ],
        session_id: "s1",
        inflight: %{},
        active_agent_id: "agent-1"
      )

    assert html =~ "flow-chat-guided-form"
    assert html =~ "Controls how much taxonomy"
    assert html =~ "Compare options"
    assert html =~ "Fewer categories and clusters"
    assert html =~ "A practical middle ground"
    assert html =~ "Balanced"
  end

  test "chat_feed renders an empty state for selection flow cards with no items" do
    flow = %Message{
      kind: :flow_prompt,
      flow_id: "create-framework",
      node_id: :similar_roles,
      title: "Similar Roles",
      body: "No similar role profiles matched this framework.",
      artifact: %{
        kind: :selection,
        node_id: :similar_roles,
        item_count: 0,
        selected_count: 0,
        items: [],
        selected_ids: [],
        display_fields: %{title: :name}
      },
      actions: [
        %Action{
          id: "skip",
          label: "Choose another starting point",
          payload: %{skip: true},
          event: :skip_select,
          variant: :secondary
        }
      ]
    }

    html =
      render_component(&ChatComponents.chat_feed/1,
        messages: [
          %{
            id: "flow-3",
            role: :assistant,
            type: :flow_card,
            agent_id: "agent-1",
            content: flow.body,
            flow: flow,
            flow_status: :active
          }
        ],
        session_id: "s1",
        inflight: %{},
        active_agent_id: "agent-1"
      )

    assert html =~ "No similar roles found"
    assert html =~ "Choose another starting point"
  end

  test "chat_feed renders selectable role candidates inside selection flow cards" do
    flow = %Message{
      kind: :flow_prompt,
      flow_id: "create-framework",
      node_id: :similar_roles,
      title: "Similar Roles",
      body: "Select any role profiles that should shape the framework.",
      artifact: %{
        kind: :selection,
        node_id: :similar_roles,
        item_count: 2,
        selected_count: 1,
        selected_ids: ["role-1"],
        display_fields: %{title: :name, subtitle: :role_family, detail: :skill_count},
        items: [
          %{id: "role-1", name: "Risk Analyst", role_family: "Risk", skill_count: 12},
          %{id: "role-2", name: "Compliance Analyst", role_family: "Compliance", skill_count: 9}
        ]
      },
      actions: [
        %Action{
          id: "continue_selected",
          label: "Continue with 1 selected",
          payload: %{selected_ids: ["role-1"]},
          event: :confirm_selection,
          variant: :primary
        }
      ]
    }

    html =
      render_component(&ChatComponents.chat_feed/1,
        messages: [
          %{
            id: "flow-4",
            role: :assistant,
            type: :flow_card,
            agent_id: "agent-1",
            content: flow.body,
            flow: flow,
            flow_status: :active
          }
        ],
        session_id: "s1",
        inflight: %{},
        active_agent_id: "agent-1"
      )

    assert html =~ "1 of 2 role candidates selected"
    assert html =~ "phx-click=\"flow_card_select_toggle\""
    assert html =~ "Risk Analyst"
    assert html =~ "Compliance Analyst"
    assert html =~ "Continue with 1 selected"
  end
end
