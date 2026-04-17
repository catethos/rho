defmodule RhoWeb.RemoteIpHelper do
  @moduledoc """
  Resolves a client IP string from a LiveView socket, mirroring the trust
  boundary applied by the `RemoteIp` plug on the controller side.

  ## Why this exists

  `RemoteIp` (plugged in the endpoint) rewrites `conn.remote_ip` from
  `Fly-Client-IP` before the router runs, so plug-based rate limiting
  sees the real client. Sockets bypass that path — `connect_info[:peer_data]`
  always holds the raw TCP peer (the Fly proxy in prod). For LiveView
  rate limiting to key on the same identity, we have to read the
  forwarded header off `:x_headers` ourselves.

  ## Trust boundary

  The `Fly-Client-IP` header is only honoured when `MIX_ENV=prod` at
  compile time. In dev/test a locally-exposed server would otherwise
  let an attacker spoof IPs by setting the header.
  """

  @trust_fly_header Mix.env() == :prod

  @doc """
  Returns the best-effort client IP for a LiveView socket, as a string.

  Returns `"unknown"` on the initial static mount (before the websocket
  has connected) — that's fine for rate limiting because `handle_event`
  callbacks only fire post-connect.
  """
  def from_socket(socket) do
    if Phoenix.LiveView.connected?(socket) do
      fly_header_ip(socket) || peer_data_ip(socket) || "unknown"
    else
      "unknown"
    end
  end

  if @trust_fly_header do
    defp fly_header_ip(socket) do
      case Phoenix.LiveView.get_connect_info(socket, :x_headers) do
        headers when is_list(headers) ->
          Enum.find_value(headers, fn
            {"fly-client-ip", value} -> value
            _ -> nil
          end)

        _ ->
          nil
      end
    end
  else
    defp fly_header_ip(_socket), do: nil
  end

  defp peer_data_ip(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
      %{address: addr} -> addr |> :inet.ntoa() |> to_string()
      _ -> nil
    end
  end
end
