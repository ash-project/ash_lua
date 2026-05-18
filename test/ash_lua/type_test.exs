# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.TypeTest do
  use ExUnit.Case, async: true

  describe "type_name/1" do
    test "uses the module's type_name/0 callback when defined" do
      defmodule WithCallback do
        use AshLua.Type
        @impl AshLua.Type
        def type_name, do: "my_pretty_name"
      end

      assert AshLua.Type.type_name(WithCallback) == "my_pretty_name"
    end

    test "underscores Ash.Type.* modules by default" do
      assert AshLua.Type.type_name(Ash.Type.Boolean) == "boolean"
      assert AshLua.Type.type_name(Ash.Type.UUID) == "uuid"
      assert AshLua.Type.type_name(Ash.Type.CiString) == "ci_string"
    end

    test "falls back to the last module segment for other modules" do
      defmodule MyApp.Custom.SomeType do
      end

      assert AshLua.Type.type_name(MyApp.Custom.SomeType) == "SomeType"
    end
  end
end
