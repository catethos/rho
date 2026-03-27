defmodule Rho.Sim.Runner do
  @moduledoc """
  Monte Carlo ensemble runner — executes multiple simulation runs in parallel
  with deterministic seed derivation, per-run reduction, and optional aggregation.
  """

  alias Rho.Sim.Engine

  @spec run_many(keyword()) :: {:ok, map()} | {:error, term()}
  def run_many(opts) do
    domain = Keyword.fetch!(opts, :domain)
    domain_opts = Keyword.fetch!(opts, :domain_opts)
    policies = Keyword.fetch!(opts, :policies)
    runs = Keyword.fetch!(opts, :runs)
    reduce = Keyword.fetch!(opts, :reduce)
    aggregate = Keyword.get(opts, :aggregate)
    base_seed = Keyword.get(opts, :base_seed, :erlang.monotonic_time())
    max_steps = Keyword.get(opts, :max_steps, 100)
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())
    interventions = Keyword.get(opts, :interventions, %{})
    params = Keyword.get(opts, :params, %{})
    keep_trace? = Keyword.get(opts, :keep_trace?, false)
    timeout = Keyword.get(opts, :timeout, 60_000)

    {task_sup, started?} =
      case Keyword.get(opts, :task_supervisor) do
        nil -> start_temp_supervisor()
        sup -> {sup, false}
      end

    try do
      results =
        Task.Supervisor.async_stream_nolink(
          task_sup,
          0..(runs - 1),
          fn run_index ->
            seed = :erlang.phash2({base_seed, run_index})

            case Engine.new(domain,
                   domain_opts: domain_opts,
                   policies: policies,
                   seed: seed,
                   max_steps: max_steps,
                   interventions: interventions,
                   params: params
                 ) do
              {:ok, {run, acc}} ->
                case Engine.run(run, acc) do
                  {:halted, {final_run, final_acc}} ->
                    final_acc = maybe_clear_trace(final_acc, keep_trace?)
                    {:completed, run_index, {final_run, final_acc}}

                  {:error, {_step, error, _run, _acc}} ->
                    {:failed, run_index, error}
                end

              {:error, reason} ->
                {:failed, run_index, reason}
            end
          end,
          max_concurrency: max_concurrency,
          timeout: timeout
        )
        |> Enum.to_list()

      {completed, failed} = partition_results(results, runs)

      reduced =
        Enum.map(completed, fn {_idx, run_acc} ->
          reduce.(run_acc)
        end)

      agg = if aggregate, do: aggregate.(reduced), else: nil

      {:ok,
       %{
         completed: reduced,
         failed: failed,
         total: runs,
         success_count: length(reduced),
         failure_count: length(failed),
         aggregate: agg
       }}
    after
      if started?, do: Supervisor.stop(task_sup)
    end
  end

  # --- Private helpers ---

  defp start_temp_supervisor do
    {:ok, pid} = Task.Supervisor.start_link()
    {pid, true}
  end

  defp maybe_clear_trace(acc, true = _keep), do: acc
  defp maybe_clear_trace(acc, false = _keep), do: %{acc | trace: []}

  defp partition_results(results, _runs) do
    Enum.reduce(results, {[], []}, fn
      {:ok, {:completed, idx, run_acc}}, {completed, failed} ->
        {[{idx, run_acc} | completed], failed}

      {:ok, {:failed, idx, reason}}, {completed, failed} ->
        {completed, [{idx, reason} | failed]}

      {:exit, reason}, {completed, failed} ->
        # Task crashed — we don't know the run_index, use -1 as sentinel
        {completed, [{-1, reason} | failed]}
    end)
    |> then(fn {completed, failed} ->
      {Enum.sort_by(completed, &elem(&1, 0)), Enum.sort_by(failed, &elem(&1, 0))}
    end)
  end
end
