defmodule RhoWeb.ObservatoryAPITest do
  @moduledoc """
  Tests for RhoWeb.ObservatoryAPI — HTTP routing and response format.
  """

  use ExUnit.Case, async: false
  use Plug.Test

  alias RhoWeb.ObservatoryAPI

  defp call(method, path, body \\ nil) do
    conn =
      conn(method, path)
      |> put_req_header("content-type", "application/json")
      |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))

    conn =
      if body do
        %{conn | body_params: body}
      else
        conn
      end

    ObservatoryAPI.call(conn, ObservatoryAPI.init([]))
  end

  defp json_body(conn) do
    Jason.decode!(conn.resp_body)
  end

  describe "GET /health" do
    test "returns ok status" do
      conn = call(:get, "/health")
      assert conn.status == 200

      body = json_body(conn)
      assert body["status"] == "ok"
      assert body["observatory"] == true
    end
  end

  describe "GET /sessions" do
    test "returns sessions list" do
      conn = call(:get, "/sessions")
      assert conn.status == 200

      body = json_body(conn)
      assert is_list(body["sessions"])
    end
  end

  describe "GET /sessions/:id/metrics" do
    test "returns metrics for unknown session" do
      conn = call(:get, "/sessions/nonexistent/metrics")
      assert conn.status == 200

      body = json_body(conn)
      assert body["session_id"] == "nonexistent"
      assert body["total_tokens"] == 0
    end
  end

  describe "GET /sessions/:id/events" do
    test "returns events list" do
      conn = call(:get, "/sessions/nonexistent/events")
      assert conn.status == 200

      body = json_body(conn)
      assert body["session_id"] == "nonexistent"
      assert is_list(body["events"])
    end
  end

  describe "GET /sessions/:id/signals" do
    test "returns signal flow" do
      conn = call(:get, "/sessions/nonexistent/signals")
      assert conn.status == 200

      body = json_body(conn)
      assert is_list(body["flows"])
    end
  end

  describe "GET /sessions/:id/diagnose" do
    test "returns diagnostics" do
      conn = call(:get, "/sessions/nonexistent/diagnose")
      assert conn.status == 200

      body = json_body(conn)
      assert body["session_id"] == "nonexistent"
      assert is_list(body["issues"])
    end
  end

  describe "GET /agents/:id/metrics" do
    test "returns empty metrics for unknown agent" do
      conn = call(:get, "/agents/nonexistent/metrics")
      assert conn.status == 200

      body = json_body(conn)
      assert body["agent_id"] == "nonexistent"
    end
  end

  describe "unknown routes" do
    test "returns 404" do
      conn = call(:get, "/nonexistent/route")
      assert conn.status == 404

      body = json_body(conn)
      assert body["error"] == "not_found"
    end
  end

  describe "POST /sessions" do
    test "creates a new session" do
      session_id = "api_test_#{System.unique_integer([:positive])}"

      conn = call(:post, "/sessions", %{"session_id" => session_id})
      assert conn.status == 200

      body = json_body(conn)
      assert body["session_id"] == session_id
      assert body["status"] == "started"

      on_exit(fn ->
        try do
          Rho.Session.stop(session_id)
        catch
          _, _ -> :ok
        end
      end)
    end
  end

  describe "POST /sessions/:id/submit" do
    test "submits a message to a session" do
      session_id = "api_submit_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Rho.Session.ensure_started(session_id)

      conn = call(:post, "/sessions/#{session_id}/submit", %{"message" => "hello"})
      assert conn.status == 200

      body = json_body(conn)
      assert body["status"] == "submitted"
      assert is_binary(body["turn_id"])

      on_exit(fn ->
        try do
          Rho.Session.stop(session_id)
        catch
          _, _ -> :ok
        end
      end)
    end
  end
end
