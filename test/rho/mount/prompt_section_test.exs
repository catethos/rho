defmodule Rho.Mount.PromptSectionTest do
  use ExUnit.Case, async: true

  alias Rho.Mount.PromptSection

  describe "new/1" do
    test "creates struct with defaults" do
      s = PromptSection.new(key: :test, body: "hello")
      assert s.key == :test
      assert s.body == "hello"
      assert s.priority == :normal
      assert s.kind == :instructions
      assert s.subsections == []
      assert s.examples == []
    end
  end

  describe "from_string/2" do
    test "wraps text with defaults" do
      s = PromptSection.from_string("Be helpful.")
      assert s.body == "Be helpful."
      assert s.key == :unknown
      assert s.priority == :normal
    end

    test "accepts key and kind options" do
      s = PromptSection.from_string("data", key: :my_key, kind: :metadata)
      assert s.key == :my_key
      assert s.kind == :metadata
    end
  end

  describe "from_binding/1" do
    test "converts a binding map to metadata section" do
      binding = %{name: "journal", kind: :text_corpus, size: 42, summary: "Journal entries", access: :tool}
      s = PromptSection.from_binding(binding)
      assert s.key == :binding_journal
      assert s.kind == :metadata
      assert s.priority == :low
      assert s.body =~ "journal"
      assert s.body =~ "42"
    end
  end

  describe "from_bindings/1" do
    test "returns nil for empty list" do
      assert PromptSection.from_bindings([]) == nil
    end

    test "groups multiple bindings into one section" do
      bindings = [
        %{name: "journal", kind: :text_corpus, size: 10, summary: "Journal", access: :tool},
        %{name: "python", kind: :session_state, size: 3, summary: "REPL", access: :python_var}
      ]

      s = PromptSection.from_bindings(bindings)
      assert s.key == :bindings
      assert s.heading == "Available Resources"
      assert s.body =~ "journal"
      assert s.body =~ "python"
    end
  end

  describe "render/2 :markdown" do
    test "renders body-only section" do
      sections = [PromptSection.new(key: :base, body: "Hello world", priority: :high)]
      result = PromptSection.render(sections, :markdown)
      assert result == "Hello world"
    end

    test "renders heading + body" do
      sections = [PromptSection.new(key: :test, heading: "My Section", body: "Content here.")]
      result = PromptSection.render(sections, :markdown)
      assert result =~ "## My Section"
      assert result =~ "Content here."
    end

    test "renders subsections with ### headings" do
      sections = [
        PromptSection.new(
          key: :parent,
          heading: "Parent",
          body: "Top level.",
          subsections: [
            PromptSection.new(key: :child, heading: "Child", body: "Nested content.")
          ]
        )
      ]

      result = PromptSection.render(sections, :markdown)
      assert result =~ "## Parent"
      assert result =~ "### Child"
      assert result =~ "Nested content."
    end

    test "renders examples in code blocks" do
      sections = [
        PromptSection.new(
          key: :test,
          heading: "Test",
          body: "See examples:",
          examples: ["example 1", "example 2"]
        )
      ]

      result = PromptSection.render(sections, :markdown)
      assert result =~ "```\nexample 1\n```"
      assert result =~ "```\nexample 2\n```"
    end

    test "orders by priority" do
      sections = [
        PromptSection.new(key: :low, body: "LOW", priority: :low),
        PromptSection.new(key: :high, body: "HIGH", priority: :high),
        PromptSection.new(key: :normal, body: "NORMAL", priority: :normal)
      ]

      result = PromptSection.render(sections, :markdown)
      high_pos = :binary.match(result, "HIGH") |> elem(0)
      normal_pos = :binary.match(result, "NORMAL") |> elem(0)
      low_pos = :binary.match(result, "LOW") |> elem(0)
      assert high_pos < normal_pos
      assert normal_pos < low_pos
    end

    test "renders empty list as empty string" do
      assert PromptSection.render([], :markdown) == ""
    end
  end

  describe "render/2 :xml" do
    test "renders section with kind as xml tag" do
      sections = [
        PromptSection.new(key: :test, heading: "My Section", body: "Content.", kind: :reference)
      ]

      result = PromptSection.render(sections, :xml)
      assert result =~ ~s(<reference key="test">)
      assert result =~ "<heading>My Section</heading>"
      assert result =~ "<body>\nContent.\n</body>"
      assert result =~ "</reference>"
    end

    test "renders subsections in xml" do
      sections = [
        PromptSection.new(
          key: :parent,
          heading: "Parent",
          body: "Top.",
          subsections: [
            PromptSection.new(key: :child, heading: "Child", body: "Nested.")
          ]
        )
      ]

      result = PromptSection.render(sections, :xml)
      assert result =~ ~s(<subsection key="child">)
      assert result =~ "<heading>Child</heading>"
      assert result =~ "</subsection>"
    end

    test "renders examples in xml" do
      sections = [
        PromptSection.new(key: :test, body: "See:", examples: ["ex1"])
      ]

      result = PromptSection.render(sections, :xml)
      assert result =~ "<example>\nex1\n</example>"
    end
  end
end
