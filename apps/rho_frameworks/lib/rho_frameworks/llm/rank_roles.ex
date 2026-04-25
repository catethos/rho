defmodule RhoFrameworks.LLM.RankRoles do
  @moduledoc """
  BAML-backed LLM function for ranking roles by semantic similarity.

  Given a query and a numbered list of existing role profiles, returns
  the 1-based indices of the most similar roles ordered by relevance.

  Replaces the `ReqLLM.generate_object` call in `RhoFrameworks.Roles.rank_similar_via_llm/3`.
  """
  use RhoBaml.Function,
    client: "OpenRouter",
    params: [query: :string, role_list: :string, limit: :int]

  @schema Zoi.struct(__MODULE__, %{
            indices:
              Zoi.array(Zoi.integer(),
                description:
                  "1-based indices of the most similar roles from the list, ordered by relevance"
              )
          })

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)
  @type t :: unquote(Zoi.type_spec(@schema))

  @prompt ~S"""
  {{ _.role("system") }}
  You are a role matching assistant. Given a query and a numbered list of existing role profiles,
  return the numbers of the most similar roles ordered by relevance.
  Consider semantic similarity — e.g. "Software Engineer" matches "Backend Developer",
  "Full Stack Engineer", etc. Return at most {{limit}} numbers.
  Only return numbers that appear in the list. If nothing is similar, return an empty array.

  {{ _.role("user") }}
  Query: {{query}}

  Existing roles:
  {{role_list}}

  {{ ctx.output_format }}
  """
end
