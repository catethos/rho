defmodule RhoWeb.InlineCSSTest do
  use ExUnit.Case, async: true

  alias RhoWeb.InlineCSS

  test "css/0 preserves grouped source order behind the public API" do
    chunks = [
      RhoWeb.InlineCSS.Base.css(),
      RhoWeb.InlineCSS.Chat.css(),
      RhoWeb.InlineCSS.Workbench.css(),
      RhoWeb.InlineCSS.DataTable.css(),
      RhoWeb.InlineCSS.Pages.css(),
      RhoWeb.InlineCSS.Flow.css()
    ]

    assert InlineCSS.css() == IO.iodata_to_binary(chunks)
    assert Enum.all?(chunks, &(&1 != ""))

    assert String.contains?(InlineCSS.css(), "/* === Reset & Base === */")
    assert String.contains?(InlineCSS.css(), "/* === Chat input === */")
    assert String.contains?(InlineCSS.css(), "/* === Spreadsheet Layout === */")
    assert String.contains?(InlineCSS.css(), "/* === Data Table Tab Strip === */")
    assert String.contains?(InlineCSS.css(), "/* === Auth pages (login / register) === */")
    assert String.contains?(InlineCSS.css(), "/* === Flow Wizard === */")
  end
end
