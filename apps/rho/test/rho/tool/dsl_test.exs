defmodule Rho.Tool.DSLTest do
  use ExUnit.Case, async: true

  # ── Test module using the DSL ──────────────────────────────────────────

  defmodule SampleTools do
    use Rho.Tool

    tool :greet, "Say hello to someone" do
      param(:name, :string, required: true, doc: "Person's name")
      param(:title, :string, doc: "Optional title")

      run(fn args, _ctx ->
        title = args[:title]
        name = args[:name]

        if title do
          {:ok, "Hello, #{title} #{name}!"}
        else
          {:ok, "Hello, #{name}!"}
        end
      end)
    end

    tool :no_params, "A tool with no parameters" do
      run(fn _args, _ctx ->
        {:ok, "done"}
      end)
    end

    tool :with_effects, "A tool returning a ToolResponse" do
      param(:query, :string, required: true, doc: "Search query")

      run(fn args, _ctx ->
        %Rho.ToolResponse{
          text: "Found results for #{args[:query]}",
          effects: [
            %Rho.Effect.Table{
              columns: [%{key: :name, label: "Name"}],
              rows: [%{name: "result1"}]
            }
          ]
        }
      end)
    end

    # Test that private helpers in the same module are accessible
    tool :with_helper, "Uses a private helper" do
      param(:value, :string, required: true, doc: "Input value")

      run(fn args, _ctx ->
        {:ok, upcase_it(args[:value])}
      end)
    end

    defp upcase_it(nil), do: ""
    defp upcase_it(s), do: String.upcase(s)
  end

  # ── Schema shape tests ────────────────────────────────────────────────

  describe "__tools__/1 schema shape" do
    test "returns a list of tool_def maps" do
      tools = SampleTools.__tools__()
      assert is_list(tools)
      assert match?([_, _, _, _], tools)

      for tool_def <- tools do
        assert %{tool: %ReqLLM.Tool{}, execute: execute} = tool_def
        assert is_function(execute, 2)
      end
    end

    test "tool names match declared atoms" do
      names = SampleTools.__tools__() |> Enum.map(& &1.tool.name) |> Enum.sort()
      assert names == ["greet", "no_params", "with_effects", "with_helper"]
    end

    test "tool descriptions are preserved" do
      tools = SampleTools.__tools__()
      greet = Enum.find(tools, &(&1.tool.name == "greet"))
      assert greet.tool.description == "Say hello to someone"
    end

    test "parameter schema is correctly built" do
      tools = SampleTools.__tools__()
      greet = Enum.find(tools, &(&1.tool.name == "greet"))
      schema = greet.tool.parameter_schema

      assert Keyword.has_key?(schema, :name)
      assert schema[:name][:type] == :string
      assert schema[:name][:required] == true
      assert schema[:name][:doc] == "Person's name"

      assert Keyword.has_key?(schema, :title)
      assert schema[:title][:type] == :string
      refute schema[:title][:required]
    end

    test "no-param tool has empty parameter_schema" do
      tools = SampleTools.__tools__()
      no_params = Enum.find(tools, &(&1.tool.name == "no_params"))
      assert no_params.tool.parameter_schema == []
    end
  end

  # ── Arg casting tests ─────────────────────────────────────────────────

  describe "arg casting via execute" do
    setup do
      ctx = %Rho.Context{agent_name: :test}
      {:ok, ctx: ctx}
    end

    test "string-keyed args are cast to atoms", %{ctx: ctx} do
      tools = SampleTools.__tools__()
      greet = Enum.find(tools, &(&1.tool.name == "greet"))

      assert {:ok, "Hello, World!"} =
               greet.execute.(%{"name" => "World"}, ctx)
    end

    test "atom-keyed args pass through", %{ctx: ctx} do
      tools = SampleTools.__tools__()
      greet = Enum.find(tools, &(&1.tool.name == "greet"))

      assert {:ok, "Hello, Dr World!"} =
               greet.execute.(%{name: "World", title: "Dr"}, ctx)
    end

    test "unknown string keys are ignored (not atomized)", %{ctx: ctx} do
      tools = SampleTools.__tools__()
      greet = Enum.find(tools, &(&1.tool.name == "greet"))

      # Extra unknown key should not cause errors
      assert {:ok, "Hello, World!"} =
               greet.execute.(%{"name" => "World", "unknown_key" => "val"}, ctx)
    end
  end

  # ── Execution tests ───────────────────────────────────────────────────

  describe "tool execution" do
    setup do
      ctx = %Rho.Context{agent_name: :test}
      {:ok, ctx: ctx}
    end

    test "run function can access private helpers in the same module", %{ctx: ctx} do
      tools = SampleTools.__tools__()
      helper_tool = Enum.find(tools, &(&1.tool.name == "with_helper"))

      assert {:ok, "HELLO"} = helper_tool.execute.(%{"value" => "hello"}, ctx)
    end

    test "run function can return ToolResponse with effects", %{ctx: ctx} do
      tools = SampleTools.__tools__()
      effects_tool = Enum.find(tools, &(&1.tool.name == "with_effects"))

      result = effects_tool.execute.(%{"query" => "test"}, ctx)
      assert %Rho.ToolResponse{text: "Found results for test", effects: effects} = result
      assert [%Rho.Effect.Table{rows: [%{name: "result1"}]}] = effects
    end
  end

  # ── Required-param enforcement ────────────────────────────────────────

  describe "required parameter validation" do
    setup do
      ctx = %Rho.Context{agent_name: :test}
      {:ok, ctx: ctx}
    end

    test "missing required param returns friendly error instead of crashing", %{ctx: ctx} do
      tools = SampleTools.__tools__()
      greet = Enum.find(tools, &(&1.tool.name == "greet"))

      assert {:error, msg} = greet.execute.(%{}, ctx)
      assert msg =~ "Missing required parameter"
      assert msg =~ "name"
    end

    test "explicit nil for required param is rejected", %{ctx: ctx} do
      tools = SampleTools.__tools__()
      greet = Enum.find(tools, &(&1.tool.name == "greet"))

      assert {:error, msg} = greet.execute.(%{"name" => nil}, ctx)
      assert msg =~ "name"
    end

    test "missing optional param is allowed", %{ctx: ctx} do
      tools = SampleTools.__tools__()
      greet = Enum.find(tools, &(&1.tool.name == "greet"))

      # title is optional — omitting it is fine
      assert {:ok, "Hello, World!"} = greet.execute.(%{"name" => "World"}, ctx)
    end
  end
end
