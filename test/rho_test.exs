defmodule RhoTest do
  use ExUnit.Case
  doctest Rho

  test "greets the world" do
    assert Rho.hello() == :world
  end
end
