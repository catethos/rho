defmodule Rho.MountRegistryTest do
  use ExUnit.Case, async: false

  alias Rho.MountRegistry

  setup do
    MountRegistry.clear()
    :ok
  end

  # --- Test mount modules ---

  defmodule ToolMount do
    @behaviour Rho.Mount

    @impl true
    def tools(opts, _ctx) do
      prefix = Keyword.get(opts, :prefix, "")
      [%{name: "#{prefix}tool_a", description: "Tool A"}]
    end
  end

  defmodule PromptMount do
    @behaviour Rho.Mount

    @impl true
    def prompt_sections(_opts, _ctx) do
      ["Always be helpful."]
    end
  end

  defmodule BindingMount do
    @behaviour Rho.Mount

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

  defmodule FullMount do
    @behaviour Rho.Mount

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

    @impl true
    def before_llm(projection, _opts, _ctx) do
      {:replace,
       %{projection | prompt_sections: projection.prompt_sections ++ ["injected by before_llm"]}}
    end

    @impl true
    def before_tool(%{name: "dangerous"}, _opts, _ctx), do: {:deny, "Not allowed"}
    def before_tool(_call, _opts, _ctx), do: :ok

    @impl true
    def after_tool(%{name: "bash"}, result, _opts, _ctx) do
      {:replace, "[filtered] " <> result}
    end

    def after_tool(_call, result, _opts, _ctx), do: {:ok, result}

    @impl true
    def after_step(step, max_steps, _opts, _ctx) when step >= max_steps - 1 do
      {:inject, "You're almost out of steps!"}
    end

    def after_step(_step, _max, _opts, _ctx), do: :ok
  end

  defmodule ScopedMount do
    @behaviour Rho.Mount

    @impl true
    def tools(_opts, _ctx), do: [%{name: "scoped_tool", description: "Scoped"}]
  end

  defmodule CrashingMount do
    @behaviour Rho.Mount

    @impl true
    def tools(_opts, _ctx), do: raise("boom")

    @impl true
    def prompt_sections(_opts, _ctx), do: raise("boom")

    @impl true
    def bindings(_opts, _ctx), do: raise("boom")

    @impl true
    def before_llm(_proj, _opts, _ctx), do: raise("boom")

    @impl true
    def before_tool(_call, _opts, _ctx), do: raise("boom")

    @impl true
    def after_tool(_call, _result, _opts, _ctx), do: raise("boom")

    @impl true
    def after_step(_step, _max, _opts, _ctx), do: raise("boom")
  end

  defmodule InjectMount do
    @behaviour Rho.Mount

    @impl true
    def after_step(_step, _max, _opts, _ctx) do
      {:inject, "Reminder from InjectMount"}
    end
  end

  # --- Registration ---

  test "register/1 adds a mount" do
    assert :ok = MountRegistry.register(ToolMount)
    assert [%Rho.MountInstance{module: ToolMount}] = MountRegistry.active_mounts(%{})
  end

  test "mounts are ordered highest-priority (last-registered) first" do
    MountRegistry.register(ToolMount)
    MountRegistry.register(PromptMount)
    MountRegistry.register(BindingMount)

    modules = MountRegistry.active_mounts(%{}) |> Enum.map(& &1.module)
    assert [BindingMount, PromptMount, ToolMount] = modules
  end

  test "clear/0 removes all mounts" do
    MountRegistry.register(ToolMount)
    MountRegistry.clear()
    assert [] = MountRegistry.active_mounts(%{})
  end

  # --- Mount opts passthrough ---

  test "mount_opts are passed through to callbacks" do
    MountRegistry.register(ToolMount, opts: [prefix: "custom_"])
    tools = MountRegistry.collect_tools(%{})
    assert [%{name: "custom_tool_a"}] = tools
  end

  # --- Scope filtering ---

  test "scoped mount fires only for matching agent_name" do
    MountRegistry.register(ScopedMount, scope: {:agent, :coder})

    assert [%{name: "scoped_tool"}] = MountRegistry.collect_tools(%{agent_name: :coder})
    assert [] = MountRegistry.collect_tools(%{agent_name: :default})
    assert [] = MountRegistry.collect_tools(%{})
  end

  test "global mount fires regardless of agent_name" do
    MountRegistry.register(ToolMount)

    assert [%{name: "tool_a"}] = MountRegistry.collect_tools(%{agent_name: :coder})
    assert [%{name: "tool_a"}] = MountRegistry.collect_tools(%{agent_name: :default})
    assert [%{name: "tool_a"}] = MountRegistry.collect_tools(%{})
  end

  test "collects from both global and matching scoped mounts" do
    MountRegistry.register(ToolMount)
    MountRegistry.register(ScopedMount, scope: {:agent, :coder})

    names = MountRegistry.collect_tools(%{agent_name: :coder}) |> Enum.map(& &1.name)
    assert "tool_a" in names
    assert "scoped_tool" in names

    names = MountRegistry.collect_tools(%{agent_name: :default}) |> Enum.map(& &1.name)
    assert "tool_a" in names
    refute "scoped_tool" in names
  end

  # --- Affordance collection ---

  test "collect_tools gathers tools from all active mounts" do
    MountRegistry.register(ToolMount)
    MountRegistry.register(FullMount)

    names = MountRegistry.collect_tools(%{}) |> Enum.map(& &1.name)
    assert "tool_a" in names
    assert "full_tool" in names
  end

  test "collect_prompt_sections gathers sections from all active mounts" do
    MountRegistry.register(PromptMount)
    MountRegistry.register(FullMount)

    sections = MountRegistry.collect_prompt_sections(%{})
    assert "Always be helpful." in sections
    assert "Full section" in sections
  end

  test "collect_bindings gathers bindings from all active mounts" do
    MountRegistry.register(BindingMount)
    MountRegistry.register(FullMount)

    names = MountRegistry.collect_bindings(%{}) |> Enum.map(& &1.name)
    assert "journal_view" in names
    assert "full_binding" in names
  end

  test "collect_tools returns empty list when mount has no tools callback" do
    MountRegistry.register(PromptMount)
    assert [] = MountRegistry.collect_tools(%{})
  end

  # --- collect_prompt_material ---

  test "collect_prompt_material normalizes strings to PromptSection structs" do
    MountRegistry.register(PromptMount)

    sections = MountRegistry.collect_prompt_material(%{})
    assert length(sections) == 1
    assert %Rho.Mount.PromptSection{body: "Always be helpful."} = hd(sections)
  end

  test "collect_prompt_material includes bindings as a metadata section" do
    MountRegistry.register(BindingMount)

    sections = MountRegistry.collect_prompt_material(%{})
    assert length(sections) == 1
    section = hd(sections)
    assert %Rho.Mount.PromptSection{key: :bindings, kind: :metadata} = section
    assert section.body =~ "journal_view"
  end

  test "collect_prompt_material combines sections and bindings" do
    MountRegistry.register(FullMount)

    sections = MountRegistry.collect_prompt_material(%{})
    keys = Enum.map(sections, & &1.key)
    # auto-wrapped string gets :unknown key
    assert :unknown in keys
    assert :bindings in keys
  end

  # --- render_binding_metadata (legacy) ---

  test "render_binding_metadata produces prompt-ready strings" do
    bindings = [
      %{
        name: "journal",
        kind: :text_corpus,
        size: 2048,
        summary: "Full journal",
        access: :python_var
      }
    ]

    [line] = MountRegistry.render_binding_metadata(bindings)
    assert line =~ "journal"
    assert line =~ "text_corpus"
    assert line =~ "2048"
    assert line =~ "python_var"
  end

  # --- Hook dispatch: before_llm ---

  test "dispatch_before_llm threads projection through mounts" do
    MountRegistry.register(FullMount)

    projection = %{
      system_prompt: "test",
      messages: [],
      prompt_sections: ["original"],
      bindings: [],
      tools: [],
      meta: %{}
    }

    result = MountRegistry.dispatch_before_llm(projection, %{})
    assert "original" in result.prompt_sections
    assert "injected by before_llm" in result.prompt_sections
  end

  test "dispatch_before_llm passes through when no mount implements it" do
    MountRegistry.register(ToolMount)

    projection = %{
      system_prompt: "test",
      messages: [],
      prompt_sections: [],
      bindings: [],
      tools: [],
      meta: %{}
    }

    assert ^projection = MountRegistry.dispatch_before_llm(projection, %{})
  end

  # --- Hook dispatch: before_tool ---

  test "dispatch_before_tool returns :ok for allowed tools" do
    MountRegistry.register(FullMount)
    assert :ok = MountRegistry.dispatch_before_tool(%{name: "bash"}, %{})
  end

  test "dispatch_before_tool short-circuits on deny" do
    MountRegistry.register(FullMount)
    assert {:deny, "Not allowed"} = MountRegistry.dispatch_before_tool(%{name: "dangerous"}, %{})
  end

  test "dispatch_before_tool returns :ok when no mount implements it" do
    MountRegistry.register(ToolMount)
    assert :ok = MountRegistry.dispatch_before_tool(%{name: "anything"}, %{})
  end

  # --- Hook dispatch: after_tool ---

  test "dispatch_after_tool replaces result when mount overrides" do
    MountRegistry.register(FullMount)
    result = MountRegistry.dispatch_after_tool(%{name: "bash"}, "output", %{})
    assert result == "[filtered] output"
  end

  test "dispatch_after_tool passes through for non-matching tools" do
    MountRegistry.register(FullMount)
    result = MountRegistry.dispatch_after_tool(%{name: "fs_read"}, "content", %{})
    assert result == "content"
  end

  test "dispatch_after_tool returns original result when no mount implements it" do
    MountRegistry.register(ToolMount)
    assert "output" = MountRegistry.dispatch_after_tool(%{name: "bash"}, "output", %{})
  end

  # --- Hook dispatch: after_step ---

  test "dispatch_after_step returns :ok normally" do
    MountRegistry.register(FullMount)
    assert :ok = MountRegistry.dispatch_after_step(1, 10, %{})
  end

  test "dispatch_after_step injects message near budget limit" do
    MountRegistry.register(FullMount)

    assert {:inject, ["You're almost out of steps!"]} =
             MountRegistry.dispatch_after_step(9, 10, %{})
  end

  test "dispatch_after_step collects injections from multiple mounts" do
    MountRegistry.register(InjectMount)
    MountRegistry.register(FullMount)

    assert {:inject, messages} = MountRegistry.dispatch_after_step(9, 10, %{})
    assert "You're almost out of steps!" in messages
    assert "Reminder from InjectMount" in messages
  end

  test "dispatch_after_step returns :ok when no mount implements it" do
    MountRegistry.register(ToolMount)
    assert :ok = MountRegistry.dispatch_after_step(1, 10, %{})
  end

  # --- Crashing mount resilience ---

  test "crashing mount in collect_tools is caught, returns empty" do
    MountRegistry.register(ToolMount)
    MountRegistry.register(CrashingMount)

    tools = MountRegistry.collect_tools(%{})
    assert [%{name: "tool_a"}] = tools
  end

  test "crashing mount in collect_prompt_sections is caught" do
    MountRegistry.register(PromptMount)
    MountRegistry.register(CrashingMount)

    sections = MountRegistry.collect_prompt_sections(%{})
    assert ["Always be helpful."] = sections
  end

  test "crashing mount in collect_bindings is caught" do
    MountRegistry.register(BindingMount)
    MountRegistry.register(CrashingMount)

    bindings = MountRegistry.collect_bindings(%{})
    assert [%{name: "journal_view"}] = bindings
  end

  test "crashing mount in dispatch_before_llm is caught, projection passes through" do
    MountRegistry.register(CrashingMount)

    projection = %{
      system_prompt: "test",
      messages: [],
      prompt_sections: [],
      bindings: [],
      tools: [],
      meta: %{}
    }

    assert ^projection = MountRegistry.dispatch_before_llm(projection, %{})
  end

  test "crashing mount in dispatch_before_tool is caught, returns :ok" do
    MountRegistry.register(CrashingMount)
    assert :ok = MountRegistry.dispatch_before_tool(%{name: "bash"}, %{})
  end

  test "crashing mount in dispatch_after_tool is caught, returns original result" do
    MountRegistry.register(CrashingMount)
    assert "output" = MountRegistry.dispatch_after_tool(%{name: "bash"}, "output", %{})
  end

  test "crashing mount in dispatch_after_step is caught, returns :ok" do
    MountRegistry.register(CrashingMount)
    assert :ok = MountRegistry.dispatch_after_step(1, 10, %{})
  end

  # --- Unloaded-module resilience (safe_call ensure_loaded regression) ---

  test "safe_call ensures module is loaded before checking function_exported?" do
    # Register a mount compiled-to-disk, then purge it from memory to simulate
    # a not-yet-loaded module (e.g. in a release where code is lazy-loaded).
    # safe_call must Code.ensure_loaded/1 before function_exported?/3.
    mod = Rho.Test.ReloadableMount
    MountRegistry.register(mod)

    :code.purge(mod)
    :code.delete(mod)
    refute :code.is_loaded(mod)

    # collect_tools should reload the module and return its tools, not [].
    assert [%{name: "reloadable_tool"}] = MountRegistry.collect_tools(%{})
    assert {:file, _} = :code.is_loaded(mod)
  end
end
