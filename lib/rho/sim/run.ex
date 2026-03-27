defmodule Rho.Sim.Run do
  @type t :: %__MODULE__{}

  defstruct [
    :run_id,
    :domain,          # module implementing Rho.Sim.Domain
    :domain_state,    # opaque — whatever domain.init/1 returned
    :policies,        # %{actor_id => {module, keyword()}} — normalized
    :policy_states,   # %{actor_id => term()} — policy-local state per actor
    :rng,             # :rand.state()
    :seed,            # original seed (integer) for reproducibility
    :max_steps,       # hard stop
    interventions: %{},  # %{pos_integer() => [term()]}
    params: %{},         # immutable user-supplied config → Context
    step: 0
  ]
  # No `status` field — the return tags from step/2 and run/2 encode status.
end
