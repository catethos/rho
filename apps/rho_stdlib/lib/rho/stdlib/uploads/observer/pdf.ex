defmodule Rho.Stdlib.Uploads.Observer.Pdf do
  @moduledoc "PDF observer placeholder. PDFs are stored and summarized without local text parsing."
  def parse(_path), do: {:error, :not_yet_supported}
  def read_sheet(_path, _sheet, _opts \\ []), do: {:error, :not_a_table}
end
