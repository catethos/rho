defmodule Rho.Stdlib.Uploads.SessionJanitor do
  @moduledoc """
  Listens for `:agent_stopped` events and shuts down the matching
  `Rho.Stdlib.Uploads.Server`. Mirrors `Rho.Stdlib.DataTable.SessionJanitor`.
  """

  use GenServer

  alias Rho.Events.Event
  alias Rho.Stdlib.Uploads.Server, as: Uploads

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Rho.Events.subscribe_lifecycle()
    {:ok, %{}}
  end

  @impl true
  def handle_info(%Event{kind: :agent_stopped, data: data}, state) do
    with true <- primary_agent?(data),
         session_id when is_binary(session_id) <- session_id_of(data) do
      Uploads.stop(session_id)
    end

    {:noreply, state}
  end

  def handle_info(%Event{}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # Mirror Rho.Stdlib.DataTable.SessionJanitor exactly. The Worker publishes
  # :agent_stopped with data: %{} (no primary? flag), so we MUST default to
  # true — otherwise the janitor never fires in production while tests pass.
  defp primary_agent?(%{primary?: true}), do: true
  defp primary_agent?(%{"primary?" => true}), do: true
  defp primary_agent?(%{primary: true}), do: true
  defp primary_agent?(%{"primary" => true}), do: true
  defp primary_agent?(%{primary?: false}), do: false
  defp primary_agent?(%{"primary?" => false}), do: false
  defp primary_agent?(%{primary: false}), do: false
  defp primary_agent?(%{"primary" => false}), do: false
  defp primary_agent?(_), do: true

  defp session_id_of(%{session_id: sid}) when is_binary(sid), do: sid
  defp session_id_of(%{"session_id" => sid}) when is_binary(sid), do: sid
  defp session_id_of(_), do: nil
end
