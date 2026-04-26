defmodule Rho.Stdlib.Plugins.LiveRender do
  @moduledoc """
  Plugin providing a `present_ui` tool that lets agents render structured UI
  via the LiveRender library.

  The agent produces a LiveRender spec map (with elements, root, and optional state),
  which is emitted as a signal and rendered as rich components in the web UI.

  ## Options

    * `:catalog` — the LiveRender catalog module (default: `LiveRender.StandardCatalog`)
    * `:max_spec_bytes` — maximum JSON size for a spec (default: 50_000)
  """

  @behaviour Rho.Plugin

  @default_catalog LiveRender.StandardCatalog
  @default_max_bytes 50_000

  @impl Rho.Plugin
  def tools(mount_opts, context) do
    # Only expose to depth-0 agents by default
    if (context[:depth] || 0) > 0 do
      []
    else
      catalog = Keyword.get(mount_opts, :catalog, @default_catalog)
      max_bytes = Keyword.get(mount_opts, :max_spec_bytes, @default_max_bytes)

      [present_ui_tool(context, catalog, max_bytes)]
    end
  end

  @impl Rho.Plugin
  def prompt_sections(mount_opts, context) do
    alias Rho.PromptSection

    # Only expose to depth-0 agents (same gate as tools)
    if (context[:depth] || 0) > 0 do
      []
    else
      catalog = Keyword.get(mount_opts, :catalog, @default_catalog)
      names = catalog.components() |> Map.keys() |> Enum.join(", ")

      [
        %PromptSection{
          key: :live_render,
          heading: "present_ui tool",
          body: """
          Use `present_ui` for structured UI (tables, metrics, cards, lists). Don't repeat UI content in text after rendering.

          Components: #{names}

          Spec format: `{"root": "<id>", "elements": {"<id>": {"type": "<component>", "props": {...}, "children": [...]}}}`\
          """,
          kind: :instructions,
          priority: :normal,
          examples: [
            ~s({"root":"r","elements":{"r":{"type":"stack","props":{},"children":["t"]},) <>
              ~s("t":{"type":"table","props":{"columns":[{"key":"name","label":"Name"}],"data":[{"name":"Alice"}]},"children":[]}}})
          ]
        }
      ]
    end
  end

  # --- Tool definition ---

  defp present_ui_tool(context, catalog, max_bytes) do
    %{
      tool:
        ReqLLM.tool(
          name: "present_ui",
          description:
            "Render structured UI components in the user's browser. " <>
              "Use for tables, metrics, cards, checklists, and other structured data. " <>
              "The spec is a JSON object with 'root' and 'elements' keys.",
          parameter_schema: [
            spec: [
              type: :map,
              required: true,
              doc: "The LiveRender UI spec with 'root' and 'elements' keys"
            ],
            title: [type: :string, doc: "Optional title displayed above the UI block"]
          ],
          callback: fn _args -> :ok end
        ),
      execute: fn args, _ctx ->
        execute_present_ui(args, context, catalog, max_bytes)
      end
    }
  end

  defp execute_present_ui(args, context, catalog, max_bytes) do
    raw_spec = args[:spec]
    title = args[:title]

    # Parse string-encoded specs (some models serialize nested objects as strings)
    # Check size before decoding to avoid redundant encode in validate_size
    {spec, pre_validated_size} =
      case raw_spec do
        s when is_binary(s) ->
          case Jason.decode(s) do
            {:ok, parsed} when is_map(parsed) -> {parsed, byte_size(s)}
            _ -> {raw_spec, nil}
          end

        other ->
          {other, nil}
      end

    with :ok <- validate_spec(spec, catalog, max_bytes, pre_validated_size) do
      # Normalize: ensure root and elements exist
      spec = normalize_spec(spec)
      publish_spec(spec, title, context)
      {:ok, "Rendered."}
    end
  end

  defp publish_spec(_spec, _title, %{session_id: nil}), do: :ok
  defp publish_spec(_spec, _title, context) when not is_map_key(context, :session_id), do: :ok

  defp publish_spec(spec, title, context) do
    session_id = context[:session_id]
    agent_id = context[:agent_id]
    message_id = "ui_#{System.unique_integer([:positive])}"
    elements = spec["elements"] || %{}
    root_id = spec["root"]

    ordered_ids = bfs_element_order(root_id, elements)

    publish_delta = fn acc ->
      trimmed = trim_children_for_partial(acc)

      Rho.Events.broadcast(
        session_id,
        Rho.Events.event(:ui_spec_delta, session_id, agent_id, %{
          message_id: message_id,
          title: title,
          spec: %{"root" => root_id, "elements" => trimmed}
        })
      )
    end

    _final_partial =
      Enum.reduce(ordered_ids, %{}, fn el_id, acc ->
        stream_element(acc, el_id, elements, publish_delta)
      end)

    Rho.Events.broadcast(
      session_id,
      Rho.Events.event(:ui_spec, session_id, agent_id, %{
        message_id: message_id,
        title: title,
        spec: spec
      })
    )
  end

  defp trim_children_for_partial(acc) do
    Map.new(acc, fn {id, el} ->
      children = el["children"] || []
      trimmed_children = Enum.filter(children, &Map.has_key?(acc, &1))
      {id, Map.put(el, "children", trimmed_children)}
    end)
  end

  defp stream_element(acc, el_id, elements, publish_delta) do
    el = elements[el_id]
    data = get_in(el, ["props", "data"])

    if is_list(data) and length(data) > 1 do
      Enum.reduce(data, acc, fn row, inner_acc ->
        existing_data = get_in(inner_acc, [el_id, "props", "data"]) || []
        updated_el = put_in(el, ["props", "data"], existing_data ++ [row])
        inner_acc = Map.put(inner_acc, el_id, updated_el)
        publish_delta.(inner_acc)
        inner_acc
      end)
    else
      acc = Map.put(acc, el_id, el)
      publish_delta.(acc)
      acc
    end
  end

  # --- Validation ---

  defp validate_spec(nil, _catalog, _max_bytes, _pre_size),
    do: {:error, "spec parameter is required"}

  defp validate_spec(spec, catalog, max_bytes, pre_validated_size) when is_map(spec) do
    with :ok <- validate_size(spec, max_bytes, pre_validated_size),
         :ok <- validate_structure(spec) do
      validate_components(spec, catalog)
    end
  end

  defp validate_spec(spec, catalog, max_bytes, _pre_size) when is_binary(spec) do
    case Jason.decode(spec) do
      {:ok, parsed} when is_map(parsed) ->
        validate_spec(parsed, catalog, max_bytes, byte_size(spec))

      _ ->
        {:error, "spec must be a valid JSON object"}
    end
  end

  defp validate_spec(_spec, _catalog, _max_bytes, _pre_size),
    do: {:error, "spec must be a JSON object"}

  defp validate_size(_spec, max_bytes, size) when is_integer(size) do
    if size > max_bytes do
      {:error, "spec exceeds maximum size of #{max_bytes} bytes"}
    else
      :ok
    end
  end

  defp validate_size(spec, max_bytes, _pre_size) do
    json = Jason.encode!(spec)

    if byte_size(json) > max_bytes do
      {:error, "spec exceeds maximum size of #{max_bytes} bytes"}
    else
      :ok
    end
  end

  defp validate_structure(spec) do
    cond do
      not is_map(spec["elements"]) and not is_map(spec[:elements]) ->
        {:error, "spec must contain an 'elements' map"}

      is_nil(spec["root"]) and is_nil(spec[:root]) ->
        {:error, "spec must contain a 'root' key"}

      true ->
        :ok
    end
  end

  defp validate_components(spec, catalog) do
    elements = spec["elements"] || spec[:elements] || %{}

    unknown =
      elements
      |> Enum.map(fn {_id, el} -> el["type"] || el[:type] end)
      |> Enum.filter(fn type -> type && is_nil(catalog.get(type)) end)
      |> Enum.uniq()

    if unknown == [] do
      :ok
    else
      {:error,
       "unknown component types: #{Enum.join(unknown, ", ")}. Available: #{catalog.components() |> Map.keys() |> Enum.join(", ")}"}
    end
  end

  defp bfs_element_order(nil, _elements), do: []

  defp bfs_element_order(root_id, elements) do
    bfs_walk([root_id], elements, [])
  end

  defp bfs_walk([], _elements, acc), do: Enum.reverse(acc)

  defp bfs_walk([id | rest], elements, acc) do
    case Map.get(elements, id) do
      nil ->
        bfs_walk(rest, elements, acc)

      el ->
        children = (el["children"] || []) |> Enum.filter(&is_binary/1)
        bfs_walk(rest ++ children, elements, [id | acc])
    end
  end

  defp normalize_spec(spec) do
    spec
    |> Map.put_new("root", spec[:root] || spec["root"])
    |> Map.put_new("elements", spec[:elements] || spec["elements"])
  end
end
