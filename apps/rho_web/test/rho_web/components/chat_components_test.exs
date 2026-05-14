defmodule RhoWeb.ChatComponentsTest do
  use ExUnit.Case, async: true

  alias RhoWeb.ChatComponents

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
end
