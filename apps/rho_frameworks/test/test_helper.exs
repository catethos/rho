Mimic.copy(ReqLLM)
Mimic.copy(RhoFrameworks.LLM.ScoreLens)

ExUnit.start()

# For in-memory SQLite, we need to run migrations before tests
_pid = Ecto.Adapters.SQL.Sandbox.start_owner!(RhoFrameworks.Repo, shared: true)
Ecto.Migrator.run(RhoFrameworks.Repo, :up, all: true)
