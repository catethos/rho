defmodule Rho.Plugins.Subagent.UI do
  @moduledoc "CLI progress display for active subagents."

  @box_width 48
  @spinner_frames ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

  @doc "Re-render the status box (moves cursor up to overwrite previous render)."
  def render_status([]), do: :ok

  def render_status(subagents) do
    lines = build_lines(subagents)

    box = [
      "  ┌ subagents #{String.duplicate("─", @box_width - 14)}┐",
      lines,
      "  └#{String.duplicate("─", @box_width)}┘"
    ] |> List.flatten() |> Enum.join("\n")

    # Move cursor up to overwrite previous render
    up = "\e[#{length(lines) + 2}A\r"
    IO.write(up <> box <> "\n")
  end

  @doc "First render — no cursor movement needed."
  def initial_render([]), do: :ok

  def initial_render(subagents) do
    lines = build_lines(subagents)

    box = [
      "  ┌ subagents #{String.duplicate("─", @box_width - 14)}┐",
      lines,
      "  └#{String.duplicate("─", @box_width)}┘"
    ] |> List.flatten() |> Enum.join("\n")

    IO.write(box <> "\n")
  end

  @doc "Clear the status box when all subagents are collected."
  def clear(0), do: :ok

  def clear(line_count) do
    up = "\e[#{line_count}A\r"
    blank = String.duplicate(" ", @box_width + 4)
    IO.write(up <> Enum.map_join(1..line_count, "\n", fn _ -> blank end) <> "\e[#{line_count}A\r")
  end

  # --- Private ---

  defp build_lines(subagents) do
    Enum.map(subagents, fn {id, info} ->
      short_id = String.slice(to_string(id), 0..7) |> String.pad_trailing(8)

      label =
        info.prompt
        |> String.slice(0..19)
        |> String.pad_trailing(20)

      spinner = spinner_frame(info.step)
      step_str = "step #{info.step}" |> String.pad_leading(8)

      "  │ #{spinner} #{short_id} #{label} #{step_str} │"
    end)
  end

  defp spinner_frame(step) do
    idx = rem(step, length(@spinner_frames))
    Enum.at(@spinner_frames, idx)
  end
end
