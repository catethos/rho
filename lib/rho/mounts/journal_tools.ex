defmodule Rho.Mounts.JournalTools do
  @moduledoc """
  Mount that provides journal/tape tools (anchor, search, recall, clear)
  and exposes the journal as a binding.

  All tool modules call `Rho.Tape.Service` directly for storage operations,
  bypassing the `Rho.Memory` behaviour which handles only core storage concerns.
  """

  @behaviour Rho.Mount

  @impl Rho.Mount
  def tools(_mount_opts, %{tape_name: tape_name} = _context) do
    [
      Rho.Tools.Anchor.tool_def(tape_name),
      Rho.Tools.SearchHistory.tool_def(tape_name),
      Rho.Tools.RecallContext.tool_def(tape_name),
      Rho.Tools.ClearMemory.tool_def(tape_name)
    ]
  end

  def tools(_mount_opts, _context), do: []

  @impl Rho.Mount
  def bindings(_mount_opts, %{tape_name: tape_name} = _context) do
    info = Rho.Tape.Service.info(tape_name)
    entry_count = info[:entry_count] || 0

    [
      %{
        name: "journal",
        kind: :text_corpus,
        size: entry_count,
        access: :tool,
        persistence: :session,
        summary: "Conversation journal with #{entry_count} entries"
      }
    ]
  end

  def bindings(_mount_opts, _context), do: []
end
