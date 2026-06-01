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
    resource = input.resource

    name = Map.get(input.arguments, :name)
    search = Map.get(input.arguments, :search)

    if present?(name) and present?(search) do
      {:error,
       Ash.Error.Action.InvalidArgument.exception(
         field: :search,
         message: "`name` and `search` are mutually exclusive — pass at most one"
       )}
    else
      with {:ok, manifest} <- AshLua.Surface.for_eval_resource(resource) do
        dispatch(manifest, name, search)
      end
    end
  end

  defp dispatch(manifest, _name, search) when is_binary(search) and search != "" do
    {:ok, AshLua.Docs.search(manifest, search)}
  end

  defp dispatch(manifest, name, _search) when name in [nil, ""] do
    {:ok, AshLua.Docs.index_doc(manifest)}
  end

  defp dispatch(manifest, "full", _search) do
    {:ok, AshLua.Docs.full_doc(manifest)}
  end

  defp dispatch(manifest, name, _search) when is_binary(name) do
    cond do
      name in AshLua.Docs.list_callables(manifest) ->
        AshLua.Docs.callable_doc(manifest, name)

      name in AshLua.Docs.list_types(manifest) ->
        AshLua.Docs.type_doc(manifest, name)

      name in AshLua.Docs.topics(manifest) ->
        AshLua.Docs.topic_doc(manifest, name)

      true ->
        {:error,
         Ash.Error.Action.InvalidArgument.exception(
           field: :name,
           message: "no callable, type, or topic named #{inspect(name)} in the exposed surface"
         )}
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(value) when is_binary(value), do: true
  defp present?(_), do: false
end
