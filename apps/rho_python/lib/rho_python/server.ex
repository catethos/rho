defmodule RhoPython.Server do
  @moduledoc false
  # Serializes pythonx + erlang_python initialization across consumer apps.
  #
  # Pythonx init is lazy: `declare_deps/1` only collects deps; the first
  # `await_ready/1` aggregates them into a single pyproject and runs
  # `Pythonx.uv_init/1`. Subsequent calls are cheap (`:persistent_term`
  # check). erlang_python init is similarly idempotent and gated by
  # `start_erlang_python/2`.

  use GenServer

  require Logger

  @ready_key {__MODULE__, :pythonx_ready?}

  # --- Public API ---

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def declare_deps(deps), do: GenServer.call(__MODULE__, {:declare_deps, deps})

  def ready?, do: :persistent_term.get(@ready_key, false)

  def await_ready(timeout) do
    if ready?() do
      :ok
    else
      try do
        GenServer.call(__MODULE__, :init_pythonx, timeout)
      catch
        :exit, {:timeout, _} -> {:error, :timeout}
      end
    end
  end

  def start_erlang_python(py_agents_dir, env_keys),
    do:
      GenServer.call(
        __MODULE__,
        {:start_erlang_python, py_agents_dir, env_keys},
        :timer.minutes(1)
      )

  # --- GenServer ---

  @impl true
  def init(_) do
    {:ok, %{deps: MapSet.new(), pythonx_initialized?: false, erlang_python_initialized?: false}}
  end

  @impl true
  def handle_call({:declare_deps, deps}, _from, state) do
    {:reply, :ok, %{state | deps: MapSet.union(state.deps, MapSet.new(deps))}}
  end

  def handle_call(:init_pythonx, _from, %{pythonx_initialized?: true} = state),
    do: {:reply, :ok, state}

  def handle_call(:init_pythonx, _from, state) do
    deps = state.deps |> MapSet.to_list() |> Enum.sort()
    do_init_pythonx(deps)
    :persistent_term.put(@ready_key, true)
    {:reply, :ok, %{state | pythonx_initialized?: true}}
  end

  def handle_call(
        {:start_erlang_python, _, _},
        _from,
        %{erlang_python_initialized?: true} = state
      ),
      do: {:reply, :ok, state}

  def handle_call({:start_erlang_python, py_agents_dir, env_keys}, _from, state) do
    do_init_erlang_python(py_agents_dir, env_keys)
    {:reply, :ok, %{state | erlang_python_initialized?: true}}
  end

  # --- Pythonx ---

  defp do_init_pythonx(deps) do
    dep_lines = Enum.map_join(deps, "\n", &"  \"#{&1}\",")

    pyproject = """
    [project]
    name = "rho-python"
    version = "0.0.0"
    requires-python = ">=3.11"
    dependencies = [
    #{dep_lines}
    ]
    """

    Logger.info("Initializing Pythonx with deps: #{inspect(deps)}")
    Pythonx.uv_init(pyproject)
  end

  # --- erlang_python ---

  defp do_init_erlang_python(py_agents_dir, env_keys) do
    {:ok, _} = Application.ensure_all_started(:erlang_python)

    :py.exec("""
    import sys, os
    if '#{py_agents_dir}' not in sys.path:
        sys.path.insert(0, '#{py_agents_dir}')
    """)

    export_env_keys_to_python(env_keys)

    venv_path = System.get_env("RHO_PY_AGENT_VENV")

    if venv_path do
      :py.activate_venv(String.to_charlist(venv_path))
    end

    Logger.info("erlang_python initialized, py_agents path: #{py_agents_dir}")
  end

  defp export_env_keys_to_python(env_keys) do
    for key <- env_keys do
      case System.get_env(key) do
        nil ->
          :ok

        val ->
          escaped = String.replace(val, "\\", "\\\\") |> String.replace("'", "\\'")
          :py.exec("os.environ['#{key}'] = '#{escaped}'")
      end
    end
  end
end
