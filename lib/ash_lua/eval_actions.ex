# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.EvalActions do
  @expose %Spark.Dsl.Entity{
    name: :resource,
    target: AshLua.EvalActions.Expose,
    args: [:resource],
    describe: "Exposes a specific set of actions on a resource to the Lua surface.",
    examples: [
      "resource MyApp.Posts.Post, actions: [:read, :create]"
    ],
    schema: [
      resource: [
        type: :atom,
        required: true,
        doc: "The resource module to expose."
      ],
      actions: [
        type: {:or, [{:in, [:all]}, {:list, :atom}]},
        default: :all,
        doc:
          "Which actions on the resource to expose. `:all` (default) exposes every public action; otherwise pass an atom list."
      ]
    ]
  }

  @eval_actions %Spark.Dsl.Section{
    name: :eval_actions,
    describe: """
    Configures the Lua surface exposed to the synthesized `:eval` and `:docs` actions.

    Each `resource` entry pairs a resource module with the set of action names
    that the script (and the generated docs) is allowed to see. Use this to
    apply principle-of-least-privilege per agent surface — only the listed
    actions become callable from Lua and only those entrypoints appear in
    `:docs` output.
    """,
    examples: [
      """
      eval_actions do
        resource MyApp.Posts.Post, actions: [:read, :get_statistics]
        resource MyApp.Posts.Comment, actions: [:read]
      end
      """
    ],
    schema: [
      eval_action_name: [
        type: :atom,
        default: :eval,
        doc: "Name of the synthesized eval action. Defaults to `:eval`."
      ],
      docs_action_name: [
        type: :atom,
        default: :docs,
        doc: "Name of the synthesized docs action. Defaults to `:docs`."
      ],
      otp_app: [
        type: :atom,
        doc:
          "OTP app to scan when building the manifest. Defaults to the agent resource's domain's `:otp_app`."
      ]
    ],
    entities: [@expose]
  }

  @moduledoc """
  Resource extension that synthesizes `:eval` and `:docs` generic actions for
  driving an LLM agent against a scoped Lua surface.

  ```elixir
  defmodule MyApp.Agents.MCPActions do
    use Ash.Resource, extensions: [AshLua.EvalActions]

    eval_actions do
      resource MyApp.Posts.Post, actions: [:read, :get_statistics]
      resource MyApp.Posts.Comment, actions: [:read]
    end
  end
  ```

  The synthesized actions inherit the caller's actor / tenant / context — both
  the script body and the documentation rendering are constrained to the
  configured `(resource, action)` pairs, and every Ash call inside the Lua
  script flows through the standard authorization machinery.
  """

  use Spark.Dsl.Extension,
    sections: [@eval_actions],
    transformers: [AshLua.EvalActions.Transformers.AddActions]
end
