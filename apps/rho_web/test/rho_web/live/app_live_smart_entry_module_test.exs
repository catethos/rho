defmodule RhoWeb.AppLiveSmartEntryModuleTest do
  use ExUnit.Case, async: true

  alias RhoWeb.AppLive.SmartEntry

  describe "build_intake_query/2" do
    test "keeps extracted intake fields and whitelisted starting points" do
      query =
        SmartEntry.build_intake_query(
          %{
            name: "Backend Engineering",
            description: "Server-side skills",
            domain: "",
            target_roles: "Engineer, Lead",
            starting_point: "scratch",
            library_hints: []
          },
          nil
        )
        |> URI.decode_query()

      assert query == %{
               "description" => "Server-side skills",
               "name" => "Backend Engineering",
               "starting_point" => "scratch",
               "target_roles" => "Engineer, Lead"
             }
    end

    test "drops invalid starting points" do
      query =
        SmartEntry.build_intake_query(
          %{
            name: "Backend Engineering",
            starting_point: "surprise",
            library_hints: []
          },
          nil
        )
        |> URI.decode_query()

      refute Map.has_key?(query, "starting_point")
    end
  end

  describe "resolve_library_hints/2" do
    test "resolves only unique case-insensitive substring matches" do
      libraries = [
        %{id: "sfia", name: "SFIA Framework v8"},
        %{id: "design-a", name: "Design System"},
        %{id: "design-b", name: "UX Design"}
      ]

      assert SmartEntry.resolve_library_hints(["sfia"], libraries) == ["sfia"]
      assert SmartEntry.resolve_library_hints(["design"], libraries) == []
      assert SmartEntry.resolve_library_hints(["missing"], libraries) == []
    end

    test "ignores non-list hints" do
      assert SmartEntry.resolve_library_hints(nil, [%{id: "a", name: "A"}]) == []
    end
  end
end
