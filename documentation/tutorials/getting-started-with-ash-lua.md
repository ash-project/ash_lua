<!--
SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# Getting started with AshLua

AshLua lets you expose your Ash domains and resources to Lua scripts, with a
consistent actor / tenant / context attached to every call. Scripts can read
data, create / update / delete records, and call generic actions — all using
the same authorization, validation, and types your application already uses
elsewhere.

This guide walks you through installing AshLua, exposing your first resource,
evaluating a Lua script, and using the documentation surface so you (or an
LLM-driven tool) can discover what's callable.

## 1. Install

Add the dependency:

```elixir
def deps do
  [
    {:ash_lua, "~> 0.1.0"}
  ]
end
```

Run the installer to wire the formatter and any extension defaults:

```sh
mix igniter.install ash_lua
```

## 2. Expose a domain and a resource

AshLua ships two Spark extensions: `AshLua.Domain` (for your domain modules)
and `AshLua.Resource` (for each resource you want to expose). Add them to
their respective `extensions:` lists.

```elixir
defmodule MyApp.Accounts do
  use Ash.Domain,
    otp_app: :my_app,
    extensions: [AshLua.Domain]

  resources do
    resource MyApp.Accounts.User
  end
end

defmodule MyApp.Accounts.User do
  use Ash.Resource,
    domain: MyApp.Accounts,
    extensions: [AshLua.Resource]

  # ... attributes / actions ...
end
```

By default, the domain is exposed under a Lua table named after the domain
module's last segment (snake_cased), and each resource under a similarly-derived
key. You can override either name:

```elixir
defmodule MyApp.Accounts do
  use Ash.Domain, otp_app: :my_app, extensions: [AshLua.Domain]

  lua do
    name "accounts"
  end

  # ...
end

defmodule MyApp.Accounts.User do
  use Ash.Resource, domain: MyApp.Accounts, extensions: [AshLua.Resource]

  lua do
    name "user"
  end

  # ...
end
```

With these defaults, every public action on `MyApp.Accounts.User` becomes
callable as `accounts.user.<action>(input)` from Lua.

## 3. Evaluate a Lua script

```elixir
{[user_id], _lua} =
  AshLua.eval!(
	    """
	    local user, err = accounts.user.create({
	      input = {
	        name = "Zach",
	        email = "z@example.com"
	      },
	      fields = { "id" }
	    })
    assert(err == nil)
    return user.id
    """,
    otp_app: :my_app,
    actor: current_user
  )
```

`AshLua.eval!/2` accepts:

  * `:otp_app` — required; the OTP app whose Ash domains to expose.
  * `:actor`, `:tenant`, `:context` — host-supplied; threaded through every Ash
    call the script makes. **These are not readable from Lua and cannot be
    overridden from the script** — the host is the sole source of authority.
  * `:manifest` / `:lua` — optional pre-built artifacts (for advanced use).

## 4. The Lua API shape

Every operation in Lua is called as a function on a domain table and returns
two values: a result and an error. A successful call returns `(result, nil)`;
a failed call returns `(nil, err_table)`.

```lua
local user, err = accounts.user.create({ input = { name = "Zach" } })

if err then
  -- err is a table:
  --   {
  --     class = "invalid" | "forbidden" | "framework" | "unknown",
  --     errors = { { message = "...", short_message = "...", code = "...", fields = {...}, vars = {...} }, ... }
  --   }
  -- There is no top-level message — a failure can carry several errors, so
  -- report the entries under `errors`:
  for _, e in ipairs(err.errors) do
    print("create failed:", e.message)
  end
else
  print("created user:", user.id)
end
```

If you'd rather have errors raise, wrap the call in Lua's built-in `assert`:

```lua
local user = assert(accounts.user.create({ input = { name = "Zach" } }))
```

`assert` returns the first value when the second is `nil`, and raises with the
second value otherwise — so it works exactly like an Elixir `!` variant for
free. Note that what's raised is the error *table*: `AshLua.Eval` recovers it
and returns it as the structured `error` in its result, but if you're calling
`AshLua.eval!/2` directly the raise surfaces as an opaque
`Lua.RuntimeException`. When you need a readable message rather than raise
semantics, use the two-value form above.

## 5. Choosing which fields come back

By default, operations that return records return **only the primary key**.
Pass a `fields` selection to opt into more:

```lua
local user = assert(accounts.user.read({
  fields = { "id", "name", "email" }
}))
```

`fields` accepts a tree:

