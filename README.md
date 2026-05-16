<!--
SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# AshLua

[![Hex version badge](https://img.shields.io/hexpm/v/ash_lua.svg)](https://hex.pm/packages/ash_lua)
[![Hexdocs badge](https://img.shields.io/badge/docs-hexdocs-purple)](https://hexdocs.pm/ash_lua)

AshLua provides function definitions to the [`lua`](https://hex.pm/packages/lua)
Elixir package, ensuring a consistent actor, tenant (statically configured or
dynamically supplied from the script), and context are merged into all calls.

## Installation

Add `ash_lua` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ash_lua, "~> 0.1.0"}
  ]
end
```

Then run the installer:

```sh
mix igniter.install ash_lua
```
