<!--
SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>

SPDX-License-Identifier: MIT
-->

<img src="https://github.com/ash-project/ash_lua/blob/main/logos/logo.svg?raw=true" alt="AshLua" width="220" align="right" />

# AshLua

[![Hex version badge](https://img.shields.io/hexpm/v/ash_lua.svg)](https://hex.pm/packages/ash_lua)
[![Hexdocs badge](https://img.shields.io/badge/docs-hexdocs-purple)](https://hexdocs.pm/ash_lua)

AshLua exposes your Ash domains and resources to Lua scripts, with a consistent
actor, tenant, and context attached to every call. Scripts can read records,
mutate them, and invoke generic actions — all through the same authorization,
validation, and types your application already uses elsewhere.

It ships with a manifest-driven documentation surface (`AshLua.Docs`) designed
to feed an MCP `search_docs` / `get_docs` tool, so an LLM client can discover
and call your API without prior knowledge.

## Installation

Add `ash_lua` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ash_lua, "~> 0.1.6"}
  ]
end
```

Then run the installer:

```sh
mix igniter.install ash_lua
```

See the [getting started guide](documentation/tutorials/getting-started-with-ash-lua.md)
for a walkthrough.

## Roadmap

The current `0.1.x` line is functional but a few pieces are still missing.

  * **Configurable input/output naming.** Domain and resource names are
    overridable today via `lua do name "..." end`; field-level renames are
    planned.

Issues / ideas welcome at
[ash-project/ash_lua/issues](https://github.com/ash-project/ash_lua/issues).
