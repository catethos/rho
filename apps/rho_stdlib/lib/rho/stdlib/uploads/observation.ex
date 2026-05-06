defmodule Rho.Stdlib.Uploads.Observation do
  @moduledoc """
  Uniform summary returned by `Rho.Stdlib.Uploads.Observer.observe/2`.
  See `docs/superpowers/specs/2026-05-06-file-upload-design.md` §5.2.
  """

  @type kind :: :structured_table | :prose | :image | :unsupported

  @type sheet_summary :: %{
          name: String.t(),
          row_count: non_neg_integer(),
          columns: [String.t()],
          sample_rows: [map()]
        }

  @type sheet_strategy :: :single_library | :roles_per_sheet | :ambiguous

  @type hints :: %{
          library_name_column: String.t() | nil,
          role_column: String.t() | nil,
          skill_name_column: String.t() | nil,
          skill_description_column: String.t() | nil,
          category_column: String.t() | nil,
          cluster_column: String.t() | nil,
          level_column: String.t() | nil,
          level_name_column: String.t() | nil,
          level_description_column: String.t() | nil,
          sheet_strategy: sheet_strategy()
        }

  @type t :: %__MODULE__{
          kind: kind(),
          sheets: [sheet_summary()],
          hints: hints(),
          warnings: [String.t()],
          summary_text: String.t()
        }

  defstruct kind: :unsupported,
            sheets: [],
            hints: %{},
            warnings: [],
            summary_text: ""
end
