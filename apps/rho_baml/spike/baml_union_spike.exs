# Spike: verify how baml_elixir parses a discriminated union.
#
# Run from umbrella root:
#
#   mix run apps/rho_baml/spike/baml_union_spike.exs
#
# Output shows the raw shape baml_elixir returns when calling a function
# whose return type is `FooAction | BarAction`. The two variants differ
# only in how the discriminant is declared:
#
#   Variant A — `tool "foo"` (literal-typed field)
#   Variant B — `tool string` (plain string)
#
# What we care about per result:
#   * Is the result a struct or a plain map?
#   * Is `__baml_class__` present? What value?
#   * Is `tool` populated as a map key (atom or string)?
#   * What other fields appear / are nil?

defmodule UnionSpike do
  @client_baml ~S'''
  client SpikeOpenRouter {
    provider "openai-generic"
    options {
      base_url "https://openrouter.ai/api/v1"
      model "anthropic/claude-haiku-4.5"
      api_key env.OPENROUTER_API_KEY
    }
  }
  '''

  @schema_a ~S'''
  class FooActionA {
    tool "foo" @description("Pick foo when input is a string")
    x string
    thinking string?
  }

  class BarActionA {
    tool "bar" @description("Pick bar when input is a number")
    y int
    thinking string?
  }

  function PickA(input: string) -> FooActionA | BarActionA {
    client SpikeOpenRouter
    prompt #"
      Input: {{ input }}

      {{ ctx.output_format }}
    "#
  }
  '''

  # Variant B: class-level @description (instead of field-level)
  @schema_b ~S'''
  /// Pick foo when input is a string
  class FooActionB {
    tool "foo"
    x string
    thinking string?
  }

  /// Pick bar when input is a number
  class BarActionB {
    tool "bar"
    y int
    thinking string?
  }

  function PickB(input: string) -> FooActionB | BarActionB {
    client SpikeOpenRouter
    prompt #"
      Input: {{ input }}

      {{ ctx.output_format }}
    "#
  }
  '''

  def run do
    load_dotenv()

    unless System.get_env("OPENROUTER_API_KEY") do
      raise "OPENROUTER_API_KEY not set in environment"
    end

    {:ok, parent} = Briefly.create(directory: true)
    dir = Path.join(parent, "baml_src")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "client.baml"), @client_baml)

    IO.puts("\n========================================")
    IO.puts(" Variant A: literal-typed `tool \"foo\"` ")
    IO.puts("========================================")
    File.write!(Path.join(dir, "schema.baml"), @schema_a)
    inspect_call("PickA", "this is a banana", dir)
    inspect_call("PickA", "the number is 42", dir)

    IO.puts("\n========================================")
    IO.puts(" Variant B: plain `tool string`         ")
    IO.puts("========================================")
    File.write!(Path.join(dir, "schema.baml"), @schema_b)
    inspect_call("PickB", "this is a banana", dir)
    inspect_call("PickB", "the number is 42", dir)
  end

  defp load_dotenv do
    case File.read(".env") do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.each(fn line ->
          case String.split(line, "=", parts: 2) do
            [k, v] -> System.put_env(String.trim(k), String.trim(v))
            _ -> :ok
          end
        end)

      _ ->
        :ok
    end
  end

  defp inspect_call(fn_name, input, dir) do
    IO.puts("\n--- #{fn_name}(\"#{input}\") ---")

    result =
      BamlElixir.Client.call(
        fn_name,
        %{input: input},
        %{path: dir, parse: false}
      )

    case result do
      {:ok, parsed} ->
        IO.inspect(parsed, label: "raw_parsed", structs: false, limit: :infinity)
        IO.inspect(is_struct(parsed), label: "is_struct?")
        IO.inspect(Map.keys(parsed), label: "keys")
        IO.inspect(Map.get(parsed, :__baml_class__), label: ":__baml_class__")
        IO.inspect(Map.get(parsed, :tool), label: ":tool (atom key)")
        IO.inspect(Map.get(parsed, "tool"), label: "\"tool\" (string key)")

      {:error, reason} ->
        IO.inspect(reason, label: "ERROR")
    end
  end
end

# Briefly may not be in deps; fall back to System.tmp_dir.
unless Code.ensure_loaded?(Briefly) do
  defmodule Briefly do
    def create(directory: true) do
      path =
        Path.join(System.tmp_dir!(), "baml_union_spike_#{System.unique_integer([:positive])}")

      File.mkdir_p!(path)
      {:ok, path}
    end
  end
end

UnionSpike.run()
