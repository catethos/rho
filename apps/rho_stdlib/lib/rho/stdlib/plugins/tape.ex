defmodule Rho.Stdlib.Plugins.Tape do
  @moduledoc """
  Mount that provides tape tools (anchor, search, recall, clear) and
  exposes the tape as a binding.

  All tool modules call `Rho.Tape.Service` directly for storage operations,
  bypassing the `Rho.Tape.Context` behaviour which handles only core
  projection concerns.
  """

  @behaviour Rho.Plugin

  @impl Rho.Plugin
  def tools(_mount_opts, %{tape_name: tape_name} = _context) do
    [
      Rho.Stdlib.Tools.Anchor.tool_def(tape_name),
      Rho.Stdlib.Tools.SearchHistory.tool_def(tape_name),
      Rho.Stdlib.Tools.RecallContext.tool_def(tape_name),
      Rho.Stdlib.Tools.ClearMemory.tool_def(tape_name)
    ]
  end

  def tools(_mount_opts, _context), do: []

  @impl Rho.Plugin
  def bindings(_mount_opts, %{tape_name: tape_name} = _context) do
    info = Rho.Tape.Service.info(tape_name)
    entry_count = info[:entry_count] || 0

    [
      %{
        name: "tape",
        kind: :text_corpus,
        size: entry_count,
        access: :tool,
        persistence: :session,
        summary: "Conversation tape with #{entry_count} entries"
      }
    ]
  end

  def bindings(_mount_opts, _context), do: []
end
