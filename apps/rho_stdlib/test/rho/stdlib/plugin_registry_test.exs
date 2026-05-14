defmodule Rho.Stdlib.PluginRegistryTest do
  use ExUnit.Case, async: false

  alias Rho.PluginRegistry

  setup do
    PluginRegistry.clear()
    :ok
  end

  # --- Test plugin modules ---

  defmodule ToolPlugin do
    @behaviour Rho.Plugin

    @impl true
    def tools(opts, _ctx) do
      prefix = Keyword.get(opts, :prefix, "")
      [%{name: "#{prefix}tool_a", description: "Tool A"}]
    end
  end

  defmodule PromptPlugin do
    @behaviour Rho.Plugin

    @impl true
    def prompt_sections(_opts, _ctx) do
      ["Always be helpful."]
    end
  end

  defmodule BindingPlugin do
    @behaviour Rho.Plugin

    @impl true
    def bindings(_opts, _ctx) do
      [
        %{
          name: "journal_view",
          kind: :text_corpus,
          size: 1024,
          access: :python_var,
          persistence: :session,
          summary: "Full journal"
        }
      ]
    end
  end

  defmodule FullPlugin do
    @behaviour Rho.Plugin

    @impl true
    def tools(_opts, _ctx), do: [%{name: "full_tool", description: "Full"}]

    @impl true
    def prompt_sections(_opts, _ctx), do: ["Full section"]

    @impl true
    def bindings(_opts, _ctx) do
      [
        %{
          name: "full_binding",
          kind: :structured_data,
          size: 256,
          access: :tool,
          persistence: :turn,
          summary: "Data"
        }
      ]
    end
  end

  defmodule ScopedPlugin do
    @behaviour Rho.Plugin

    @impl true
    def tools(_opts, _ctx), do: [%{name: "scoped_tool", description: "Scoped"}]
  end

  defmodule CrashingPlugin do
    @behaviour Rho.Plugin

    @impl true
    def tools(_opts, _ctx), do: crash!()

    @impl true
    def prompt_sections(_opts, _ctx), do: crash!()

    @impl true
    def bindings(_opts, _ctx), do: crash!()

    defp crash!, do: raise("boom")
  end

  # --- Registration ---

  test "register/1 adds a plugin" do
    assert :ok = PluginRegistry.register(ToolPlugin)
    assert [%Rho.PluginInstance{module: ToolPlugin}] = PluginRegistry.active_plugins(%{})
  end

  test "plugins are ordered highest-priority (last-registered) first" do
    PluginRegistry.register(ToolPlugin)
    PluginRegistry.register(PromptPlugin)
    PluginRegistry.register(BindingPlugin)

    modules = PluginRegistry.active_plugins(%{}) |> Enum.map(& &1.module)
    assert [BindingPlugin, PromptPlugin, ToolPlugin] = modules
  end

  test "clear/0 removes all plugins" do
    PluginRegistry.register(ToolPlugin)
    PluginRegistry.clear()
    assert [] = PluginRegistry.active_plugins(%{})
  end

  # --- Plugin opts passthrough ---

  test "plugin_opts are passed through to callbacks" do
    PluginRegistry.register(ToolPlugin, opts: [prefix: "custom_"])
    tools = PluginRegistry.collect_tools(%{})
    assert [%{name: "custom_tool_a"}] = tools
  end

  # --- Scope filtering ---

  test "scoped plugin fires only for matching agent_name" do
    PluginRegistry.register(ScopedPlugin, scope: {:agent, :coder})

    assert [%{name: "scoped_tool"}] = PluginRegistry.collect_tools(%{agent_name: :coder})
    assert [] = PluginRegistry.collect_tools(%{agent_name: :default})
    assert [] = PluginRegistry.collect_tools(%{})
  end

  test "global plugin fires regardless of agent_name" do
    PluginRegistry.register(ToolPlugin)

    assert [%{name: "tool_a"}] = PluginRegistry.collect_tools(%{agent_name: :coder})
    assert [%{name: "tool_a"}] = PluginRegistry.collect_tools(%{agent_name: :default})
    assert [%{name: "tool_a"}] = PluginRegistry.collect_tools(%{})
  end

  test "collects from both global and matching scoped plugins" do
    PluginRegistry.register(ToolPlugin)
    PluginRegistry.register(ScopedPlugin, scope: {:agent, :coder})

    names = PluginRegistry.collect_tools(%{agent_name: :coder}) |> Enum.map(& &1.name)
    assert "tool_a" in names
    assert "scoped_tool" in names

    names = PluginRegistry.collect_tools(%{agent_name: :default}) |> Enum.map(& &1.name)
    assert "tool_a" in names
    refute "scoped_tool" in names
  end

  # --- Affordance collection ---

  test "collect_tools gathers tools from all active plugins" do
    PluginRegistry.register(ToolPlugin)
    PluginRegistry.register(FullPlugin)

    names = PluginRegistry.collect_tools(%{}) |> Enum.map(& &1.name)
    assert "tool_a" in names
    assert "full_tool" in names
  end

  test "collect_prompt_sections gathers sections from all active plugins" do
    PluginRegistry.register(PromptPlugin)
    PluginRegistry.register(FullPlugin)

    sections = PluginRegistry.collect_prompt_sections(%{})
    assert "Always be helpful." in sections
    assert "Full section" in sections
  end

  test "collect_bindings gathers bindings from all active plugins" do
    PluginRegistry.register(BindingPlugin)
    PluginRegistry.register(FullPlugin)

    names = PluginRegistry.collect_bindings(%{}) |> Enum.map(& &1.name)
    assert "journal_view" in names
    assert "full_binding" in names
  end

  test "collect_tools returns empty list when plugin has no tools callback" do
    PluginRegistry.register(PromptPlugin)
    assert [] = PluginRegistry.collect_tools(%{})
  end

  # --- Crashing plugin resilience ---

  test "crashing plugin in collect_tools is caught, returns empty" do
    PluginRegistry.register(ToolPlugin)
    PluginRegistry.register(CrashingPlugin)

    tools = PluginRegistry.collect_tools(%{})
    assert [%{name: "tool_a"}] = tools
  end

  test "crashing plugin in collect_prompt_sections is caught" do
    PluginRegistry.register(PromptPlugin)
    PluginRegistry.register(CrashingPlugin)

    sections = PluginRegistry.collect_prompt_sections(%{})
    assert ["Always be helpful."] = sections
  end

  test "crashing plugin in collect_bindings is caught" do
    PluginRegistry.register(BindingPlugin)
    PluginRegistry.register(CrashingPlugin)

    bindings = PluginRegistry.collect_bindings(%{})
    assert [%{name: "journal_view"}] = bindings
  end
end
