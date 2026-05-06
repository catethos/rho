defmodule Rho.Stdlib.Uploads.Observer.Pdf do
  @moduledoc "PDF observer — v1 stub. v2 implements pdfplumber two-pass."
  def parse(_path), do: {:error, :not_yet_supported}
  def read_sheet(_path, _sheet, _opts \\ []), do: {:error, :not_yet_supported}
end
