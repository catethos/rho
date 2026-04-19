defmodule Rho.CLI.Config do
  @moduledoc """
  Full config loader for the CLI. Reads `.rho.exs`, normalizes
  legacy keys (`mounts:` -> `plugins:`, `reasoner:` -> `turn_strategy:`),
  and provides agent config queries.
  """

  @config_file ".rho.exs"

  @defaults [
    model: "openrouter:anthropic/claude-sonnet",
    system_prompt: "You are a helpful assistant.",
    plugins: [:bash],
    max_steps: 50,
    max_tokens: 4096,
    turn_strategy: :direct,
    prompt_format: :markdown
  ]

  @turn_strategy_modules %{
    direct: Rho.TurnStrategy.Direct,
    typed_structured: Rho.TurnStrategy.TypedStructured
  }

  @doc """
  Resolves a turn-strategy entry to a module.

  Accepts:
  - An atom shorthand: `:direct` -> `Rho.TurnStrategy.Direct`
  - A module: `MyProject.CustomStrategy` -> `MyProject.CustomStrategy`
  """
  def resolve_turn_strategy(entry) when is_atom(entry) do
    Map.get(@turn_strategy_modules, entry, entry)
  end

  @doc """
  Returns the agent config for the given agent name.

  Merges in order: defaults < .rho.exs agent config < env vars (env wins).
  Normalizes legacy keys: `mounts:` -> `plugins:`, `reasoner:` -> `turn_strategy:`.
  """
  def agent(name \\ :default) do
    file_config = load_file_config(name) |> normalize_keys()

    config =
      @defaults
      |> Keyword.merge(file_config)

    # Env vars only override when no .rho.exs exists
    config = if file_config == [], do: Keyword.merge(config, env_overrides()), else: config

    %{
      model: config[:model],
      system_prompt: config[:system_prompt],
      plugins: config[:plugins] || [],
      max_steps: config[:max_steps],
      max_tokens: config[:max_tokens],
      provider: config[:provider],
      turn_strategy:
        resolve_turn_strategy(config[:turn_strategy] || config[:reasoner] || :direct),
      turn_strategy_opts: config[:turn_strategy_opts] || config[:reasoner_opts] || [],
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

  @doc "Returns Python/pip deps from all agent configs."
  def python_deps do
    agent_names()
    |> Enum.flat_map(fn name ->
      config = load_file_config(name)
      config[:python_deps] || []
    end)
    |> Enum.uniq()
  end

  @doc "Loads an agent's avatar as a base64 data URI."
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

  # Normalize legacy config keys to canonical names
  defp normalize_keys(config) do
    config
    |> normalize_key(:mounts, :plugins)
    |> normalize_key(:reasoner, :turn_strategy)
    |> normalize_key(:tape_module, :tape_module)
  end

  defp normalize_key(config, old_key, new_key) do
    case {Keyword.fetch(config, old_key), Keyword.fetch(config, new_key)} do
      {{:ok, val}, :error} ->
        config |> Keyword.delete(old_key) |> Keyword.put(new_key, val)

      _ ->
        config
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
