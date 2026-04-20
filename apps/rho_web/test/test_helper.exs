ExUnit.start()

# rho_frameworks Repo is needed for LiveViews that hit the DB
# When running the full umbrella suite, rho_frameworks tests may have already
# started the sandbox owner — guard against :already_shared.
try do
  Ecto.Adapters.SQL.Sandbox.start_owner!(RhoFrameworks.Repo, shared: true)
rescue
  MatchError -> :ok
end

Ecto.Migrator.run(RhoFrameworks.Repo, :up, all: true)
