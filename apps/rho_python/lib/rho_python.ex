defmodule RhoPython do
  @moduledoc """
  Owns the pythonx + erlang_python runtime lifecycle for the umbrella.

  ## Pythonx (library Python)

  Consumer apps declare their Python dependencies via `declare_deps/1`,
  typically from their own `Application.start/2`. Initialization is lazy
  — the first call to `await_ready/1` aggregates all currently-declared
  deps into a single pyproject and invokes `Pythonx.uv_init/1`.

  ## erlang_python (stateful agent-loop Python)

  Use `start_erlang_python/2` to start the `:erlang_python` OTP app and
  configure its `sys.path` / env / venv. Idempotent.
  """

  alias RhoPython.Server

  @doc "Declare Python deps (idempotent). Call from consumer Application.start/2."
  @spec declare_deps([String.t()]) :: :ok
  def declare_deps(deps) when is_list(deps), do: Server.declare_deps(deps)

  @doc "Returns true once `Pythonx.uv_init/1` has finished."
  @spec ready?() :: boolean()
  def ready?(), do: Server.ready?()

  @doc """
  Block until pythonx is initialized. Triggers init lazily on first call.

  Subsequent calls return `:ok` immediately. Returns `{:error, :timeout}`
  if init does not complete within the given timeout.
  """
  @spec await_ready(timeout()) :: :ok | {:error, :timeout}
  def await_ready(timeout \\ 30_000), do: Server.await_ready(timeout)

  @doc """
  Start `:erlang_python` and prepare it for use:

    * adds `py_agents_dir` to `sys.path`
    * exports the listed env vars to `os.environ`
    * activates the venv at `RHO_PY_AGENT_VENV` if set

  Idempotent.
  """
  @spec start_erlang_python(Path.t(), [String.t()]) :: :ok
  def start_erlang_python(py_agents_dir, env_keys \\ []),
    do: Server.start_erlang_python(py_agents_dir, env_keys)
end
