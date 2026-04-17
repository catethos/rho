defmodule Rho.Stdlib.DataTable.Schema.Column do
  @moduledoc """
  Column descriptor for a `Rho.Stdlib.DataTable.Schema`.

  Declares a single field name, its primitive type, whether it is required,
  and an optional human-readable doc string.
  """

  defstruct [:name, :type, required?: false, doc: nil]

  @type primitive :: :string | :integer | :float | :boolean | :any

  @type t :: %__MODULE__{
          name: atom(),
          type: primitive(),
          required?: boolean(),
          doc: String.t() | nil
        }
end
