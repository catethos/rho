defmodule Rho.AgentConfigTest do
  use ExUnit.Case, async: false

  @cache_key {Rho.AgentConfig, :cache}

  setup do
    previous_env = System.get_env("RHO_AGENT_CONFIG")
    previous_app_env = Application.get_env(:rho, :agent_config_path)
    clear_cache()

    on_exit(fn ->
      restore_env("RHO_AGENT_CONFIG", previous_env)

      if previous_app_env do
        Application.put_env(:rho, :agent_config_path, previous_app_env)
      else
        Application.delete_env(:rho, :agent_config_path)
      end

      clear_cache()
    end)
  end

  test "discovers .rho.exs from parent directories" do
    root = tmp_dir()
    subdir = Path.join([root, "apps", "rho_web"])
    File.mkdir_p!(subdir)

    File.write!(Path.join(root, ".rho.exs"), """
    %{
      default: [system_prompt: "root default"],
      spreadsheet: [system_prompt: "sheet"],
      researcher: [system_prompt: "research"]
    }
    """)

    File.cd!(subdir, fn ->
      clear_cache()

      assert Rho.AgentConfig.agent_names() == [:default, :researcher, :spreadsheet]
    end)
  end

  test "explicit RHO_AGENT_CONFIG path wins over upward discovery" do
    root = tmp_dir()
    subdir = Path.join(root, "nested")
    explicit = Path.join(root, "agents.exs")
    File.mkdir_p!(subdir)
    File.write!(Path.join(root, ".rho.exs"), "%{default: [], spreadsheet: []}")
    File.write!(explicit, "%{researcher: []}")

    System.put_env("RHO_AGENT_CONFIG", explicit)

    File.cd!(subdir, fn ->
      clear_cache()
      assert Rho.AgentConfig.agent_names() == [:researcher]
    end)
  end

  defp tmp_dir do
    dir =
      Path.join(System.tmp_dir!(), "rho_agent_config_test_#{System.unique_integer([:positive])}")

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  defp clear_cache, do: :persistent_term.erase(@cache_key)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
