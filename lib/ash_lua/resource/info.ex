# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Resource.Info do
  @moduledoc "Introspection helpers for `AshLua.Resource`."

  alias Spark.Dsl.Extension

  @doc """
  The Lua key (under the domain table) to expose this resource as.

  Falls back to snake_case of the resource module's last segment.
  """
  @spec name(Ash.Resource.t() | Spark.Dsl.t()) :: String.t()
  def name(resource) do
    case Extension.get_opt(resource, [:lua], :name, nil) do
      nil -> default_name(resource)
      name -> name
    end
  end

  @doc "Whether the resource should be exposed to Lua. Defaults to `true`."
  @spec expose?(Ash.Resource.t() | Spark.Dsl.t()) :: boolean()
  def expose?(resource) do
    Extension.get_opt(resource, [:lua], :expose?, true)
  end

  defp default_name(resource) when is_atom(resource) do
    resource
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  defp default_name(dsl_state) do
    dsl_state
    |> Spark.Dsl.Extension.get_persisted(:module)
    |> default_name()
  end
end
