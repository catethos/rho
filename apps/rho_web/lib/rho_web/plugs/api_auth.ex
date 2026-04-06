defmodule RhoWeb.Plugs.APIAuth do
  @moduledoc """
  Bearer token authentication for the Observatory API.

  Set the `RHO_API_TOKEN` environment variable to enable authentication.
  When the variable is unset, all requests are allowed (dev mode).
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case System.get_env("RHO_API_TOKEN") do
      nil ->
        # No token configured — allow all (dev mode)
        conn

      expected_token ->
        case get_req_header(conn, "authorization") do
          ["Bearer " <> token] when token == expected_token ->
            conn

          _ ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
            |> halt()
        end
    end
  end
end
