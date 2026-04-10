defmodule FakeTapeModule do
  @moduledoc false
  def fork(source_tape, opts \\ []) do
    suffix = :erlang.unique_integer([:positive])
    fork_name = "#{source_tape}_fork_#{suffix}"
    # Store opts so tests can verify fork_point was passed
    Process.put(:last_fork_opts, opts)
    {:ok, fork_name}
  end
end

defmodule RhoWeb.Session.ThreadsTest do
  use ExUnit.Case, async: true

  alias RhoWeb.Session.Threads

  @session_id "test-threads-session"

  setup do
    # Use a temp directory as workspace so tests don't pollute the real workspace
    workspace =
      Path.join(System.tmp_dir!(), "rho_threads_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace) end)

    %{workspace: workspace}
  end

  # -------------------------------------------------------------------
  # init/3
  # -------------------------------------------------------------------

  describe "init/3" do
    test "creates threads.json with implicit Main thread", %{workspace: ws} do
      {:ok, state} = Threads.init(@session_id, ws, tape_name: "session_abc_def")

      assert state["active_thread_id"] == "thread_main"
      assert length(state["threads"]) == 1

      [main] = state["threads"]
      assert main["id"] == "thread_main"
      assert main["name"] == "Main"
      assert main["tape_name"] == "session_abc_def"
      assert main["status"] == "active"
      assert main["forked_from"] == nil
      assert main["fork_point"] == nil
      assert is_binary(main["created_at"])
    end

    test "is a no-op if threads.json already exists", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_1")
      {:ok, state} = Threads.init(@session_id, ws, tape_name: "tape_2")

      # Still points at original tape, not the new one
      [main] = state["threads"]
      assert main["tape_name"] == "tape_1"
    end

    test "raises if tape_name not provided", %{workspace: ws} do
      assert_raise KeyError, fn ->
        Threads.init(@session_id, ws, [])
      end
    end
  end

  # -------------------------------------------------------------------
  # list/2
  # -------------------------------------------------------------------

  describe "list/2" do
    test "returns empty list when no registry exists", %{workspace: ws} do
      assert Threads.list("nonexistent", ws) == []
    end

    test "returns all threads after init", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_1")
      threads = Threads.list(@session_id, ws)

      assert length(threads) == 1
      assert hd(threads)["id"] == "thread_main"
    end

    test "returns multiple threads after create", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_1")

      {:ok, _} =
        Threads.create(@session_id, ws, %{
          "name" => "Fork A",
          "tape_name" => "tape_fork_a"
        })

      threads = Threads.list(@session_id, ws)
      assert length(threads) == 2
    end
  end

  # -------------------------------------------------------------------
  # active/2
  # -------------------------------------------------------------------

  describe "active/2" do
    test "returns nil when no registry exists", %{workspace: ws} do
      assert Threads.active("nonexistent", ws) == nil
    end

    test "returns the Main thread after init", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_1")
      thread = Threads.active(@session_id, ws)

      assert thread["id"] == "thread_main"
      assert thread["name"] == "Main"
    end

    test "returns switched thread after switch", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_1")

      {:ok, fork} =
        Threads.create(@session_id, ws, %{
          "name" => "Fork",
          "tape_name" => "tape_fork"
        })

      :ok = Threads.switch(@session_id, ws, fork["id"])

      active = Threads.active(@session_id, ws)
      assert active["id"] == fork["id"]
      assert active["name"] == "Fork"
    end
  end

  # -------------------------------------------------------------------
  # get/3
  # -------------------------------------------------------------------

  describe "get/3" do
    test "returns nil when no registry exists", %{workspace: ws} do
      assert Threads.get("nonexistent", ws, "thread_main") == nil
    end

    test "returns nil for unknown thread_id", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_1")
      assert Threads.get(@session_id, ws, "thread_nonexistent") == nil
    end

    test "returns thread by ID", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_1")
      thread = Threads.get(@session_id, ws, "thread_main")

      assert thread["id"] == "thread_main"
      assert thread["tape_name"] == "tape_1"
    end
  end

  # -------------------------------------------------------------------
  # create/3
  # -------------------------------------------------------------------

  describe "create/3" do
    test "adds a thread to the registry", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_1")

      {:ok, thread} =
        Threads.create(@session_id, ws, %{
          "name" => "Category-first",
          "tape_name" => "tape_fork_1",
          "forked_from" => "thread_main",
          "fork_point" => 42,
          "summary" => "Trying category-first approach"
        })

      assert thread["name"] == "Category-first"
      assert thread["tape_name"] == "tape_fork_1"
      assert thread["forked_from"] == "thread_main"
      assert thread["fork_point"] == 42
      assert thread["summary"] == "Trying category-first approach"
      assert thread["status"] == "active"
      assert String.starts_with?(thread["id"], "thread_")
      assert is_binary(thread["created_at"])
    end

    test "generated IDs are unique", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_1")

      {:ok, t1} = Threads.create(@session_id, ws, %{"name" => "A", "tape_name" => "ta"})
      {:ok, t2} = Threads.create(@session_id, ws, %{"name" => "B", "tape_name" => "tb"})

      assert t1["id"] != t2["id"]
    end

    test "returns error when no registry exists", %{workspace: ws} do
      assert {:error, :no_registry} =
               Threads.create("nonexistent", ws, %{
                 "name" => "X",
                 "tape_name" => "tx"
               })
    end

    test "persists to disk", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_1")

      {:ok, thread} =
        Threads.create(@session_id, ws, %{"name" => "Persisted", "tape_name" => "tp"})

      # Re-read from disk
      found = Threads.get(@session_id, ws, thread["id"])
      assert found["name"] == "Persisted"
    end
  end

  # -------------------------------------------------------------------
  # switch/3
  # -------------------------------------------------------------------

  describe "switch/3" do
    test "switches active thread", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_1")

      {:ok, fork} =
        Threads.create(@session_id, ws, %{"name" => "Fork", "tape_name" => "tf"})

      assert :ok = Threads.switch(@session_id, ws, fork["id"])

      active = Threads.active(@session_id, ws)
      assert active["id"] == fork["id"]
    end

    test "returns error for unknown thread_id", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_1")
      assert {:error, :not_found} = Threads.switch(@session_id, ws, "thread_nonexistent")
    end

    test "returns error when no registry exists", %{workspace: ws} do
      assert {:error, :not_found} = Threads.switch("nonexistent", ws, "thread_main")
    end

    test "switching back and forth preserves all threads", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_1")

      {:ok, fork} =
        Threads.create(@session_id, ws, %{"name" => "Fork", "tape_name" => "tf"})

      :ok = Threads.switch(@session_id, ws, fork["id"])
      :ok = Threads.switch(@session_id, ws, "thread_main")

      assert length(Threads.list(@session_id, ws)) == 2
      assert Threads.active(@session_id, ws)["id"] == "thread_main"
    end
  end

  # -------------------------------------------------------------------
  # delete/3
  # -------------------------------------------------------------------

  describe "delete/3" do
    test "deletes a non-active thread", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_1")

      {:ok, fork} =
        Threads.create(@session_id, ws, %{"name" => "Fork", "tape_name" => "tf"})

      assert :ok = Threads.delete(@session_id, ws, fork["id"])
      assert Threads.get(@session_id, ws, fork["id"]) == nil
      assert length(Threads.list(@session_id, ws)) == 1
    end

    test "cannot delete the active thread", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_1")
      assert {:error, :active_thread} = Threads.delete(@session_id, ws, "thread_main")
    end

    test "returns error for unknown thread", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_1")
      assert {:error, :not_found} = Threads.delete(@session_id, ws, "thread_nonexistent")
    end

    test "returns error when no registry exists", %{workspace: ws} do
      assert {:error, :not_found} = Threads.delete("nonexistent", ws, "thread_main")
    end
  end

  # -------------------------------------------------------------------
  # Persistence round-trip
  # -------------------------------------------------------------------

  # -------------------------------------------------------------------
  # fork_thread/4
  # -------------------------------------------------------------------

  describe "fork_thread/4" do
    test "creates fork tape, registers thread, and switches to it", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_main")

      {:ok, thread} =
        Threads.fork_thread(@session_id, ws, FakeTapeModule, name: "Try category-first")

      assert thread["name"] == "Try category-first"
      assert thread["forked_from"] == "thread_main"
      assert String.contains?(thread["tape_name"], "fork")
      assert thread["summary"] == nil

      # It should be the active thread now
      active = Threads.active(@session_id, ws)
      assert active["id"] == thread["id"]

      # Total threads should be 2
      assert length(Threads.list(@session_id, ws)) == 2
    end

    test "passes fork_point to tape module", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_main")

      {:ok, thread} =
        Threads.fork_thread(@session_id, ws, FakeTapeModule, fork_point: 42)

      assert thread["fork_point"] == 42
    end

    test "uses default name when none provided", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_main")

      {:ok, thread} = Threads.fork_thread(@session_id, ws, FakeTapeModule)

      assert thread["name"] == "Fork of Main"
    end

    test "returns error when no registry exists", %{workspace: ws} do
      assert {:error, :no_registry} =
               Threads.fork_thread("nonexistent", ws, FakeTapeModule)
    end
  end

  # -------------------------------------------------------------------
  # needs_summary?/2
  # -------------------------------------------------------------------

  describe "needs_summary?/2" do
    test "returns false for nonexistent tape (0 entries)" do
      refute Threads.needs_summary?("nonexistent_tape_#{System.unique_integer([:positive])}", nil)
    end
  end

  # -------------------------------------------------------------------
  # Persistence round-trip
  # -------------------------------------------------------------------

  describe "persistence" do
    test "full round-trip: init, create, switch, read back", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_main")

      {:ok, fork} =
        Threads.create(@session_id, ws, %{
          "name" => "Branch",
          "tape_name" => "tape_branch",
          "forked_from" => "thread_main",
          "fork_point" => 10
        })

      :ok = Threads.switch(@session_id, ws, fork["id"])

      # Verify everything reads back correctly from disk
      threads = Threads.list(@session_id, ws)
      assert length(threads) == 2

      active = Threads.active(@session_id, ws)
      assert active["id"] == fork["id"]
      assert active["tape_name"] == "tape_branch"
      assert active["forked_from"] == "thread_main"
      assert active["fork_point"] == 10

      main = Threads.get(@session_id, ws, "thread_main")
      assert main["tape_name"] == "tape_main"
    end
  end

  # -------------------------------------------------------------------
  # Integration: thread-aware snapshots
  # -------------------------------------------------------------------

  describe "thread-aware snapshots" do
    alias RhoWeb.Session.Snapshot

    test "save and load snapshots per thread", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_main")

      {:ok, fork} =
        Threads.create(@session_id, ws, %{"name" => "Fork", "tape_name" => "tape_fork"})

      # Save different snapshots for each thread
      main_state = %{agents: %{}, total_cost: 1.0}
      fork_state = %{agents: %{}, total_cost: 2.0}

      :ok = Snapshot.save(@session_id, ws, main_state, thread_id: "thread_main")
      :ok = Snapshot.save(@session_id, ws, fork_state, thread_id: fork["id"])

      # Load them back — each returns its own data
      {:ok, loaded_main} = Snapshot.load(@session_id, ws, thread_id: "thread_main")
      {:ok, loaded_fork} = Snapshot.load(@session_id, ws, thread_id: fork["id"])

      assert loaded_main[:total_cost] == 1.0
      assert loaded_fork[:total_cost] == 2.0
    end

    test "thread switch saves and loads correct per-thread snapshots", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_main")

      {:ok, fork} =
        Threads.create(@session_id, ws, %{"name" => "Fork", "tape_name" => "tape_fork"})

      # Save snapshot for main thread
      main_state = %{total_cost: 10.0}
      :ok = Snapshot.save(@session_id, ws, main_state, thread_id: "thread_main")

      # Switch to fork
      :ok = Threads.switch(@session_id, ws, fork["id"])
      assert Threads.active(@session_id, ws)["id"] == fork["id"]

      # Main snapshot is still loadable
      {:ok, snap} = Snapshot.load(@session_id, ws, thread_id: "thread_main")
      assert snap[:total_cost] == 10.0

      # Fork has no snapshot yet
      assert :none = Snapshot.load(@session_id, ws, thread_id: fork["id"])
    end
  end

  # -------------------------------------------------------------------
  # Integration: fork creates new tape with correct fork_point
  # -------------------------------------------------------------------

  describe "fork with fork_point integration" do
    test "fork from specific point records fork_point in thread metadata", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_main")

      {:ok, thread} =
        Threads.fork_thread(@session_id, ws, FakeTapeModule, fork_point: 7, name: "At step 7")

      assert thread["fork_point"] == 7
      assert thread["forked_from"] == "thread_main"
      assert thread["name"] == "At step 7"

      # Verify the fork_point was passed through to the tape module
      assert Process.get(:last_fork_opts) == [at: 7]
    end

    test "fork without fork_point passes empty opts to tape module", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_main")

      {:ok, thread} = Threads.fork_thread(@session_id, ws, FakeTapeModule)

      assert thread["fork_point"] == nil
      assert Process.get(:last_fork_opts) == []
    end

    test "multiple forks create separate threads", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_main")

      {:ok, fork1} = Threads.fork_thread(@session_id, ws, FakeTapeModule, name: "Fork A")
      # fork1 is now active, fork from it
      {:ok, fork2} = Threads.fork_thread(@session_id, ws, FakeTapeModule, name: "Fork B")

      threads = Threads.list(@session_id, ws)
      assert length(threads) == 3

      # fork2 should be forked from fork1, not from main
      assert fork2["forked_from"] == fork1["id"]
    end
  end

  # -------------------------------------------------------------------
  # Integration: new blank thread
  # -------------------------------------------------------------------

  describe "new blank thread" do
    test "creating a blank thread with create + switch", %{workspace: ws} do
      {:ok, _} = Threads.init(@session_id, ws, tape_name: "tape_main")

      # Simulate what the LiveView handler does
      blank_tape = "#{@session_id}_thread_blank"

      {:ok, thread} =
        Threads.create(@session_id, ws, %{
          "name" => "New Thread",
          "tape_name" => blank_tape
        })

      :ok = Threads.switch(@session_id, ws, thread["id"])

      active = Threads.active(@session_id, ws)
      assert active["id"] == thread["id"]
      assert active["tape_name"] == blank_tape
      assert active["forked_from"] == nil
      assert active["fork_point"] == nil

      assert length(Threads.list(@session_id, ws)) == 2
    end
  end
end
