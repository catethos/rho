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
