<!--
SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# Integrate with ash_ai

[`ash_ai`](https://github.com/ash-project/ash_ai) exposes Ash actions to LLMs
over the Model Context Protocol. The natural unit of work there is "call one
action" — perfect for "create a Todo" or "search for posts", less perfect for
"summarize all overdue todos by category".

AshLua plugs into the same pipeline with two compact actions on a resource of
yours, declared via the `AshLua.EvalActions` extension. Once exposed through
`ash_ai`, an LLM gets exactly two new tools — one to read the API surface, one
to execute composed Lua against it — instead of one tool per Ash action. The
LLM does the composition inside Lua, in one round-trip, with the host's actor
and tenant attached.

## The shape

Define one resource per "agent surface" you want to expose:

```elixir
defmodule MyApp.Agents.MCPActions do
  use Ash.Resource,
    domain: MyApp.Agents,
    extensions: [AshLua.EvalActions]

  eval_actions do
    resource MyApp.Posts.Post, actions: [:read, :get_statistics]
    resource MyApp.Posts.Comment, actions: [:read]
    resource MyApp.Accounts.User, actions: [:read, :create]
  end
end
```

That's the whole declaration. The extension synthesizes two generic actions on
`MCPActions`:

  * **`:eval`** — takes a Lua `script` and runs it through `AshLua.eval!/2`,
    scoped to *only* the listed `(resource, action)` pairs. Returns
    `%{result, error}` (mirroring the in-script `(result, err)` convention).
  * **`:docs`** — returns markdown documentation for the same scoped surface,
    in one of three modes:
      * no arguments → the full rendered page (`AshLua.Docs.full_doc/1`);
      * `name: "..."` → the focused page for that callable, type, or topic;
      * `search: "..."` → a ranked list of matching ids, intended as a
        discovery aid (then follow up with the same action using `name`).

    `name` and `search` are mutually exclusive.

Both actions inherit the standard Ash machinery: the calling actor, tenant,
and context are passed straight through to every Ash call the Lua script
performs. There is no way for a script to escalate, switch tenants, or call
operations outside the scoped set.

The synthesized action names are configurable. Use this when you want multiple
agent surfaces co-existing under different tool names, or when the defaults
collide with action names you've already defined:

```elixir
eval_actions do
  eval_action_name :run_lua
  docs_action_name :describe_lua

  resource MyApp.Posts.Post, actions: [:read]
end
```

## Why one resource, two actions

The pair maps onto exactly what an LLM client needs to drive itself:

| LLM intent                                | Action call                        |
|-------------------------------------------|------------------------------------|
| "What can I do here?"                     | `MCPActions.docs(%{})`              |
| "Find anything about overdue todos."      | `MCPActions.docs(%{search: "..."})` |
| "Tell me more about this one operation."  | `MCPActions.docs(%{name: "..."})`   |
| "Do this composed thing for me."          | `MCPActions.eval(%{script: "..."})` |

Because the actions live on a regular Ash resource, they reuse everything else
you already have — policies, code-interface generation, logging, telemetry,
ash_ai tool-exposure. From `ash_ai`'s perspective, these are two ordinary
actions to advertise as MCP tools.

## Scoping the surface

`eval_actions` is the source of truth for which operations the script (and
generated docs) can see. The script can only call `<domain>.<resource>.<action>`
paths that correspond to a listed `(resource, action)` pair; everything else
is invisible (no entry in the docs, no callable in the Lua environment).

This is the natural place to apply "principle of least privilege" — expose
only the actions that are safe and useful for the agent you're building, and
omit anything destructive or expensive. You can run multiple agent resources
side-by-side, each with its own scope:

```elixir
defmodule MyApp.Agents.ReadOnlyMCP do
  use Ash.Resource,
    domain: MyApp.Agents,
    extensions: [AshLua.EvalActions]

  eval_actions do
    resource MyApp.Posts.Post, actions: [:read]
    resource MyApp.Posts.Comment, actions: [:read]
  end
end

defmodule MyApp.Agents.SupportMCP do
  use Ash.Resource,
    domain: MyApp.Agents,
    extensions: [AshLua.EvalActions]

  eval_actions do
    resource MyApp.Support.Ticket, actions: [:read, :create, :reassign]
    resource MyApp.Accounts.User, actions: [:read]
  end
end
```

## Wiring it to ash_ai

`ash_ai` exposes Ash actions as MCP tools through its own `tools do ... end`
block on the domain. Register both synthesized actions there — the LLM will
then see them under whatever names you give the `tool` declarations:

```elixir
defmodule MyApp.Agents do
  use Ash.Domain, otp_app: :my_app, extensions: [AshAi]

  resources do
    resource MyApp.Agents.MCPActions
  end

  tools do
    tool :ash_lua_docs, MyApp.Agents.MCPActions, :docs
    tool :ash_lua_eval, MyApp.Agents.MCPActions, :eval
  end
end
```

If you customised the synthesized action names via `eval_action_name` /
`docs_action_name`, pass the same names to the third argument of `tool`:

```elixir
tools do
  tool :read_lua_surface, MyApp.Agents.MCPActions, :describe_lua
  tool :run_lua,          MyApp.Agents.MCPActions, :run_lua
end
```

The LLM sees the two MCP tool names you declared (`ash_lua_docs`,
`ash_lua_eval`, or your custom ones). Both share the actor and tenant
configured for the MCP session — `ash_ai` threads those through into the
generic action's context, and from there into every Ash call the Lua script
performs.

## A walkthrough

The user asks: _"How many overdue, high-priority todos do I have, and what's
the average age of the oldest five?"_

```text
LLM → ash_lua_docs({ search = "overdue todo" })
←   # Search results for `overdue todo`
    - `work.todo.read` (operation) — list todos with filtering
    - `work.todo` (record type) — record type
    ...

LLM → ash_lua_docs({ name = "work.todo.read" })
←   # `work.todo.read` … (the per-operation page)

LLM → ash_lua_docs({ name = "work.todo" })
←   # Record type `work.todo` … (fields, filterable predicates, …)

LLM → ash_lua_eval({ script = """
  local overdue = assert(work.todo.read({
    filter    = { priority = "high", completed = false,
                  due_date = { less_than = today() } },
    operation = "count"
  }))

  local sample = assert(work.todo.read({
    filter = { priority = "high", completed = false,
               due_date = { less_than = today() } },
    sort   = "created_at",
    limit  = 5,
    fields = { "created_at" }
  }))

  return overdue, sample
""" })
←   { 12, [<5 records>] }
```

One round-trip's worth of `eval` covers what would otherwise be many tool
calls plus arithmetic the model has to do itself. Every Ash call inside the
script still flowed through the user's actor, tenant, and policies.

## What `:eval` returns

The action's return is whatever the script returns from Lua. Because Ash
actions need a stable return shape, the synthesized `:eval` action's
`returns` is structured along the same lines as the Lua-side
`(result, err)` convention:

```elixir
%{
  result:       <encoded Lua value, or nil on error>,
  error:        <%{ class, errors: [...] } or nil>,
  print_output: [<line>, ...]
}
```

A successful script run populates `result` and leaves `error` nil; a failed
script run does the opposite. This mirrors the in-script `(result, err)`
convention so the LLM's reasoning about success/failure looks the same at
both layers.

`print_output` collects anything the script printed with Lua's built-in
`print(...)`, in call order — useful for the model to leave itself
breadcrumbs while a script runs. See the `print-output` topic via `:docs`
for details.

## What `:docs` returns

`:docs` operates in three modes depending on its arguments:

  * **No arguments** — returns the full markdown page from
    `AshLua.Docs.full_doc/1`, restricted to the scoped surface.
  * **`name: "..."`** — returns a single focused page:
      * a callable path like `"work.todo.read"` → the per-operation page from
        `AshLua.Docs.callable_doc/2`;
      * a record-type path like `"work.todo"` or a named type like `"Status"`
        → the page from `AshLua.Docs.type_doc/2`;
      * a topic id like `"filters"` → the topic page from
        `AshLua.Docs.topic_doc/2`.

    Unknown names return an `:invalid_argument` error.

  * **`search: "..."`** — returns markdown listing up to 20 matching ids
    ranked by relevance (`AshLua.Docs.search/2`). Each line shows the id, its
    kind (operation / record type / type / topic), and a one-line summary.
    The LLM then picks one and follows up with `name`.

`name` and `search` are mutually exclusive — passing both returns an
`:invalid_argument` error on `:search`.

## Why not just expose every action directly?

You can — and `ash_ai` does this well for direct, single-action workflows
("create this Todo", "look up that User"). The trade-off shows up the moment
the user asks something compositional:

  * **One tool per action:** the LLM makes N round-trips, holds intermediate
    results in its context window, and does arithmetic between them. More
    tokens, more error surface, no transactionality across the steps.
  * **`eval` + `docs`:** the LLM writes the composition as a Lua script.
    Everything runs in one round-trip against the real database, with one
    consistent actor / tenant / context, and the model only has to reason
    about the final value.

Both approaches coexist — wire them up alongside each other and let the model
pick the right tool for the request.
