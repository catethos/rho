defmodule RhoEmbeddingsTest do
  use ExUnit.Case, async: false

  alias RhoEmbeddings.Backend.Fake

  setup do
    # Tests share the singleton Server started by the supervision tree.
    # Wait for the Fake backend's load Task to complete before each test.
    wait_until_ready()
    Fake.reset()
    :ok
  end

  describe "ready?/0 and model_name/0" do
    test "ready? flips to true after the load task completes" do
      assert RhoEmbeddings.ready?() == true
    end

    test "model_name returns the configured default" do
      assert RhoEmbeddings.model_name() ==
               "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
    end
  end

  describe "embed_many/1 with the Fake backend" do
    test "returns one vector per input, each 384-dim" do
      {:ok, [v1, v2]} = RhoEmbeddings.embed_many(["hello", "world"])

      assert length(v1) == 384
      assert length(v2) == 384
      assert Enum.all?(v1, &is_float/1)
    end

    test "stashed vectors are returned verbatim" do
      canned = List.duplicate(0.5, 384)
      :ok = Fake.put_vector("data analysis", canned)

      {:ok, [vec]} = RhoEmbeddings.embed_many(["data analysis"])
      assert vec == canned
    end

    test "is deterministic for identical inputs" do
      {:ok, [v1]} = RhoEmbeddings.embed_many(["consistent"])
      {:ok, [v2]} = RhoEmbeddings.embed_many(["consistent"])
      assert v1 == v2
    end

    test "different inputs produce different vectors" do
      {:ok, [v1]} = RhoEmbeddings.embed_many(["alpha"])
      {:ok, [v2]} = RhoEmbeddings.embed_many(["beta"])
      refute v1 == v2
    end
  end

  defp wait_until_ready(deadline_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait(deadline)
  end

  defp do_wait(deadline) do
    cond do
      RhoEmbeddings.ready?() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("RhoEmbeddings.Server never became ready")

      true ->
        Process.sleep(20)
        do_wait(deadline)
    end
  end
end
