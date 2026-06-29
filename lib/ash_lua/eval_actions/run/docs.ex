# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.EvalActions.Run.Docs do
  @moduledoc """
  Implementation backing the synthesized `:docs` action.

  Returns markdown for the scoped Lua surface, in one of three modes:

    * **`search` set** — runs `AshLua.Docs.search/2` over the scoped surface
      and returns a ranked list of matches. The list is intended as a
      discovery aid; follow up with the same action using `name` set to one
      of the returned ids.
    * **`name` set** — resolves against the scoped manifest and returns the
      focused page (callable, record-type, named-type, or topic). The reserved
      name `"full"` returns the entire scoped page (`AshLua.Docs.full_doc/1`).
    * **neither set** — returns a compact index of the scoped surface
      (`AshLua.Docs.index_doc/1`).

  Passing both `name` and `search` is an error.
  """

  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    AshLua.Eval.docs(
      [eval_resource: input.resource],
      name: Map.get(input.arguments, :name),
      search: Map.get(input.arguments, :search)
    )
  end
end
