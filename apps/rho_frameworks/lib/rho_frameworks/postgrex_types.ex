Postgrex.Types.define(
  RhoFrameworks.PostgrexTypes,
  [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
  json: Jason
)
