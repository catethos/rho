defmodule RhoWeb.AppLiveChatShellComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rho.Stdlib.DataTable.WorkbenchContext
  alias Rho.Stdlib.DataTable.WorkbenchContext.ArtifactSummary
  alias RhoWeb.AppLive.ChatShellComponents

  test "new_chat_dialog renders configured agent roles as conversation choices" do
    html = render_component(&ChatShellComponents.new_chat_dialog/1, %{})

    assert html =~ "New Chat"
    assert html =~ "General"
    assert html =~ ~s(phx-click="new_conversation")
    assert html =~ ~s(phx-value-role="default")
  end

  test "chat shell always exposes Workbench actions" do
    uploads = %{
      files: Phoenix.LiveView.UploadConfig.build(:files, "files", accept: :any),
      avatar: Phoenix.LiveView.UploadConfig.build(:avatar, "avatar", accept: :any)
    }

    html =
      render_component(&ChatShellComponents.chat_side_panel/1, %{
        chat_mode: :expanded,
        messages: [],
        session_id: "s1",
        inflight: %{},
        active_agent_id: "s1/primary",
        pending: false,
        agents: %{},
        agent_tab_order: [],
        chat_status: :idle,
        total_input_tokens: 0,
        total_output_tokens: 0,
        total_cost: 0.0,
        total_cached_tokens: 0,
        total_reasoning_tokens: 0,
        step_input_tokens: 0,
        step_output_tokens: 0,
        uploads: uploads,
        active_agent: %{agent_name: :spreadsheet},
        conversations: [],
        chat_rail_collapsed: true,
        files_parsing: %{}
      })

    assert html =~ "Actions"
    assert html =~ ~s(phx-click="open_workbench_home")
  end

  test "workbench_suggestions keeps the first three actionable artifact actions" do
    context = %WorkbenchContext{
      active_artifact: %ArtifactSummary{
        table_name: "library:future",
        title: "Future Library",
        actions: [:generate_levels, :save_draft, :publish, :suggest_skills]
      }
    }

    assert [
             %{label: "Generate levels", content: generate_content},
             %{label: "Save draft", content: save_content},
             %{label: "Publish", content: publish_content}
           ] = ChatShellComponents.workbench_suggestions(context)

    assert generate_content ==
             "Generate proficiency levels for skills missing levels in library:future."

    assert save_content == "Save Future Library as a draft."
    assert publish_content == "Publish Future Library when it is ready."
  end

  test "format_tokens and agent_role_label preserve chat chrome labels" do
    assert ChatShellComponents.format_tokens(999) == "999"
    assert ChatShellComponents.format_tokens(12_500) == "12.5K"
    assert ChatShellComponents.format_tokens(2_000_000) == "2.0M"

    assert ChatShellComponents.agent_role_label(:default) == "General"
    assert ChatShellComponents.agent_role_label(:research_lead) == "Research Lead"
  end
end
