defmodule RhoFrameworks.UseCases.ResearchDomain do
  @moduledoc """
  Exa-backed UseCase that pulls domain context into the session before
  structured framework generation runs.

  The use case is deliberately synchronous and does not call an LLM. UI
  callers decide whether to run it in a task; this module only writes bounded,
  pinned Exa summaries into the session's `research_notes` named table.
  """

  @behaviour RhoFrameworks.UseCase

  alias RhoFrameworks.Scope
  alias RhoFrameworks.UseCases.ResearchDomain.Insert

  @impl true
  def describe do
    %{
      id: :research_domain,
      label: "Research the domain",
      cost_hint: :network,
      doc: "Calls Exa directly and writes pinned summaries into research_notes before generation."
    }
  end

  @impl true
  def run(input, %Scope{session_id: session_id}) when is_binary(session_id) do
    Insert.run(input, session_id, :flow)
  end

  def run(_input, %Scope{}), do: {:error, :missing_session_id}

  @doc "Canonical research table used by research panels and generation input."
  @spec table_name() :: String.t()
  def table_name, do: Insert.table_name()
end
