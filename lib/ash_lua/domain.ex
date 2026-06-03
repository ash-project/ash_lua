# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Domain do
  @action %Spark.Dsl.Entity{
    name: :action,
    target: AshLua.Domain.Action,
    args: [:name, :resource, :action],
    describe: "Expose an Ash action at a public Lua function name inside a namespace.",
    examples: [
      """
      namespace "pages" do
        action :list, MyApp.StorefrontPage, :list_for_storefront
      end
      """
    ],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The Lua function name inside the namespace."
      ],
      resource: [
        type: {:spark, Ash.Resource},
        required: true,
        doc: "The Ash resource that owns the action."
      ],
      action: [
        type: :atom,
        required: true,
        doc: "The internal Ash action to call."
      ]
    ]
  }

  @namespace %Spark.Dsl.Entity{
    name: :namespace,
    target: AshLua.Domain.Namespace,
    args: [:name],
    describe: "Defines a public Lua namespace for actions.",
    examples: [
      """
      namespace "pages" do
        action :list, MyApp.StorefrontPage, :list_for_storefront
      end
      """,
      """
      namespace "storefronts.pages" do
        action :list, MyApp.StorefrontPage, :list_for_storefront
      end
      """
    ],
    schema: [
      name: [
        type: {:or, [:string, {:list, :string}]},
        required: true,
        doc:
          "The public Lua namespace. Dotted strings are split into nested Lua tables, so \"storefronts.pages\" exposes `storefronts.pages.*`."
      ]
    ],
    entities: [
      actions: [@action]
    ]
  }

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
    ],
    entities: [@namespace]
  }

  @moduledoc """
  Extension that exposes an Ash domain's resources to Lua scripts evaluated through `AshLua.eval!/2`.
  """

  use Spark.Dsl.Extension,
    sections: [@lua],
    verifiers: [AshLua.Domain.Verifiers.VerifySurface]
end
