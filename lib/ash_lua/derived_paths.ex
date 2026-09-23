# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.DerivedPaths do
  @moduledoc false

  @doc """
  Groups exposed resources by their derived `domain.resource` Lua path and
  returns the paths claimed by more than one resource.
  """
  @spec collisions([module()]) :: [{String.t(), [module()]}]
  def collisions(resources) do
    resources
    |> Enum.uniq()
    |> Enum.filter(&exposed?/1)
    |> Enum.group_by(&path/1)
    |> Enum.filter(fn {_path, resources} -> length(resources) > 1 end)
    |> Enum.sort()
  end

  @spec messages([{String.t(), [module()]}]) :: [String.t()]
  def messages(collisions) do
    Enum.map(collisions, fn {path, resources} ->
      "#{Enum.map_join(resources, ", ", &inspect/1)} all derive the Lua path #{inspect(path)}. " <>
        "Give each a distinct name with `lua do name \"...\" end` (via the AshLua.Resource extension)."
    end)
  end

  defp exposed?(resource) do
    match?({:module, _}, Code.ensure_compiled(resource)) and
      AshLua.Resource.Info.expose?(resource)
  end

  defp path(resource) do
    domain = Ash.Resource.Info.domain(resource)
    AshLua.Domain.Info.name(domain) <> "." <> AshLua.Resource.Info.name(resource)
  end
end
