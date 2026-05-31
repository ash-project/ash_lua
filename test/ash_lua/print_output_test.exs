# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.PrintOutputTest do
  use ExUnit.Case, async: false

  alias AshLua.Test.Posts.MCPActions

  describe "AshLua.Runtime.print_output/1" do
    test "captures `print(...)` calls in call order" do
      {[], lua} =
        AshLua.eval!(
          """
          print("hello")
          print("world", 42)
          """,
          otp_app: :ash_lua
        )

      assert AshLua.Runtime.print_output(lua) == ["hello", "world\t42"]
    end

    test "returns [] when nothing was printed" do
      {_, lua} = AshLua.eval!("return 1", otp_app: :ash_lua)
      assert AshLua.Runtime.print_output(lua) == []
    end

    test "renders non-string args sensibly" do
      {_, lua} =
        AshLua.eval!(
          """
          print(nil, true, false)
          print({ a = 1 })
          print(print)
          """,
          otp_app: :ash_lua
        )

      [a, b, c] = AshLua.Runtime.print_output(lua)
      assert a == "nil\ttrue\tfalse"
      assert b =~ "a = 1"
      assert c == "<function>"
    end
  end

  describe ":eval action surfaces print_output" do
    test "captured prints are included in the response" do
      input =
        Ash.ActionInput.for_action(MCPActions, :eval, %{
          script: """
          print("starting")
          print("done")
          return 1
          """
        })

      assert {:ok, %{result: 1, error: nil, print_output: lines}} = Ash.run_action(input)
      assert lines == ["starting", "done"]
    end

    test "print_output is an empty list when nothing printed" do
      input =
        Ash.ActionInput.for_action(MCPActions, :eval, %{script: "return 42"})

      assert {:ok, %{print_output: []}} = Ash.run_action(input)
    end
  end
end
