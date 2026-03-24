defmodule Rho.Tools.WebFetch do
  @moduledoc "Tool for fetching web content via HTTP GET."

  @behaviour Rho.Mount

  @max_text_length 20_000

  @impl Rho.Mount
  def tools(_mount_opts, _context), do: [tool_def()]

  defp tool_def do
    %{
      tool:
        ReqLLM.tool(
          name: "web_fetch",
          description: "HTTP GET a URL and return its text content extracted from HTML.",
          parameter_schema: [
            url: [type: :string, required: true, doc: "The URL to fetch"],
            timeout: [type: :integer, doc: "Timeout in seconds (default 10)"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: &execute/1
    }
  end

  def execute(%{"url" => url} = args), do: execute(%{url: url, timeout: args["timeout"]})

  def execute(%{url: url} = args) do
    timeout = (args[:timeout] || 10) * 1000

    case Req.get(url, receive_timeout: timeout) do
      {:ok, %{body: body}} when is_binary(body) ->
        text = extract_text(body)
        {:ok, truncate(text)}

      {:ok, %{body: body}} ->
        {:ok, truncate(inspect(body))}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp extract_text(body) do
    if html?(body) do
      html_to_text(body)
    else
      body
    end
  end

  defp html?(body) do
    trimmed = body |> String.trim_leading() |> String.slice(0..200) |> String.downcase()
    String.contains?(trimmed, "<!doctype html") or String.contains?(trimmed, "<html")
  end

  defp html_to_text(html) do
    {:ok, doc} = Floki.parse_document(html)

    # Remove script, style, nav, header, footer tags
    doc
    |> Floki.filter_out("script, style, nav, header, footer, noscript")
    |> extract_nodes()
    |> Enum.join("\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp extract_nodes(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, &extract_node/1)
  end

  defp extract_node({tag, _attrs, children}) when tag in ~w(h1 h2 h3 h4 h5 h6) do
    text = children |> extract_nodes() |> Enum.join(" ") |> String.trim()
    if text != "", do: ["\n## #{text}\n"], else: []
  end

  defp extract_node({"p", _attrs, children}) do
    text = children |> extract_nodes() |> Enum.join(" ") |> String.trim()
    if text != "", do: [text, "\n"], else: []
  end

  defp extract_node({"li", _attrs, children}) do
    text = children |> extract_nodes() |> Enum.join(" ") |> String.trim()
    if text != "", do: ["- #{text}"], else: []
  end

  defp extract_node({"br", _attrs, _children}), do: ["\n"]

  defp extract_node({_tag, _attrs, children}), do: extract_nodes(children)

  defp extract_node(text) when is_binary(text) do
    cleaned = text |> String.replace(~r/\s+/, " ") |> String.trim()
    if cleaned != "", do: [cleaned], else: []
  end

  defp extract_node(_), do: []

  defp truncate(text) do
    if String.length(text) > @max_text_length do
      String.slice(text, 0, @max_text_length) <> "\n\n[truncated — content exceeded #{@max_text_length} chars]"
    else
      text
    end
  end
end
