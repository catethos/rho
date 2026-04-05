defmodule Rho.Config do
  @config_file ".rho.exs"

  @defaults [
    model: "openrouter:anthropic/claude-sonnet",
    system_prompt: "You are a helpful assistant.",
    mounts: [:bash],
    max_steps: 50,
    max_tokens: 4096,
    reasoner: :direct,
    prompt_format: :markdown
  ]

  @reasoner_modules %{
    direct: Rho.Reasoner.Direct,
    structured: Rho.Reasoner.Structured
  }

  @mount_modules %{
    bash: Rho.Tools.Bash,
    fs_read: Rho.Tools.FsRead,
    fs_write: Rho.Tools.FsWrite,
    fs_edit: Rho.Tools.FsEdit,
    web_fetch: Rho.Tools.WebFetch,
    python: Rho.Tools.Python,
    skills: Rho.Skills,
    subagent: Rho.Plugins.Subagent,
    multi_agent: Rho.Mounts.MultiAgent,
    sandbox: Rho.Tools.Sandbox,
    journal: Rho.Mounts.JournalTools,
    step_budget: Rho.Plugins.StepBudget,
    live_render: Rho.Mounts.LiveRender,
    py_agent: Rho.Mounts.PyAgent,
    spreadsheet: Rho.Mounts.Spreadsheet,
    framework_persistence: Rho.Mounts.FrameworkPersistence,
    doc_ingest: Rho.Mounts.DocIngest
  }

  @doc """
  Resolves a mount entry to `{module, opts}`.

  Accepts:
  - An atom shorthand: `:bash` → `{Rho.Tools.Bash, []}`
  - A tuple with options: `{:python, max_iterations: 20}` → `{Rho.Tools.Python, [max_iterations: 20]}`
  - A raw module: `MyProject.ReviewPolicy` → `{MyProject.ReviewPolicy, []}`
  - A tuple of module + opts: `{MyProject.ReviewPolicy, some: :opt}` → `{MyProject.ReviewPolicy, [some: :opt]}`
  """
  def resolve_mount(entry) when is_atom(entry) do
    case Map.fetch(@mount_modules, entry) do
      {:ok, mod} -> {mod, []}
      :error -> {entry, []}
    end
  end

  def resolve_mount({name, opts}) when is_atom(name) and is_list(opts) do
    case Map.fetch(@mount_modules, name) do
      {:ok, mod} -> {mod, opts}
      :error -> {name, opts}
    end
  end

  @doc "Returns the map of known mount atoms to their modules."
  def mount_modules, do: @mount_modules

  @doc """
  Resolves a reasoner entry to a module implementing `Rho.Reasoner`.

  Accepts:
  - An atom shorthand: `:direct` → `Rho.Reasoner.Direct`
  - A module: `MyProject.CustomReasoner` → `MyProject.CustomReasoner`
  """
  def resolve_reasoner(entry) when is_atom(entry) do
    Map.get(@reasoner_modules, entry, entry)
  end

  @doc """
  Returns the agent config for the given agent name.

  Merges in order: defaults < .rho.exs agent config < env vars (env wins).
  """
  def agent(name \\ :default) do
    file_config = load_file_config(name)

    config =
      @defaults
      |> Keyword.merge(file_config)

    # Env vars only override when no .rho.exs exists
    config = if file_config == [], do: Keyword.merge(config, env_overrides()), else: config

    %{
      model: config[:model],
      system_prompt: config[:system_prompt],
      mounts: config[:mounts] || [],
      max_steps: config[:max_steps],
      max_tokens: config[:max_tokens],
      provider: config[:provider],
      reasoner: resolve_reasoner(config[:reasoner] || :direct),
      reasoner_opts: config[:reasoner_opts] || [],
      description: config[:description],
      skills: config[:skills] || [],
      prompt_format: config[:prompt_format] || :markdown,
      avatar: config[:avatar]
    }
  end

  @doc "Lists available agent names from .rho.exs."
  def agent_names do
    case load_file() do
      %{} = agents -> Map.keys(agents)
      _ -> [:default]
    end
  end

  @doc "Returns web configuration from environment variables."
  def web do
    %{
      enabled: System.get_env("RHO_WEB_ENABLED", "false") == "true"
    }
  end

  @doc "Returns whether sandbox mode is enabled (RHO_SANDBOX=true)."
  def sandbox_enabled? do
    System.get_env("RHO_SANDBOX", "false") == "true"
  end

  @doc "Returns the configured memory backend module, defaulting to Rho.Memory.Tape."
  def memory_module do
    mod = Application.get_env(:rho, :memory_module, Rho.Memory.Tape)
    Code.ensure_loaded!(mod)
    mod
  end

  @doc """
  Returns the Python/pip configuration for Pythonx.

  Reads `python_deps` from the agent config in `.rho.exs`.
  Returns a list of pip dependency strings (e.g. ["numpy==2.2.2", "pandas"]).
  """
  def python_deps do
    all_agents = agent_names()

    all_agents
    |> Enum.flat_map(fn name ->
      config = load_file_config(name)
      config[:python_deps] || []
    end)
    |> Enum.uniq()
  end

  @doc """
  Loads an agent's avatar as a base64 data URI.

  Resolves the `avatar` field from the agent config in `.rho.exs`.
  Supports `~` expansion. Returns `nil` if not configured or file not found.
  """
  def load_avatar(agent_name) do
    config = agent(agent_name)

    case config[:avatar] do
      nil -> nil
      path -> read_avatar(Path.expand(path))
    end
  rescue
    _ -> nil
  end

  defp read_avatar(path) do
    if File.exists?(path) do
      binary = File.read!(path)
      ext = path |> Path.extname() |> String.trim_leading(".")

      media =
        case ext do
          "jpg" -> "image/jpeg"
          "jpeg" -> "image/jpeg"
          "png" -> "image/png"
          "gif" -> "image/gif"
          "webp" -> "image/webp"
          "svg" -> "image/svg+xml"
          _ -> "image/png"
        end

      "data:#{media};base64,#{Base.encode64(binary)}"
    end
  end

  # -- Private --

  defp load_file_config(name) do
    case load_file() do
      %{} = agents ->
        agents[name] ||
          raise "Agent #{inspect(name)} not found in #{@config_file}. Available: #{inspect(Map.keys(agents))}"

      nil ->
        []
    end
  end

  defp load_file do
    now = System.monotonic_time(:second)

    case :persistent_term.get({__MODULE__, :cache}, nil) do
      {_mtime, result, checked_at} when now - checked_at < 2 ->
        result

      cache ->
        do_load_file(cache, now)
    end
  end

  defp do_load_file(cache, now) do
    path = Path.expand(@config_file)

    case File.stat(path) do
      {:ok, %{mtime: mtime}} ->
        case cache do
          {^mtime, result, _} ->
            :persistent_term.put({__MODULE__, :cache}, {mtime, result, now})
            result

          _ ->
            {result, _} = Code.eval_file(path)
            :persistent_term.put({__MODULE__, :cache}, {mtime, result, now})
            result
        end

      {:error, _} ->
        nil
    end
  end

  defp env_overrides do
    [
      {"RHO_MODEL", :model, &Function.identity/1},
      {"RHO_MAX_STEPS", :max_steps, &String.to_integer/1},
      {"RHO_MAX_TOKENS", :max_tokens, &String.to_integer/1}
    ]
    |> Enum.reduce([], fn {env, key, transform}, acc ->
      case System.get_env(env) do
        nil -> acc
        val -> Keyword.put(acc, key, transform.(val))
      end
    end)
  end
end
