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

  With `filter_docs_by_actor? true`, operations the calling actor certainly
  cannot run are left out of every mode. The check runs per call, after the
  cached manifest is resolved, so the cache stays actor-free.
  """

  use Ash.Resource.Actions.Implementation

  require Logger

  @impl true
  def run(input, _opts, context) do
    resource = input.resource
    name = Map.get(input.arguments, :name)
    args = [name: name, search: Map.get(input.arguments, :search)]

    result =
      if AshLua.EvalActions.Info.filter_docs_by_actor?(resource) do
        with {:ok, manifest} <- AshLua.Eval.manifest(eval_resource: resource, cache?: true) do
          manifest
          |> authorized_entrypoints(context)
          |> AshLua.Eval.docs(args)
        end
      else
        AshLua.Eval.docs([eval_resource: resource, cache?: true], args)
      end

    maybe_append_pagination_note(result, resource, name)
  end

  defp authorized_entrypoints(manifest, context) do
    source_context = Map.get(context, :source_context)

    opts = [
      tenant: context.tenant,
      context: if(is_map(source_context), do: source_context, else: %{}),
      maybe_is: true,
      run_queries?: false,
      pre_flight?: false
    ]

    %{manifest | entrypoints: Enum.filter(manifest.entrypoints, &can?(&1, context.actor, opts))}
  end

  defp can?(%{resource: resource, action: %{name: action}}, actor, opts) do
    if Ash.Resource.Info.authorizers(resource) == [] do
      true
    else
      Ash.can?({resource, action}, actor, opts)
    end
  rescue
    e ->
      Logger.warning("""
      Error raised while checking whether the actor can run #{inspect(resource)}.#{action}, \
      so it is left out of the docs. The check builds the action with empty input.

      #{Exception.format(:error, e, __STACKTRACE__)}
      """)

      false
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
