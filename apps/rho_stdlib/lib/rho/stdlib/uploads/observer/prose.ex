defmodule Rho.Stdlib.Uploads.Observer.Prose do
  @moduledoc """
  Lightweight pure-Elixir text observers for user-uploaded prose files.
  """

  alias Rho.Stdlib.Uploads.Observation

  @default_preview_chars 8_000

  @spec parse_text(String.t(), String.t(), keyword()) :: {:ok, Observation.t()} | {:error, term()}
  def parse_text(path, filename, opts \\ []) do
    with {:ok, bytes} <- File.read(path) do
      text = normalize_utf8(bytes)
      build_observation(filename, document_label(filename), text, opts)
    else
      {:error, reason} -> {:error, {:io_error, reason}}
    end
  end

  @spec parse_html(String.t(), String.t(), keyword()) :: {:ok, Observation.t()} | {:error, term()}
  def parse_html(path, filename, opts \\ []) do
    with {:ok, bytes} <- File.read(path),
         text <- bytes |> normalize_utf8() |> html_to_text() do
      build_observation(filename, "HTML document", text, opts)
    else
      {:error, reason} -> {:error, {:io_error, reason}}
    end
  end

  def normalize_utf8(bytes) when is_binary(bytes) do
    if String.valid?(bytes) do
      bytes
    else
      :unicode.characters_to_binary(bytes, :latin1, :utf8)
    end
  end

  defp build_observation(filename, label, text, opts) do
    preview_chars = Keyword.get(opts, :preview_chars, @default_preview_chars)
    text = clean_text(text)
    preview = String.slice(text, 0, preview_chars)
    char_count = String.length(text)

    preview_block =
      if preview == "" do
        ""
      else
        "\n\n--- Document preview ---\n#{preview}\n--- End preview ---"
      end

    {:ok,
     %Observation{
       kind: :prose_text,
       summary_text:
         "[Uploaded: #{filename}]\n#{label}, #{format_count(char_count, "character")}." <>
           preview_block
     }}
  end

  defp document_label(filename) do
    case Path.extname(filename) |> String.downcase() do
      ".md" -> "Markdown document"
      ".markdown" -> "Markdown document"
      ".txt" -> "Text document"
      _ -> "Text document"
    end
  end

  defp html_to_text(html) do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        doc
        |> Floki.filter_out("script,style,noscript,template")
        |> extract_html_blocks()

      {:error, _} ->
        html
    end
  end

  defp extract_html_blocks(doc) do
    blocks =
      doc
      |> Floki.find("h1,h2,h3,h4,h5,h6,p,li,td,th")
      |> Enum.reject(&hidden_node?/1)
      |> Enum.map(&Floki.text(&1, sep: " "))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if blocks == [] do
      Floki.text(doc, sep: " ")
    else
      Enum.join(blocks, "\n")
    end
  end

  defp hidden_node?({_tag, attrs, _children}) do
    Enum.any?(attrs, fn
      {"hidden", _} -> true
      {"aria-hidden", "true"} -> true
      {"style", style} -> style |> String.downcase() |> String.contains?("display:none")
      _ -> false
    end)
  end

  defp hidden_node?(_), do: false

  defp clean_text(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp format_count(1, singular), do: "1 #{singular}"
  defp format_count(n, singular), do: "#{n} #{singular}s"
end
