defmodule RhoWeb.DataTable.ExportTest do
  use ExUnit.Case, async: true

  alias RhoWeb.DataTable.Export
  alias RhoWeb.DataTable.Schema
  alias RhoWeb.DataTable.Schema.Column

  describe "build_csv/2" do
    test "exports flat rows and excludes action columns" do
      schema =
        schema([
          column(:name, "Name"),
          column(:score, "Score", :number),
          column(:actions, "Actions", :action)
        ])

      rows = [
        %{name: "Ada", score: 9, actions: "ignore"},
        %{"name" => "Grace", "score" => "10", "actions" => "ignore"}
      ]

      assert Export.build_csv(rows, schema) == "Name,Score\nAda,9\nGrace,10"
    end

    test "escapes commas, quotes, and newlines" do
      schema = schema([column(:name, "Name"), column(:note, "Note")])

      rows = [
        %{name: "Ada, Lovelace", note: "said \"hello\""},
        %{name: "Grace", note: "line one\nline two"}
      ]

      assert Export.build_csv(rows, schema) ==
               "Name,Note\n\"Ada, Lovelace\",\"said \"\"hello\"\"\"\nGrace,\"line one\nline two\""
    end

    test "expands child rows and leaves child cells blank when absent" do
      schema = %Schema{
        title: "Skills",
        columns: [column(:skill, "Skill")],
        child_columns: [column(:level, "Level", :number), column(:description, "Description")],
        children_key: :proficiency_levels
      }

      rows = [
        %{
          skill: "Hiring",
          proficiency_levels: [
            %{level: 1, description: "Aware"},
            %{"level" => 2, "description" => "Practices"}
          ]
        },
        %{skill: "Coaching", proficiency_levels: []}
      ]

      assert Export.build_csv(rows, schema) ==
               "Skill,Level,Description\nHiring,1,Aware\nHiring,2,Practices\nCoaching,,"
    end
  end

  describe "build_xlsx/2" do
    test "builds a workbook with headers, child rows, and numeric cells" do
      schema = %Schema{
        title: "Skills",
        columns: [
          column(:skill, "Skill"),
          column(:score, "Score", :number),
          column(:actions, "Actions", :action)
        ],
        child_columns: [column(:level, "Level", :number)],
        children_key: :levels
      }

      rows = [
        %{skill: "Hiring", score: "3.5", actions: "ignore", levels: [%{level: "2"}]}
      ]

      files = unzip(Export.build_xlsx(rows, schema))

      assert Map.has_key?(files, "xl/worksheets/sheet1.xml")
      refute files["xl/sharedStrings.xml"] =~ "Actions"
      assert files["xl/sharedStrings.xml"] =~ "Hiring"
      assert files["xl/worksheets/sheet1.xml"] =~ "<v>3.5</v>"
      assert files["xl/worksheets/sheet1.xml"] =~ "<v>2.0</v>"
    end
  end

  defp schema(columns), do: %Schema{title: "Data", columns: columns}

  defp column(key, label, type \\ :text) do
    %Column{key: key, label: label, type: type}
  end

  defp unzip(binary) do
    {:ok, entries} = :zip.extract(binary, [:memory])

    Map.new(entries, fn {path, content} ->
      {List.to_string(path), IO.iodata_to_binary(content)}
    end)
  end
end
