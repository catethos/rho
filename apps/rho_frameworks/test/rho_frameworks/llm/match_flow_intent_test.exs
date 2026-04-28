defmodule RhoFrameworks.LLM.MatchFlowIntentTest do
  @moduledoc """
  Schema/prompt regression tests for `MatchFlowIntent`. The actual LLM
  call is exercised through the `:match_flow_intent_mod` seam in
  `AppLive` tests — here we just lock in the contract: the struct has
  the fields downstream code reads, and the compiled `.baml` carries
  the `starting_point` / `library_hints` rules the LV depends on.
  """

  use ExUnit.Case, async: true

  alias RhoFrameworks.LLM.MatchFlowIntent

  describe "struct shape" do
    test "exposes the fields downstream code reads" do
      keys = MatchFlowIntent.__struct__() |> Map.from_struct() |> Map.keys() |> MapSet.new()

      assert MapSet.subset?(
               MapSet.new([
                 :flow_id,
                 :confidence,
                 :reasoning,
                 :name,
                 :description,
                 :domain,
                 :target_roles,
                 :starting_point,
                 :library_hints
               ]),
               keys
             )
    end
  end

  describe "compiled .baml" do
    @baml_path Path.expand(
                 "../../../priv/baml_src/functions/match_flow_intent.baml",
                 __DIR__
               )

    setup do
      assert File.exists?(@baml_path),
             "expected generated BAML at #{@baml_path} — run `mix compile`"

      %{baml: File.read!(@baml_path)}
    end

    test "declares starting_point as string and library_hints as string list", %{baml: baml} do
      assert baml =~ ~r/starting_point\s+string/
      assert baml =~ ~r/library_hints\s+string\[\]/
    end

    test "prompt enumerates all five starting_point values", %{baml: baml} do
      assert baml =~ ~s("extend_existing")
      assert baml =~ ~s("merge")
      assert baml =~ ~s("from_template")
      assert baml =~ ~s("scratch")
      assert baml =~ ~r/""\s+—\s+the message is too vague/u
    end

    test "prompt includes the SFIA → extend_existing example", %{baml: baml} do
      assert baml =~ ~r/SFIA framework/
      assert baml =~ ~r/library_hints=\["SFIA"\]/
    end

    test "prompt includes a merge example with two library_hints", %{baml: baml} do
      assert baml =~ ~r/merge our SFIA and DAMA frameworks/
      assert baml =~ ~r/library_hints=\["SFIA",\s*"DAMA"\]/
    end

    test "prompt warns the LLM to prefer empty over guessing", %{baml: baml} do
      assert baml =~ ~r/Prefer\s+""\s+over\s+guessing/
    end

    test "prompt distinguishes edit-framework from create-framework", %{baml: baml} do
      assert baml =~ ~r/edit-framework/
      assert baml =~ ~r/edit our SFIA framework/
      assert baml =~ ~r/flow_id="edit-framework"/
    end

    test "prompt scopes starting_point to create-framework only", %{baml: baml} do
      assert baml =~ ~r/starting_point applies ONLY to flow_id == "create-framework"/
      assert baml =~ ~r/edit-framework.*starting_point.*""|""\s+for.*"edit-framework"/i
    end
  end
end
