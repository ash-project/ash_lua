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
    * **neither set** — returns one line per operation
      (`AshLua.Docs.abridged_doc/1`), also reachable as `"abridged"`.

  Passing both `name` and `search` is an error.
  """

  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    name = Map.get(input.arguments, :name)

    [eval_resource: input.resource, cache?: true]
    |> AshLua.Eval.docs(name: name, search: Map.get(input.arguments, :search))
    |> maybe_append_pagination_note(input.resource, name)
  end

  defp maybe_append_pagination_note({:ok, doc}, resource, name)
       when name in [nil, "", "abridged", "full", "pagination"] do
    if AshLua.EvalActions.Info.require_pagination?(resource) do
      {:ok, doc <> "\n\n" <> pagination_note(resource)}
    else
      {:ok, doc}
    end
  end

  defp maybe_append_pagination_note(result, _resource, _name), do: result

  defp pagination_note(resource) do
    """
    **Pagination is required on this surface.** Every list operation that supports pagination
    returns the page table (`results`, `limit`, `more?`, ...) even without `page`, holding at most
    the action's default page size (#{AshLua.EvalActions.Info.default_page_size(resource)} unless the action sets its own).
    Pass `page = { limit = n }` or `limit`/`offset` to page through, and follow `more?`.
    """
    |> String.trim_trailing()
  end
end
