defmodule RhoWeb.InlineCSS do
  @moduledoc """
  Inline CSS for the Rho LiveView UI.

  The public `css/0` API stays inline for the root layout, while grouped source
  modules keep the large stylesheet split by ownership.
  """

  alias RhoWeb.InlineCSS.Base
  alias RhoWeb.InlineCSS.Chat
  alias RhoWeb.InlineCSS.DataTable
  alias RhoWeb.InlineCSS.Flow
  alias RhoWeb.InlineCSS.Pages
  alias RhoWeb.InlineCSS.Workbench

  def css do
    [
      Base.css(),
      Chat.css(),
      Workbench.css(),
      DataTable.css(),
      Pages.css(),
      Flow.css()
    ]
    |> IO.iodata_to_binary()
  end
end
