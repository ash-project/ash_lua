# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Domain.Info do
  @moduledoc "Introspection helpers for `AshLua.Domain`."

  alias AshLua.Domain.Namespace
  alias Spark.Dsl.Extension

  @doc """
  The Lua table name to expose this domain under.

  Falls back to snake_case of the domain module's last segment if not explicitly configured.
  """
  @spec name(Ash.Domain.t() | Spark.Dsl.t()) :: String.t()
  def name(domain) do
    case Extension.get_opt(domain, [:lua], :name, nil) do
      nil -> default_name(domain)
      name -> name
    end
  end

  @doc "Explicit public Lua namespaces configured on the domain."
  @spec namespaces(Ash.Domain.t() | Spark.Dsl.t()) :: [Namespace.t()]
  def namespaces(domain) do
    domain
    |> Extension.get_entities([:lua])
    |> List.wrap()
    |> Enum.filter(&match?(%Namespace{}, &1))
  end

  defp default_name(domain) when is_atom(domain) do
    domain
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
