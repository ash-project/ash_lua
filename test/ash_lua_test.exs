defmodule AshLuaTest do
  use ExUnit.Case
  doctest AshLua

  test "greets the world" do
    assert AshLua.hello() == :world
  end
end
