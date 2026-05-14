defmodule Rho.Session do
  @moduledoc """
  Programmatic session API — the single entry point for all frontends.

  CLI, web, tests, and livebook all use this module to interact with agents.
  Wraps `Rho.Agent.Primary` (lifecycle) and `Rho.Agent.Worker` (turns).
  """

  alias Rho.Agent.{Primary, Worker}
  alias Rho.Session.Handle

  @type handle :: %Handle{}

  @doc """
  Start a new agent session.

  ## Options

    * `:session_id` — explicit session ID (auto-generated if omitted)
    * `:agent` — agent config name (default: `:default`)
    * `:workspace` — working directory (default: `File.cwd!()`)
    * `:emit` — `(map() -> :ok)` event callback
    * `:user_id` — for multi-tenant scoping
    * `:organization_id` — for multi-tenant scoping
    * `:conversation_id` — durable conversation id for trace metadata
    * `:thread_id` — durable thread id for trace metadata
    * `:tape_ref` — explicit tape reference
    * `:run_spec` — explicit `%Rho.RunSpec{}` (skips config loading)

  Returns `{:ok, %Handle{}}` or `{:error, reason}`.
  """
  @spec start(keyword()) :: {:ok, handle()} | {:error, term()}
  def start(opts \\ []) do
    session_id = opts[:session_id] || generate_session_id()
    agent_name = opts[:agent] || :default

    # Build or accept a RunSpec
    run_spec = opts[:run_spec] || build_run_spec(agent_name, opts)

    primary_opts =
      [agent_name: agent_name]
      |> maybe_put(:workspace, opts[:workspace])
      |> maybe_put(:user_id, opts[:user_id])
      |> maybe_put(:organization_id, opts[:organization_id])
      |> maybe_put(:conversation_id, opts[:conversation_id])
      |> maybe_put(:thread_id, opts[:thread_id])
      |> maybe_put(:tape_ref, opts[:tape_ref])
      |> maybe_put(:run_spec, run_spec)

    case Primary.ensure_started(session_id, primary_opts) do
      {:ok, pid} ->
        handle = %Handle{
          session_id: session_id,
          primary_pid: pid,
          emit: opts[:emit]
        }

        {:ok, handle}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Send a message synchronously — blocks until the turn completes.

  Returns `{:ok, text}`, `{:final, value}`, or `{:error, reason}`.
  """
  @spec send(handle(), String.t(), keyword()) ::
          {:ok, String.t()} | {:final, term()} | {:error, term()}
  def send(%Handle{} = handle, content, opts \\ []) do
    pid = resolve_pid(handle)
    Worker.ask(pid, content, opts)
  end

  @doc """
  Send a message asynchronously — returns immediately.

  Events are delivered via the signal bus or the `:emit` callback.
  Returns `{:ok, turn_id}`.
  """
  @spec send_async(handle(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def send_async(%Handle{} = handle, content, opts \\ []) do
    pid = resolve_pid(handle)
    Worker.submit(pid, content, opts)
  end

  @doc """
  Get session info (agent status, capabilities, etc.).
  """
  @spec info(handle()) :: map()
  def info(%Handle{} = handle) do
    pid = resolve_pid(handle)
    Worker.info(pid)
  end

  @doc """
  Stop the session and all its agents.
  """
  @spec stop(handle()) :: :ok
  def stop(%Handle{session_id: session_id}) do
    Primary.stop(session_id)
  end

  # -- Private --

  defp resolve_pid(%Handle{session_id: session_id, primary_pid: pid}) do
    if Process.alive?(pid), do: pid, else: Primary.whereis(session_id)
  end

  # Crypto-random so an attacker can't enumerate or guess another user's
  # session by incrementing a counter. 12 bytes of url-safe base64 is
  # 16 chars — same bit-strength budget as a typical session cookie.
  defp generate_session_id do
    "ses_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  defp build_run_spec(agent_name, opts) do
    Rho.RunSpec.FromConfig.build(agent_name, opts)
  end

  defp maybe_put(kwl, _key, nil), do: kwl
  defp maybe_put(kwl, key, value), do: Keyword.put(kwl, key, value)
end
