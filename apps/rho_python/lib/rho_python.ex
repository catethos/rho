defmodule RhoPython do
  @moduledoc """
  Owns the umbrella's Python runtime lifecycle.

  Python is embedded into the BEAM via `:erlang_python`. Consumer apps
  declare their pip deps with `declare_deps/1` (typically from their
  own `Application.start/2`). Initialization is lazy — the first call
  to `await_ready/1` builds a uv-managed venv from the aggregated dep
  list, activates it under erlang_python, and (if `configure_py_agents/2`
  was called) wires up a sys.path dir + env-var exports for the
  `:py_agent` plugin.

  The venv path comes from `$RHO_PY_VENV` (falls back to a cache dir
  under `$XDG_CACHE_HOME`). Re-running over an existing venv is a fast
  no-op — `uv pip install` skips already-installed packages.
  """

  alias RhoPython.Server

  @doc "Declare pip deps (idempotent). Call from consumer Application.start/2."
  @spec declare_deps([String.t()]) :: :ok
  def declare_deps(deps) when is_list(deps), do: Server.declare_deps(deps)

  @doc "Returns true once the shared venv is built and activated."
  @spec ready?() :: boolean()
  def ready?(), do: Server.ready?()

  @doc """
  Block until init completes (builds the venv on first call).
  Subsequent calls return `:ok` cheaply. Returns `{:error, :timeout}`
  if init does not complete within the given timeout.
  """
  @spec await_ready(timeout()) :: :ok | {:error, :timeout}
  def await_ready(timeout \\ 30_000), do: Server.await_ready(timeout)

  @doc """
  Register a directory to expose on Python's `sys.path` and a list of
  env vars to re-export to `os.environ` during init. Call BEFORE
  `await_ready/1` so the configuration is applied during initialization.
  Idempotent.
  """
  @spec configure_py_agents(Path.t(), [String.t()]) :: :ok
  def configure_py_agents(py_agents_dir, env_keys \\ []),
    do: Server.configure_py_agents(py_agents_dir, env_keys)
end
