<!--
SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# Use AshLua as a runtime

`AshLua.EvalActions` is convenient when another Ash-based integration should
expose `:docs` and `:eval` as ordinary Ash actions. For custom transports or
in-process LLM loops, use `AshLua.Eval` directly instead.

The runtime API has the same shape as the generated actions:

  * resolve a scoped manifest;
  * expose documentation for that manifest;
  * run Lua against a fresh VM with the caller's actor, tenant, and context.

## Define the surface

Declare the public Lua namespace on your domains. Labels let each consuming
runtime pick the subset it should expose.

```elixir
defmodule MyApp.Content do
  use Ash.Domain,
    otp_app: :my_app,
    extensions: [AshLua.Domain]

  lua do
    namespace "posts" do
      action :list, MyApp.Posts.Post, :read, labels: [:public, :read_model]
      action :create, MyApp.Posts.Post, :create, labels: [:public, :writes]
    end
  end
end
```

You can either define an `AshLua.EvalActions` resource and reuse its scope:

```elixir
defmodule MyApp.AgentSurface do
  use Ash.Resource,
    domain: MyApp.Agents,
    extensions: [AshLua.EvalActions]

  eval_actions do
    labels [:public]
  end
end
```

or build the scope directly from the OTP app and labels:

```elixir
{:ok, manifest} = AshLua.Eval.manifest(otp_app: :my_app, labels: [:public])
```

## Run scripts directly

Resolve or preload the manifest once, then pass it into each invocation:

```elixir
manifest = AshLua.Eval.manifest!(eval_resource: MyApp.AgentSurface)

{:ok, %{result: result, error: nil, print_output: prints}} =
  AshLua.Eval.run(
    """
    local posts = assert(posts.list({ fields = { "id", "title" }, limit = 10 }))
    print("loaded " .. #posts .. " posts")
    return posts
    """,
    manifest: manifest,
    actor: current_user,
    tenant: tenant,
    context: %{request_id: request_id}
  )
```

Each call builds a fresh Lua VM. State that should survive between calls must
live in your application through the exposed Ash actions.

## Serve docs

`AshLua.Eval.docs/2` returns the same markdown as the generated `:docs` action:

```elixir
{:ok, index} = AshLua.Eval.docs(manifest)
{:ok, page} = AshLua.Eval.docs(manifest, name: "posts.list")
{:ok, matches} = AshLua.Eval.docs(manifest, search: "published posts")
```

These functions are transport-agnostic. A custom MCP tool, HTTP endpoint, job,
or internal LLM loop can use the same functions and adapt the return value to
its own protocol.

## Bound the Lua VM

For untrusted or model-generated scripts, pass `lua_options:` through to
`Lua.new/1`:

```elixir
AshLua.Eval.run(script,
  manifest: manifest,
  actor: current_user,
  lua_options: [
    max_instructions: 100_000,
    max_call_depth: 100,
    max_string_bytes: 1_000_000
  ]
)
```

The Lua package's default sandbox remains in effect unless you pass a custom
prebuilt `:lua` VM. Prefer manifest caching over VM caching: the manifest is
immutable surface data, while the VM carries request-specific actor, tenant,
context, private state, and captured output.

## Preload in production

If you use `AshLua.EvalActions` resources to define scopes, preload their
manifests during application boot:

```elixir
AshLua.preload_eval_manifests!(:my_app)
```

After preload, `AshLua.Eval.manifest(eval_resource: MyApp.AgentSurface)` and
the generated actions use the cached manifest. Each script invocation still
gets a fresh Lua VM.