```lua
fields = {
  "id", "title",                                       -- stored fields
  "title_upper",                                       -- computed fields
  "comment_count",                                     -- summary fields
  { author = { "id", "name" } },                       -- linked one-record
  { comments = { "id", "body" } },                     -- linked many-records
  { title_prefixed = { args = { prefix = ">> " } } },  -- computed with input
  { metadata = { "priority", "category" } },           -- structured-value sub-selection
  { coordinates = { "latitude" } },                    -- tuple sub-selection
  { content = { text = { "body" } } },                 -- one-of (union) member sub-selection
}
```

Passing `{ author = {} }` (an empty sub-selection) means "use the default for
the linked record" — primary key only. Passing an explicit list selects exactly
what you ask for and nothing else.

Unknown fields, unknown computed-field arguments, and other selection mistakes
surface as a structured `(nil, err)` with `code = "invalid_fields"`.

## 6. Querying lists

List-style read operations accept a few reserved keys:

```lua
local results = assert(posts.post.read({
  filter  = { published = true },                  -- narrow the result set
  sort    = "-created_at",                         -- `-` prefix for descending
  limit   = 10,
  offset  = 20,
  fields  = { "title", { author = { "name" } } },
}))
```

To paginate with a cursor instead, use `page = { limit = 10, after = "..." }`.
The result becomes a table with `results`, `count`, `limit`, `more?`, and
`offset` or `before` / `after` depending on the pagination style.

To summarize a result set without retrieving the records, use `operation`:

```lua
local total      = assert(posts.post.read({ operation = "count" }))
local any        = assert(posts.post.read({ operation = "exists" }))
local avg_rating = assert(posts.comment.read({ operation = { "avg", "rating" } }))
local high_sum   = assert(posts.comment.read({
  filter    = { rating = { greater_than_or_equal = 5 } },
  operation = { "sum", "rating" }
}))
```

Supported operations: `"count"`, `"exists"`, and `{ "sum" | "avg" | "min" |
"max" | "count", "<field>" }`.

## 7. Mutations

Create / update / delete behave like read, except action fields and arguments go
under the `input` key. Update and delete take the primary key there too:

```lua
local post = assert(posts.post.create({
  input = { title = "Hello", body = "World" },
  fields = { "id", "title" }
}))

local updated = assert(posts.post.update({
  input = { id = post.id, title = "Hello again" },
  fields = { "title" }
}))

assert(posts.post.destroy({ input = { id = post.id } }))
```

Generic actions (defined with `action :name, type do ... end`) take their
declared arguments and return whatever the action returns — a scalar, a map,
a list, whatever. `fields` is honored when the return type is a record or a
structured value.

## 8. Discovering the API surface

`AshLua.Docs` produces per-operation and per-record-type markdown straight from
your domains — useful both as a reading aid and as a feed for an MCP
`search_docs` / `get_docs` tool (e.g. `ash_ai`).

```elixir
AshLua.Docs.list_callables(otp_app: :my_app)
# => ["accounts.user.create", "accounts.user.read", ...]

{:ok, md} = AshLua.Docs.callable_doc([otp_app: :my_app], "accounts.user.create")

AshLua.Docs.list_types(otp_app: :my_app)
# => ["accounts.user", ...]

{:ok, md} = AshLua.Docs.type_doc([otp_app: :my_app], "accounts.user")

# Or get one rendered page covering everything:
AshLua.Docs.full_doc(otp_app: :my_app)
```

The rendered pages deliberately avoid implementation vocabulary — they describe
operations as `get` / `list` / `create` / `update` / `delete` / `call`, and
treat stored, computed, and summary fields uniformly as "fields".

## 9. Authorization and multitenancy

The actor, tenant, and context you pass to `AshLua.eval!/2` are merged into
every Ash call the script makes. That means:

  * Authorization policies fire as they normally would for that actor.
  * Tenant-scoped resources are scoped to the tenant you supplied.
  * Custom context (audit metadata, request IDs, etc.) reaches your changes,
    preparations, and policies.

There is intentionally **no Lua-side API** to read or modify any of these — a
script cannot escalate its actor, leak its actor's identity, or switch tenants.

## Next steps

  * Run `AshLua.Docs.full_doc(otp_app: :my_app)` to see what's automatically
    exposed.
  * Look at the per-callable pages for operations you want to script against.
  * Wire `AshLua.eval!/2` into wherever scripts come from in your application
    (admin UI, scheduled jobs, MCP tools, etc.).
