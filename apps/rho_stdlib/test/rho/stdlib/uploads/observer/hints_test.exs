defmodule Rho.Stdlib.Uploads.Observer.HintsTest do
  use ExUnit.Case, async: true

  alias Rho.Stdlib.Uploads.Observer.Hints

  test "detects library_name_column from canonical header" do
    h =
      Hints.from_sheets([%{name: "S", columns: ["Skill Library Name", "Skill Name", "Category"]}])

    assert h.library_name_column == "Skill Library Name"
    assert h.skill_name_column == "Skill Name"
    assert h.category_column == "Category"
  end

  test "matches case-insensitively and against aliases" do
    h = Hints.from_sheets([%{name: "S", columns: ["competency", "domain", "definition"]}])
    assert h.skill_name_column == "competency"
    assert h.category_column == "domain"
    assert h.skill_description_column == "definition"
  end

  test "single sheet with no library_name column → :single_library" do
    h = Hints.from_sheets([%{name: "S", columns: ["Skill Name", "Category"]}])
    assert h.sheet_strategy == :single_library
  end

  test "multi sheet with no library_name column AND consistent columns → :roles_per_sheet" do
    h =
      Hints.from_sheets([
        %{name: "PM", columns: ["Skill Name", "Category", "Description"]},
        %{name: "DE", columns: ["Skill Name", "Category", "Description"]},
        %{name: "CEO", columns: ["Skill Name", "Category", "Description"]}
      ])

    assert h.sheet_strategy == :roles_per_sheet
  end

  test "multi sheet with library_name column → :single_library" do
    h =
      Hints.from_sheets([
        %{name: "Sheet1", columns: ["Skill Library Name", "Skill Name"]},
        %{name: "Sheet2", columns: ["Skill Library Name", "Skill Name"]}
      ])

    assert h.sheet_strategy == :single_library
  end

  test "multi sheet with inconsistent columns → :ambiguous" do
    h =
      Hints.from_sheets([
        %{name: "S1", columns: ["Skill Name", "Category"]},
        %{name: "S2", columns: ["Name", "Group"]}
      ])

    assert h.sheet_strategy == :ambiguous
  end
end
