defmodule Rho.SessionTest do
  use ExUnit.Case, async: false

  setup do
    :ok
  end

  describe "ensure_started/2" do
    test "starts a new session" do
      session_id = "test-#{System.unique_integer([:positive])}"
      {:ok, pid} = Rho.Session.ensure_started(session_id)

      assert is_pid(pid)
      assert Process.alive?(pid)
      assert pid == Rho.Session.whereis(session_id)
    end

    test "returns existing session on repeated calls" do
      session_id = "test-#{System.unique_integer([:positive])}"
      {:ok, pid1} = Rho.Session.ensure_started(session_id)
      {:ok, pid2} = Rho.Session.ensure_started(session_id)

      assert pid1 == pid2
    end
  end

  describe "whereis/1" do
    test "returns nil for unknown session" do
      assert nil == Rho.Session.whereis("nonexistent-#{System.unique_integer([:positive])}")
    end

    test "returns pid for active session" do
      session_id = "test-#{System.unique_integer([:positive])}"
      {:ok, pid} = Rho.Session.ensure_started(session_id)

      assert pid == Rho.Session.whereis(session_id)
    end
  end

  describe "info/1" do
    test "returns session metadata and tape stats" do
      session_id = "test-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Rho.Session.ensure_started(session_id)

      info = Rho.Session.info(session_id)

      assert info.session_id == session_id
      assert is_binary(info.tape_name)
      assert info.agent_name == :default
      assert is_map(info.tape)
      assert info.tape.anchor_count >= 1
    end
  end

  describe "subscribe/unsubscribe" do
    test "subscribe and unsubscribe work" do
      session_id = "test-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Rho.Session.ensure_started(session_id)

      assert :ok = Rho.Session.subscribe(session_id)
      assert :ok = Rho.Session.unsubscribe(session_id)
    end

    test "duplicate subscribe is idempotent" do
      session_id = "test-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Rho.Session.ensure_started(session_id)

      assert :ok = Rho.Session.subscribe(session_id)
      assert :ok = Rho.Session.subscribe(session_id)
      assert :ok = Rho.Session.unsubscribe(session_id)
    end
  end

  describe "resolve_id/1" do
    test "uses explicit session_id when provided" do
      assert "my-session" = Rho.Session.resolve_id(session_id: "my-session")
    end

    test "defaults to channel:chat_id" do
      assert "cli:default" = Rho.Session.resolve_id([])
      assert "telegram:123" = Rho.Session.resolve_id(channel: "telegram", chat_id: "123")
    end

    test "falls back to channel:chat_id when no tape_name in context" do
      assert "cli:default" = Rho.Session.resolve_id(channel: "cli", chat_id: "default")
    end
  end

  describe "list/1" do
    test "lists sessions with prefix filter" do
      s1 = "list-test:#{System.unique_integer([:positive])}"
      s2 = "list-test:#{System.unique_integer([:positive])}"
      s3 = "other:#{System.unique_integer([:positive])}"

      {:ok, _} = Rho.Session.ensure_started(s1)
      {:ok, _} = Rho.Session.ensure_started(s2)
      {:ok, _} = Rho.Session.ensure_started(s3)

      results = Rho.Session.list(prefix: "list-test:")
      ids = Enum.map(results, & &1.session_id)

      assert s1 in ids
      assert s2 in ids
      refute s3 in ids
    end
  end
end
