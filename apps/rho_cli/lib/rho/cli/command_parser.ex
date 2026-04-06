defmodule Rho.CLI.CommandParser do
  @moduledoc """
  Parses `,tool_name key=value` command syntax.

  Commands start with `,` followed by a tool name and optional arguments.
  Arguments can be key=value pairs or positional values.
  Positional values are joined and stored under the "cmd" key for bash compatibility.
  """

  @doc """
  Parses a command line (without the leading comma) into {tool_name, args_map}.

  ## Examples

      iex> Rho.CommandParser.parse("bash ls -la")
      {"bash", %{"cmd" => "ls -la"}}

      iex> Rho.CommandParser.parse("fs_read path=/tmp/foo.txt")
      {"fs_read", %{"path" => "/tmp/foo.txt"}}

      iex> Rho.CommandParser.parse("web_fetch url=https://example.com")
      {"web_fetch", %{"url" => "https://example.com"}}

      iex> Rho.CommandParser.parse("")
      {"bash", %{}}

  """
  def parse(line) do
    line = String.trim(line)

    case String.split(line, ~r/\s+/, parts: 2) do
      [""] -> {"bash", %{}}
      [name] -> {name, %{}}
      [name, rest] -> {name, parse_args(rest)}
    end
  end

  @doc """
  Parses an argument string into a map.

  Key=value pairs become map entries. Positional (unkeyed) tokens are
  joined with spaces and stored under the "cmd" key.

  ## Examples

      iex> Rho.CommandParser.parse_args("path=/tmp/foo.txt")
      %{"path" => "/tmp/foo.txt"}

      iex> Rho.CommandParser.parse_args("ls -la /tmp")
      %{"cmd" => "ls -la /tmp"}

      iex> Rho.CommandParser.parse_args("path=/tmp echo hello")
      %{"path" => "/tmp", "cmd" => "echo hello"}

  """
  def parse_args(str) do
    tokens = OptionParser.split(str)

    {kv, positional} = Enum.split_with(tokens, &String.contains?(&1, "="))

    kwargs =
      Map.new(kv, fn token ->
        [k, v] = String.split(token, "=", parts: 2)
        {k, v}
      end)

    if positional != [] do
      Map.put(kwargs, "cmd", Enum.join(positional, " "))
    else
      kwargs
    end
  end
end
