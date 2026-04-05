defmodule Rho.FileParserTest do
  use ExUnit.Case, async: true

  alias Rho.FileParser

  describe "parse/2" do
    test "parses CSV file to structured output" do
      path = Path.join([File.cwd!(), "test", "fixtures", "sample.csv"])
      assert {:structured, %{sheets: [sheet]}} = FileParser.parse(path, "text/csv")
      assert sheet.name != nil
      assert sheet.row_count == 3
      assert "Category" in sheet.columns
      assert "Skill" in sheet.columns
      assert "Description" in sheet.columns
      assert hd(sheet.rows)["Category"] in ["Leadership", "Communication", "Technical"]
    end

    test "parses image to base64" do
      # Minimal valid 1x1 PNG
      png =
        <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
          2, 0, 0, 0, 144, 119, 83, 222, 0, 0, 0, 12, 73, 68, 65, 84, 8, 215, 99, 248, 207, 192,
          0, 0, 0, 2, 0, 1, 226, 33, 188, 51, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

      path =
        Path.join(
          System.tmp_dir!(),
          "test_image_#{System.unique_integer([:positive])}.png"
        )

      File.write!(path, png)

      assert {:image, data, "image/png"} = FileParser.parse(path, "image/png")
      assert is_binary(data)
      assert byte_size(data) > 0
      # Verify it's valid base64
      assert {:ok, _} = Base64.decode64(data) |> then(&{:ok, &1})

      File.rm(path)
    end

    test "returns error for unsupported file type" do
      path = Path.join(System.tmp_dir!(), "test_#{System.unique_integer([:positive])}.xls")
      File.write!(path, "fake content")

      assert {:error, message} = FileParser.parse(path, "application/vnd.ms-excel")
      assert message =~ "Unsupported"

      File.rm(path)
    end
  end
end
