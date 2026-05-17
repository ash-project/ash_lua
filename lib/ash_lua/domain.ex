# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Domain do
  @lua %Spark.Dsl.Section{
    name: :lua,
    describe: """
    Domain-level configuration for AshLua.
    """,
    examples: [
      """
      lua do
        name "accounts"
      end
      """
    ],
    schema: [
      name: [
        type: :string,
        doc:
          "The Lua table name to expose this domain under. Defaults to snake_case of the domain module's last segment."
      ]
    ]
  }

  @moduledoc """
  Extension that exposes an Ash domain's resources to Lua scripts evaluated through `AshLua.eval/2`.
  """

  use Spark.Dsl.Extension, sections: [@lua]
end
