defmodule RhoFrameworks.Accounts.TokenSweeper do
  @moduledoc """
  Periodically deletes expired rows from `users_tokens`.

  `UserToken.verify_session_token_query/1` already filters out tokens older
  than 60 days at read time, so expired rows are *functionally* dead —
  but they accumulate indefinitely without a sweeper, bloating the table
  and its indexes.

  A plain GenServer is deliberate: we have exactly one periodic chore and
  are on SQLite, so adding Oban (plus its `oban_jobs` table and cron config)
  would be wildly disproportionate. If this file grows a second or third
  periodic job, reconsider.

  ## Timing

  Runs once 1 minute after boot (to avoid racing with migrations in dev),
  then every 24 hours. The sweep itself is a single `DELETE` — it does not
  paginate, since at our scale (one row per login per user per 60 days)
  the table will never be large enough to matter.
  """

  use GenServer
  require Logger

  import Ecto.Query

  alias RhoFrameworks.Accounts.UserToken
  alias RhoFrameworks.Repo

  @sweep_interval :timer.hours(24)
  @initial_delay :timer.minutes(1)
  @retention_days 60

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Run the sweep synchronously. Returns `{:ok, deleted_count}`."
  def sweep_now do
    GenServer.call(__MODULE__, :sweep, :timer.seconds(30))
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :sweep, @initial_delay)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    do_sweep()
    Process.send_after(self(), :sweep, @sweep_interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    {:reply, do_sweep(), state}
  end

  defp do_sweep do
    {count, _} =
      Repo.delete_all(from(t in UserToken, where: t.inserted_at < ago(^@retention_days, "day")))

    if count > 0 do
      Logger.info("TokenSweeper: deleted #{count} expired user_tokens row(s)")
    end

    {:ok, count}
  rescue
    err ->
      # Never crash the sweeper — log and try again next interval. A DB hiccup
      # shouldn't take down the supervisor chain or spam restarts.
      Logger.error("TokenSweeper: sweep failed: #{inspect(err)}")
      {:error, err}
  end
end
