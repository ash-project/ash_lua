# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Resource do
  @lua %Spark.Dsl.Section{
    name: :lua,
    describe: """
    Resource-level configuration for AshLua.
    """,
    examples: [
      """
      lua do
        name "todo"
        expose? true
      end
      """
    ],
    schema: [
      name: [
        type: :string,
        doc:
          "The Lua key (under the domain table) to expose this resource as. Defaults to snake_case of the resource module's last segment."
      ],
      expose?: [
        type: :boolean,
        default: true,
        doc: "Whether to expose this resource and its public actions to Lua."
      ]
    ]
  }

  @moduledoc """
  Extension that exposes a single Ash resource's public actions to Lua scripts.

  Used in conjunction with `AshLua.Domain` on the resource's owning domain.
  """

  use Spark.Dsl.Extension, sections: [@lua]
end
