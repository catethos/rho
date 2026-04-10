ExUnit.start()

# rho_frameworks Repo is needed for LiveViews that hit the DB
_pid = Ecto.Adapters.SQL.Sandbox.start_owner!(RhoFrameworks.Repo, shared: true)
Ecto.Migrator.run(RhoFrameworks.Repo, :up, all: true)
