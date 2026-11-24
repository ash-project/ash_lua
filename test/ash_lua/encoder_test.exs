# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.EncoderTest do
  use ExUnit.Case, async: true

  alias AshLua.Encoder
  alias AshLua.Errors.FieldsError

  defp function_value, do: {:native_func, fn args, state -> {args, state} end}

  describe "decode_input/1" do
    test "a key that is a Lua function raises invalid_table_key with its path" do
      error =
        assert_raise FieldsError, fn ->
          Encoder.decode_input([{"input", [{"meta", [{function_value(), 1}]}]}])
        end

      assert error.code == "invalid_table_key"
      assert error.fields == ["meta"]
      assert Map.new(error.vars) == %{"key" => "function", "path" => ["input", "meta"]}
    end

    test "a Lua function as a value is left in place" do
      value = function_value()
      assert Encoder.decode_input([{"f", value}]) == %{"f" => value}
    end
  end

  describe "decode_call_input/1" do
    test "a Lua function as a value raises invalid_value with its path" do
      error =
        assert_raise FieldsError, fn ->
          Encoder.decode_call_input([{"filter", [{"title", function_value()}]}])
        end

      assert error.code == "invalid_value"
      assert Map.new(error.vars) == %{"value" => "function", "path" => ["filter", "title"]}
    end

    test "userdata as a value raises invalid_value" do
      error =
        assert_raise FieldsError, fn ->
          Encoder.decode_call_input([{"limit", {:userdata, %{token: "t"}}}])
        end

      assert error.code == "invalid_value"
      assert Map.new(error.vars) == %{"value" => "userdata", "path" => ["limit"]}
    end

    test "plain data decodes as decode_input/1 does" do
      input = [{"input", [{"title", "t"}, {"tags", [{1, "a"}, {2, "b"}]}]}, {"limit", 5}]
      assert Encoder.decode_call_input(input) == Encoder.decode_input(input)
    end
  end

  describe "encode_result/1" do
    test "a key that is not valid UTF-8 is base64-encoded, like a value" do
      assert Encoder.encode_result(%{<<255>> => <<255>>, "ok" => 1}) == %{
               "/w==" => "/w==",
               "ok" => 1
             }
    end

    test "userdata is an opaque marker" do
      assert Encoder.encode_result({:userdata, %{token: "t"}}) == %{"opaque" => "userdata"}
    end

    test "a key that is a Lua reference raises invalid_table_key" do
      assert_raise FieldsError, ~r/not a table/, fn ->
        Encoder.encode_result([{{:tref, 1}, 1}])
      end
    end
  end
end
