defmodule RhoWeb.DataTable.SchemasTest do
  use ExUnit.Case, async: true

  alias RhoWeb.DataTable.Schemas

  describe "resolve/2" do
    test "resolves the research notes table to usable columns" do
      schema = Schemas.resolve(nil, "research_notes")

      assert schema.title == "Research Notes"
      refute schema.show_id

      assert Enum.map(schema.columns, & &1.key) == [
               :fact,
               :source_title,
               :source,
               :published_date,
               :tag,
               :relevance,
               :pinned
             ]

      assert Enum.map(schema.columns, & &1.css_class) == [
               "dt-col-research-finding",
               "dt-col-research-source",
               "dt-col-research-url",
               "dt-col-research-date",
               "dt-col-research-tag",
               "dt-col-research-score",
               "dt-col-research-pinned"
             ]
    end

    test "resolves the research notes view key" do
      assert Schemas.resolve(:research_notes) == Schemas.research_notes()
    end
  end
end
