defmodule Rho.Mounts.SpreadsheetLoadTest do
  use ExUnit.Case, async: false

  alias Rho.Mounts.Spreadsheet

  defp make_context(session_id) do
    %{
      session_id: session_id,
      agent_id: "test_agent",
      workspace: "/tmp",
      agent_name: :spreadsheet,
      opts: %{company_id: "test_co", is_admin: false}
    }
  end

  describe "load_framework tool" do
    test "tool has append parameter" do
      context = make_context("test_load_append")
      tools = Spreadsheet.tools([], context)
      tool = Enum.find(tools, fn t -> t.tool.name == "load_framework" end)

      param_names = Keyword.keys(tool.tool.parameter_schema)

      assert :append in param_names
    end
  end

  describe "load_framework_roles tool" do
    test "tool has append parameter" do
      context = make_context("test_load_roles_append")
      tools = Spreadsheet.tools([], context)
      tool = Enum.find(tools, fn t -> t.tool.name == "load_framework_roles" end)

      param_names = Keyword.keys(tool.tool.parameter_schema)

      assert :append in param_names
    end
  end

  describe "get_company_view tool" do
    test "tool is present in tools list" do
      context = make_context("test_company_view")
      tools = Spreadsheet.tools([], context)
      tool_names = Enum.map(tools, fn t -> t.tool.name end)
      assert "get_company_view" in tool_names
    end
  end
end
