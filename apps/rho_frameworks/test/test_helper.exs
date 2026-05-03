Mimic.copy(ReqLLM)
Mimic.copy(RhoFrameworks.LLM.ScoreLens)
Mimic.copy(RhoFrameworks.LLM.SemanticDuplicates)

ExUnit.start()

# Postgres SQL.Sandbox: migrate first, then claim a single shared connection
# owner so all (non-async) tests see the same transaction. Changes roll back
# at the end of the run.
Ecto.Migrator.run(RhoFrameworks.Repo, :up, all: true)
_pid = Ecto.Adapters.SQL.Sandbox.start_owner!(RhoFrameworks.Repo, shared: true)
