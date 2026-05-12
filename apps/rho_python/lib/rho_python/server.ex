defmodule RhoPython.Server do
  @moduledoc false
  # Owns the umbrella's Python runtime lifecycle.
  #
  # `declare_deps/1` aggregates pip deps from any number of consumer
  # apps. `configure_py_agents/2` registers an optional sys.path dir +
  # env-var export list (used by the `:py_agent` plugin). Both are
  # idempotent and may be called in any order before init.
  #
  # `await_ready/1` runs the (potentially slow) venv build on first
  # call: it ensures `:erlang_python` is started, creates a uv-managed
  # venv at `RHO_PY_VENV` (or a default cache path) if missing,
  # installs declared deps with `uv pip install`, activates the venv
  # under erlang_python, and applies the py_agents configuration.
  # Subsequent calls return `:ok` immediately via `:persistent_term`.

  use GenServer

  require Logger

  @ready_key {__MODULE__, :ready?}

  # --- Public API ---

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def declare_deps(deps), do: GenServer.call(__MODULE__, {:declare_deps, deps})

  def configure_py_agents(py_agents_dir, env_keys),
    do:
      GenServer.call(
        __MODULE__,
        {:configure_py_agents, py_agents_dir, env_keys}
      )

  def ready?, do: :persistent_term.get(@ready_key, false)

  def await_ready(timeout) do
    if ready?() do
      :ok
    else
      try do
        GenServer.call(__MODULE__, :init, timeout)
      catch
        :exit, {:timeout, _} -> {:error, :timeout}
      end
    end
  end

  # --- GenServer ---

  @impl true
  def init(_) do
    {:ok,
     %{
       deps: MapSet.new(),
       py_agents_dir: nil,
       env_keys: [],
       initialized?: false
     }}
  end

  @impl true
  def handle_call({:declare_deps, deps}, _from, state) do
    {:reply, :ok, %{state | deps: MapSet.union(state.deps, MapSet.new(deps))}}
  end

  def handle_call({:configure_py_agents, dir, keys}, _from, state) do
    {:reply, :ok, %{state | py_agents_dir: dir, env_keys: keys}}
  end

  def handle_call(:init, _from, %{initialized?: true} = state),
    do: {:reply, :ok, state}

  def handle_call(:init, _from, state) do
    do_init(state)
    :persistent_term.put(@ready_key, true)
    {:reply, :ok, %{state | initialized?: true}}
  end

  # --- Init pipeline ---

  defp do_init(state) do
    {:ok, _} = Application.ensure_all_started(:erlang_python)

    deps = state.deps |> MapSet.to_list() |> Enum.sort()
    venv = resolve_venv_path()

    if deps != [] do
      build_venv(venv, deps)
    end

    if venv_exists?(venv) do
      :ok = :py.activate_venv(venv)
    end

    if state.py_agents_dir do
      add_to_sys_path(state.py_agents_dir)
      export_env_keys_to_python(state.env_keys)
    end

    Logger.info(
      "RhoPython initialized: venv=#{venv}, deps=#{inspect(deps)}, py_agents_dir=#{inspect(state.py_agents_dir)}"
    )
  end

  defp resolve_venv_path do
    System.get_env("RHO_PY_VENV") ||
      Path.join([cache_root(), "rho", "py_venv"])
  end

  defp cache_root do
    case System.get_env("XDG_CACHE_HOME") do
      nil ->
        case System.user_home() do
          nil -> System.tmp_dir!()
          home -> Path.join(home, ".cache")
        end

      path ->
        path
    end
  end

  defp venv_exists?(venv), do: File.exists?(Path.join(venv, "pyvenv.cfg"))

  defp build_venv(venv, deps) do
    File.mkdir_p!(Path.dirname(venv))

    unless venv_exists?(venv) do
      Logger.info("Creating uv venv at #{venv}")
      {out, status} = System.cmd("uv", ["venv", venv], stderr_to_stdout: true)
      if status != 0, do: raise("uv venv failed (status=#{status}): #{out}")
    end

    Logger.info("Installing Python deps via uv: #{inspect(deps)}")

    {out, status} =
      System.cmd("uv", ["pip", "install", "--python", venv | deps], stderr_to_stdout: true)

    if status != 0, do: raise("uv pip install failed (status=#{status}): #{out}")
  end

  defp add_to_sys_path(dir) do
    :py.exec("""
    import sys
    if '#{dir}' not in sys.path:
        sys.path.insert(0, '#{dir}')
    """)
  end

  defp export_env_keys_to_python(env_keys) do
    for key <- env_keys, val = System.get_env(key), val != nil do
      escaped = val |> String.replace("\\", "\\\\") |> String.replace("'", "\\'")
      :py.exec("import os; os.environ['#{key}'] = '#{escaped}'")
    end
  end
end
