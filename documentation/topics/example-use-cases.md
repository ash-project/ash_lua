<!--
SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# Example use cases

Two illustrations of why you might reach for AshLua. The first is a
user-configurable scripting surface; the second is an `ash_ai`-driven MCP
server. Both ship today.

## 1. User-configurable scripts: a custom dashboard tile

A common pattern in admin tools and internal SaaS dashboards is letting users
build their own dashboard — pick what they want to see, with whatever logic
they want behind it. The hard part is letting that logic touch real data
without giving users a Phoenix shell or rebuilding queries in a config UI.

With AshLua, each dashboard tile can be a small Lua snippet, evaluated with the
viewing user's actor and tenant. The script can list, filter, and aggregate —
nothing else.

### The persistence side

Persist tile definitions as a resource of yours, e.g. `MyApp.Dashboards.Tile`,
with at least `name`, `description`, `script` (string), and an owner.

```elixir
defmodule MyApp.Dashboards.Tile do
  use Ash.Resource, domain: MyApp.Dashboards

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :script, :string, allow_nil?: false, public?: true
  end

  # ... owner relationship, actions, policies ...
end
```

### Rendering the tile

To render a tile for the current user, evaluate its script with that user as
the actor:

```elixir
defmodule MyAppWeb.TileLive do
  use MyAppWeb, :live_view

  def render_tile(tile, current_user) do
    case AshLua.eval!(tile.script,
           otp_app: :my_app,
           actor: current_user,
           tenant: current_user.org_id
         ) do
      {[value], _lua} -> {:ok, value}
    end
  rescue
    e in [Lua.RuntimeException, Lua.CompilerException] ->
      {:error, Exception.message(e)}
  end
end
```

### What the user writes

The script body is just Lua. The user references the operations exposed by
your domains — same surface AshLua's documentation describes. Three flavors of
useful tile:

**Count of overdue items in my queue**

```lua
return assert(work.todo.read({
  filter = { assigned_to_id = my_id, completed = false,
             due_date = { less_than = today() } },
  operation = "count"
}))
```

**Average rating of my last 10 reviews**

```lua
return assert(reviews.review.read({
  filter = { reviewer_id = my_id },
  sort   = "-created_at",
  limit  = 10,
  operation = { "avg", "rating" }
}))
```

**Top 5 best-selling products this week**

```lua
return assert(catalog.product.read({
  filter = { sold_at = { greater_than = ago(7, "day") } },
  sort   = "-units_sold",
  limit  = 5,
  fields = { "name", "units_sold" }
}))
```

### Why this is safe

The script can only:

  * Call operations on domains the host has exposed via `AshLua.Domain`.
  * Pass inputs that Ash already knows how to validate.
  * See data the actor is authorized to see — your existing authorization
    policies are the gate, exactly as they would be for any other Ash call.

The script **cannot**:

  * Read or change the actor, tenant, or context.
  * Reach into Elixir, the filesystem, the network, or other processes.
  * Spend more than the work an explicit query already would.

For free, you get a UI/UX where users wire up real, authorized data into their
own widgets without you building a query-builder UI for every combination of
filter + sort + fields + aggregate.

## 2. An AshLua-backed MCP server (via ash_ai)

[`ash_ai`](https://github.com/ash-project/ash_ai) already exposes Ash actions
to LLMs over the [Model Context Protocol](https://modelcontextprotocol.io/),
one tool per action. That's a great fit when the LLM's job is "create a Todo"
or "search for posts". It's less good when the job is "summarize all overdue
todos by category", "diff this user's activity week-over-week", or anything
else that needs *composition* — many calls combined and arithmetic between
them.

The natural fit: hand the LLM the Lua surface AshLua already publishes, and
let it write the composition itself.

This ships today. The `AshLua.EvalActions` extension synthesizes two generic
actions on a resource of yours, which you advertise through `ash_ai` as two
MCP tools — one to read the API surface, one to execute composed Lua against
it. See [Integrate with ash_ai](../how_to/integrate-with-ash-ai.md) for the
full setup; the rest of this section sketches the resulting LLM workflow.

The two tools an LLM ends up with:

| MCP tool        | Action                | Maps to                                                       |
|-----------------|-----------------------|--------------------------------------------------------------|
| `ash_lua_docs`  | `MCPActions.docs/1`   | `AshLua.Docs.full_doc/1`, `callable_doc/2`, `type_doc/2`, `search/2` |
| `ash_lua_eval`  | `MCPActions.eval/1`   | `AshLua.eval!(script, otp_app: app, actor: ..., tenant: ...)` |

`ash_lua_docs` covers both discovery (no arguments → the full surface;
`search: "..."` → ranked matches) and focus (`name: "..."` → one operation,
type, or topic), so a single tool replaces the separate "list callables" and
"get docs" probes.

### An example LLM workflow

A user asks: _"How many overdue, high-priority todos do I have, and what's the
average age of the oldest five?"_

The model probes the surface, then writes the script:

```text
LLM → ash_lua_docs({ search = "overdue todo" })
←   - `work.todo.read` (operation) — list todos with filtering
    - `work.todo` (record type) — record type
    ...

LLM → ash_lua_docs({ name = "work.todo.read" })
←   # `work.todo.read` ... (the markdown ash_lua generates today)

LLM → ash_lua_docs({ name = "work.todo" })
←   # Record type `work.todo` — fields include `priority`, `due_date`, `created_at`, ...

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
←   { result = { 12, [<5 todo records>] }, error = nil }
```

The model then takes the structured result and produces the answer. Crucially,
**every Ash call still went through that user's actor and tenant** — the LLM
never sees credentials, never bypasses authorization, and never makes up a
field name (the docs gave it the real surface up front).

### Why route LLMs through Lua instead of one-tool-per-action

When the LLM has one tool per action, it composes by making N tool calls and
doing arithmetic in its head between them. That's slow, expensive, and
error-prone — especially for any answer that requires combining results.

When the LLM has one tool that takes Lua, it composes inside the script. One
round-trip, one set of host-supplied identities, and the result is a real
value computed against the real database. The model still uses `get_docs` to
discover the surface — but instead of stitching results together itself, it
writes the stitching as code.

This pattern is what AshLua was built for.
