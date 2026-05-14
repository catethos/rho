defmodule Rho.Tape.ForkTest do
  use ExUnit.Case

  alias Rho.Tape.{Fork, Service, Store}

  @main_tape "test_fork_main_#{System.os_time(:nanosecond)}"

  setup do
    on_exit(fn ->
      Store.clear(@main_tape)
      # Clean up any fork tapes
      :ok
    end)

    :ok
  end

  describe "fork/2" do
    test "creates a fork tape with fork_origin anchor" do
      Service.ensure_bootstrap_anchor(@main_tape)
      {:ok, e1} = Service.append(@main_tape, :message, %{"role" => "user", "content" => "hello"})

      {:ok, fork_name} = Fork.fork(@main_tape)
      on_exit(fn -> Store.clear(fork_name) end)

      entries = Store.read(fork_name)
      assert match?([_, _, _], entries)

      origin = List.last(entries)
      assert origin.kind == :anchor
      assert origin.payload["name"] == "fork_origin"
      assert origin.payload["fork"]["source_tape"] == @main_tape
      assert origin.payload["fork"]["at_id"] == e1.id

      copied = Enum.find(entries, &(&1.payload["content"] == "hello"))
      assert copied.meta["copied_from_tape"] == @main_tape
      assert copied.meta["copied_from_entry_id"] == e1.id
    end

    test "supports custom fork name" do
      Service.ensure_bootstrap_anchor(@main_tape)
      fork_name = "custom_fork_#{System.os_time(:nanosecond)}"

      {:ok, ^fork_name} = Fork.fork(@main_tape, name: fork_name)
      on_exit(fn -> Store.clear(fork_name) end)

      assert Store.read(fork_name) != []
    end

    test "supports forking at specific entry ID" do
      Service.ensure_bootstrap_anchor(@main_tape)
      {:ok, e1} = Service.append(@main_tape, :message, %{"role" => "user", "content" => "first"})
      Service.append(@main_tape, :message, %{"role" => "user", "content" => "second"})

      {:ok, fork_name} = Fork.fork(@main_tape, at: e1.id)
      on_exit(fn -> Store.clear(fork_name) end)

      origin =
        Store.read(fork_name)
        |> Enum.find(&(&1.kind == :anchor and &1.payload["name"] == "fork_origin"))

      assert origin.payload["fork"]["at_id"] == e1.id
    end

    test "materializes only entries up to the fork point" do
      Service.ensure_bootstrap_anchor(@main_tape)
      {:ok, e1} = Service.append(@main_tape, :message, %{"role" => "user", "content" => "first"})
      Service.append(@main_tape, :message, %{"role" => "assistant", "content" => "second"})

      {:ok, fork_name} = Fork.fork(@main_tape, at: e1.id)
      on_exit(fn -> Store.clear(fork_name) end)

      contents =
        fork_name
        |> Store.read()
        |> Enum.map(& &1.payload["content"])

      assert "first" in contents
      refute "second" in contents
    end

    test "drops incomplete tool calls at the fork point" do
      Service.ensure_bootstrap_anchor(@main_tape)

      {:ok, call} =
        Service.append(@main_tape, :tool_call, %{
          "name" => "bash",
          "args" => %{},
          "call_id" => "call_incomplete"
        })

      Service.append(@main_tape, :tool_result, %{
        "name" => "bash",
        "output" => "late",
        "status" => "ok",
        "call_id" => "call_incomplete"
      })

      {:ok, fork_name} = Fork.fork(@main_tape, at: call.id)
      on_exit(fn -> Store.clear(fork_name) end)

      refute Enum.any?(Store.read(fork_name), &(&1.kind == :tool_call))
    end
  end

  describe "merge/2" do
    test "appends delta entries from fork to main tape" do
      Service.ensure_bootstrap_anchor(@main_tape)
      Service.append(@main_tape, :message, %{"role" => "user", "content" => "before fork"})

      {:ok, fork_name} = Fork.fork(@main_tape)
      on_exit(fn -> Store.clear(fork_name) end)

      # Add entries to the fork
      Service.append(fork_name, :message, %{"role" => "user", "content" => "fork msg 1"})
      Service.append(fork_name, :message, %{"role" => "assistant", "content" => "fork msg 2"})

      main_before = length(Store.read(@main_tape))
      {:ok, count} = Fork.merge(fork_name, @main_tape)

      assert count == 2
      main_after = Store.read(@main_tape)
      assert length(main_after) == main_before + 2

      merged = Enum.slice(main_after, -2..-1//1)
      assert Enum.at(merged, 0).payload["content"] == "fork msg 1"
      assert Enum.at(merged, 1).payload["content"] == "fork msg 2"
    end

    test "adds from_fork metadata to merged entries" do
      Service.ensure_bootstrap_anchor(@main_tape)

      {:ok, fork_name} = Fork.fork(@main_tape)
      on_exit(fn -> Store.clear(fork_name) end)

      Service.append(fork_name, :message, %{"role" => "user", "content" => "forked"})

      {:ok, 1} = Fork.merge(fork_name, @main_tape)

      merged = List.last(Store.read(@main_tape))
      assert merged.meta["from_fork"] == fork_name
    end

    test "returns error for non-fork tape" do
      Service.ensure_bootstrap_anchor(@main_tape)
      assert {:error, :no_fork_origin} = Fork.merge(@main_tape, "other_tape")
    end

    test "does not merge the fork_origin anchor itself" do
      Service.ensure_bootstrap_anchor(@main_tape)

      {:ok, fork_name} = Fork.fork(@main_tape)
      on_exit(fn -> Store.clear(fork_name) end)

      Service.append(fork_name, :message, %{"role" => "user", "content" => "hello"})

      {:ok, 1} = Fork.merge(fork_name, @main_tape)

      main_entries = Store.read(@main_tape)
      fork_origins = Enum.filter(main_entries, &(&1.payload["name"] == "fork_origin"))
      assert fork_origins == []
    end
  end

  describe "fork_info/1" do
    test "returns fork metadata for fork tape" do
      Service.ensure_bootstrap_anchor(@main_tape)
      {:ok, e} = Service.append(@main_tape, :message, %{"role" => "user", "content" => "hi"})

      {:ok, fork_name} = Fork.fork(@main_tape)
      on_exit(fn -> Store.clear(fork_name) end)

      info = Fork.fork_info(fork_name)
      assert info.source_tape == @main_tape
      assert info.at_id == e.id
    end

    test "returns nil for non-fork tape" do
      Service.ensure_bootstrap_anchor(@main_tape)
      assert Fork.fork_info(@main_tape) == nil
    end
  end
end