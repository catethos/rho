defmodule Rho.Tape.Context.Tape do
  @moduledoc "Tape-context projection backed by the existing tape system."
  @behaviour Rho.Tape.Context

  alias Rho.Tape.{Service, View, Compact, Fork, Store}

  @impl true
  def memory_ref(session_id, workspace), do: Service.session_tape(session_id, workspace)

  @impl true
  def bootstrap(tape_name), do: Service.ensure_bootstrap_anchor(tape_name)

  @impl true
  def append(tape_name, kind, payload, meta \\ %{}),
    do: Service.append(tape_name, kind, payload, meta)

  @impl true
  def append_from_event(tape_name, event), do: Service.append_from_event(tape_name, event)

  @impl true
  def build_context(tape_name) do
    view = View.default(tape_name)
    View.to_messages(view)
  end

  @impl true
  def info(tape_name), do: Service.info(tape_name)

  @impl true
  def history(tape_name), do: Service.history(tape_name)

  @impl true
  def reset(tape_name, opts \\ []) do
    archive = Keyword.get(opts, :archive, false)
    Service.reset(tape_name, archive)
  end

  @impl true
  def compact_if_needed(tape_name, opts), do: Compact.run_if_needed(tape_name, opts)

  @impl true
  def fork(tape_name, opts), do: Fork.fork(tape_name, opts)

  @impl true
  def merge(fork_tape, main_tape), do: Fork.merge(fork_tape, main_tape)

  @impl true
  def children(_opts), do: [Store]
end
