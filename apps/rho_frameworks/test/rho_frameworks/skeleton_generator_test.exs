defmodule RhoFrameworks.SkeletonGeneratorTest do
  use ExUnit.Case, async: false

  alias Rho.Stdlib.DataTable
  alias RhoFrameworks.SkeletonGenerator
  alias RhoFrameworks.Runtime
  alias RhoFrameworks.Repo

  setup do
    org_id = Ecto.UUID.generate()

    Repo.insert!(%RhoFrameworks.Accounts.Organization{
      id: org_id,
      name: "SkeletonGen Test Org",
      slug: "skelgen-test-#{System.unique_integer([:positive])}"
    })

    session_id = "sess-skelgen-#{System.unique_integer([:positive])}"
    on_exit(fn -> DataTable.stop(session_id) end)

    rt =
      Runtime.new_flow(
        organization_id: org_id,
        session_id: session_id,
        execution_id: "flow-skelgen-#{System.unique_integer([:positive])}"
      )

    %{org_id: org_id, session_id: session_id, rt: rt}
  end

  describe "generate/2" do
    test "spawns a LiteWorker and returns agent_id", %{rt: rt} do
      assert {:ok, %{agent_id: agent_id}} =
               SkeletonGenerator.generate(
                 %{name: "Engineering Framework", description: "Software engineering skills"},
                 rt
               )

      assert is_binary(agent_id)
      assert String.contains?(agent_id, "agent_")
    end

    test "resolve_tools/1 includes manage_library, save_skeletons, finish" do
      ctx = %Rho.Context{agent_name: :spreadsheet}
      tools = SkeletonGenerator.resolve_tools(ctx)

      tool_names = Enum.map(tools, fn t -> t.tool.name end)
      assert "manage_library" in tool_names
      assert "save_skeletons" in tool_names
      assert "finish" in tool_names
    end
  end
end
