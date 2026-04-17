defmodule Rho.PromptSection do
  @moduledoc """
  Structured representation of a prompt section contributed by a mount.

  The entire system prompt is assembled as a `[%PromptSection{}]`, then
  rendered into a final string via `render/2` using a configurable format.
  """

  @type t :: %__MODULE__{
          key: atom(),
          heading: String.t() | nil,
          body: String.t() | nil,
          subsections: [t()],
          examples: [String.t()],
          priority: :high | :normal | :low,
          kind: :instructions | :reference | :metadata,
          position: :prelude | :postlude
        }

  defstruct [
    :key,
    :heading,
    :body,
    subsections: [],
    examples: [],
    priority: :normal,
    kind: :instructions,
    position: :prelude
  ]

  @priority_order %{high: 0, normal: 1, low: 2}
  @position_order %{prelude: 0, postlude: 1}

  @doc "Create a new PromptSection."
  def new(fields) when is_list(fields), do: struct!(__MODULE__, fields)
  def new(%{} = fields), do: struct!(__MODULE__, fields)

  @doc "Wrap a raw string into a PromptSection (backward compat)."
  def from_string(text, opts \\ []) when is_binary(text) do
    %__MODULE__{
      key: Keyword.get(opts, :key, :unknown),
      heading: Keyword.get(opts, :heading),
      body: text,
      priority: Keyword.get(opts, :priority, :normal),
      kind: Keyword.get(opts, :kind, :instructions)
    }
  end

  @doc "Convert a binding map to a metadata PromptSection."
  def from_binding(%{name: name} = binding) do
    %__MODULE__{
      key: :"binding_#{name}",
      heading: nil,
      body: format_binding(binding),
      priority: :low,
      kind: :metadata
    }
  end

  @doc "Convert a list of bindings into a single metadata PromptSection."
  def from_bindings([]), do: nil

  def from_bindings(bindings) when is_list(bindings) do
    body = Enum.map_join(bindings, "\n", &format_binding/1)

    %__MODULE__{
      key: :bindings,
      heading: "Available Resources",
      body: body,
      priority: :low,
      kind: :metadata
    }
  end

  @doc """
  Render a list of PromptSections into a final string.

  Supported formats: `:markdown` (default), `:xml`.
  """
  def render(sections, format \\ :markdown) do
    sections
    |> sort_by_priority()
    |> Enum.map(&render_section(&1, format))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # --- Sorting ---

  defp sort_by_priority(sections) do
    sections
    |> Enum.with_index()
    |> Enum.sort_by(fn {s, idx} ->
      {
        @position_order[s.position || :prelude] || 0,
        @priority_order[s.priority] || 1,
        idx
      }
    end)
    |> Enum.map(&elem(&1, 0))
  end

  # --- Markdown rendering ---

  defp render_section(section, :markdown) do
    parts = []

    parts =
      if section.heading do
        [parts | ["## #{section.heading}"]]
      else
        parts
      end

    parts =
      if section.body && section.body != "" do
        [parts | [section.body]]
      else
        parts
      end

    parts =
      Enum.reduce(section.subsections, parts, fn sub, acc ->
        sub_parts = []

        sub_parts =
          if sub.heading do
            [sub_parts | ["### #{sub.heading}"]]
          else
            sub_parts
          end

        sub_parts =
          if sub.body && sub.body != "" do
            [sub_parts | [sub.body]]
          else
            sub_parts
          end

        sub_parts =
          Enum.reduce(sub.examples, sub_parts, fn ex, a ->
            [a | ["```\n#{ex}\n```"]]
          end)

        [acc | [IO.iodata_to_binary(Enum.intersperse(List.flatten(sub_parts), "\n\n"))]]
      end)

    parts =
      Enum.reduce(section.examples, parts, fn ex, acc ->
        [acc | ["```\n#{ex}\n```"]]
      end)

    IO.iodata_to_binary(Enum.intersperse(List.flatten(parts), "\n\n"))
  end

  # --- XML rendering ---

  defp render_section(section, :xml) do
    tag = to_string(section.kind || :instructions)
    key_attr = if section.key, do: ~s( key="#{section.key}"), else: ""

    inner = []

    inner =
      if section.heading do
        [inner | ["<heading>#{section.heading}</heading>"]]
      else
        inner
      end

    inner =
      if section.body && section.body != "" do
        [inner | ["<body>\n#{section.body}\n</body>"]]
      else
        inner
      end

    inner =
      Enum.reduce(section.subsections, inner, fn sub, acc ->
        [acc | [render_xml_subsection(sub)]]
      end)

    inner =
      Enum.reduce(section.examples, inner, fn ex, acc ->
        [acc | ["<example>\n#{ex}\n</example>"]]
      end)

    content = IO.iodata_to_binary(Enum.intersperse(List.flatten(inner), "\n"))
    "<#{tag}#{key_attr}>\n#{content}\n</#{tag}>"
  end

  defp render_xml_subsection(sub) do
    sub_inner = []

    sub_inner =
      if sub.heading do
        [sub_inner | ["<heading>#{sub.heading}</heading>"]]
      else
        sub_inner
      end

    sub_inner =
      if sub.body && sub.body != "" do
        [sub_inner | ["<body>\n#{sub.body}\n</body>"]]
      else
        sub_inner
      end

    sub_inner =
      Enum.reduce(sub.examples, sub_inner, fn ex, a ->
        [a | ["<example>\n#{ex}\n</example>"]]
      end)

    sub_attrs = if sub.key, do: ~s( key="#{sub.key}"), else: ""
    content = IO.iodata_to_binary(Enum.intersperse(List.flatten(sub_inner), "\n"))
    "<subsection#{sub_attrs}>\n#{content}\n</subsection>"
  end

  # --- Helpers ---

  defp format_binding(%{name: name, kind: kind, size: size, summary: summary, access: access}) do
    "`#{name}` (#{kind}, #{size} chars) — #{summary}. Access via #{access}."
  end
end
