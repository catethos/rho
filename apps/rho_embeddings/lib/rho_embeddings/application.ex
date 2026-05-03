defmodule RhoEmbeddings.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Default backend is now `RhoEmbeddings.Backend.OpenAI` (HTTP) — the
    # fastembed/Pillow stack hits a Python 3.13 _imaging ABI break on
    # macOS arm64 that Pillow 11.x doesn't fix and fastembed 0.7.3 caps
    # below Pillow 12. Re-enable Pythonx + fastembed by configuring
    # `backend: RhoEmbeddings.Backend.Pythonx` and uncommenting the
    # declare_deps below once the upstream wheel ships.
    #
    # :ok = RhoPython.declare_deps(["fastembed==0.7.3", "numpy>=2.0"])

    children = [RhoEmbeddings.Server]
    Supervisor.start_link(children, strategy: :one_for_one, name: RhoEmbeddings.Supervisor)
  end
end
