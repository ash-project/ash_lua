# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.FieldNames do
  @moduledoc """
  Exact resource field name mappings for the Lua boundary.
  """

  @doc "Returns the Lua-facing name for an internal resource field."
  @spec to_lua_field_name(module(), atom() | String.t()) :: String.t()
  def to_lua_field_name(resource, field_name) do
    field_atom = field_atom(field_name)

    case field_atom && Keyword.get(field_names(resource), field_atom) do
      nil -> to_string(field_name)
      mapped -> mapped
    end
  end

  @doc "Returns the internal field atom for a Lua-facing field name when known."
  @spec to_internal_field_name(module(), atom() | String.t()) :: atom() | String.t()
  def to_internal_field_name(_resource, field_name) when is_atom(field_name), do: field_name

  def to_internal_field_name(resource, field_name) when is_binary(field_name) do
    case Map.fetch(reverse_field_names(resource), field_name) do
      {:ok, internal} -> internal
      :error -> field_atom(field_name) || field_name
    end
  end

  @doc "Returns the Lua-facing name for an internal action argument."
  @spec to_lua_argument_name(module(), atom(), atom() | String.t()) :: String.t()
  def to_lua_argument_name(resource, action_name, argument_name) do
    argument_atom = field_atom(argument_name)

    case argument_atom && Keyword.get(argument_names(resource, action_name), argument_atom) do
      nil -> to_string(argument_name)
      mapped -> mapped
    end
  end

  @doc "Returns the internal action argument atom for a Lua-facing argument name when known."
  @spec to_internal_argument_name(module(), atom(), atom() | String.t()) :: atom() | String.t()
  def to_internal_argument_name(_resource, _action_name, argument_name)
      when is_atom(argument_name),
      do: argument_name

  def to_internal_argument_name(resource, action_name, argument_name)
      when is_binary(argument_name) do
    case Map.fetch(reverse_argument_names(resource, action_name), argument_name) do
      {:ok, internal} -> internal
      :error -> field_atom(argument_name) || argument_name
    end
  end

  @doc "Returns the Lua-facing input name for an action field or argument."
  @spec to_lua_input_name(module(), atom(), atom(), atom() | String.t()) :: String.t()
  def to_lua_input_name(resource, action_name, action_type, input_name) do
    argument_name = to_lua_argument_name(resource, action_name, input_name)

    cond do
      argument_name != to_string(input_name) ->
        argument_name

      action_type in [:read, :create, :update, :destroy] ->
        to_lua_field_name(resource, input_name)

      true ->
        argument_name
    end
  end

  @doc "Rewrites resource action input keys from Lua names to internal Ash names."
  @spec to_internal_input(module(), map(), map()) :: map()
  def to_internal_input(resource, %{name: action_name, type: action_type}, input)
      when is_map(input) do
    Map.new(input, fn
      {key, value} when key in ["filter", :filter] ->
        {key, to_internal_filter(resource, value)}

      {key, value} when key in ["sort", :sort] ->
        {key, to_internal_sort(resource, value)}

      {key, value} ->
        {to_internal_input_key(resource, action_name, action_type, key), value}
    end)
  end

  def to_internal_input(_resource, _action, input), do: input

  @doc "Rewrites encoded Ash error fields to Lua-facing input names."
  @spec to_lua_error(map(), module(), map()) :: map()
  def to_lua_error(error_map, resource, %{name: action_name, type: action_type})
      when is_map(error_map) do
    Map.update(error_map, "errors", [], fn errors ->
      Enum.map(errors, &to_lua_error_leaf(&1, resource, action_name, action_type))
    end)
  end

  def to_lua_error(error_map, _resource, _action), do: error_map

  defp to_internal_input_key(_resource, _action_name, _action_type, key)
       when key in [
              "fields",
              :fields,
              "filter",
              :filter,
              "sort",
              :sort,
              "limit",
              :limit,
              "offset",
              :offset,
              "page",
              :page,
              "operation",
              :operation
            ],
       do: key

  defp to_internal_input_key(resource, action_name, action_type, key) do
    argument_name = to_internal_argument_name(resource, action_name, key)

    cond do
      argument_name != key and argument_name != to_string(key) ->
        Atom.to_string(argument_name)

      action_type in [:read, :create, :update, :destroy] ->
        to_internal_field_key(resource, key)

      true ->
        key
    end
  end

  defp to_lua_error_leaf(leaf, resource, action_name, action_type) when is_map(leaf) do
    Map.update(leaf, "fields", [], fn fields ->
      fields
      |> List.wrap()
      |> Enum.map(&to_lua_input_name(resource, action_name, action_type, &1))
    end)
  end

  defp to_lua_error_leaf(leaf, _resource, _action_name, _action_type), do: leaf

  @doc "Rewrites field names in an Ash filter input tree."
  @spec to_internal_filter(module(), term()) :: term()
  def to_internal_filter(resource, filter) when is_map(filter) do
    Map.new(filter, fn {key, value} ->
      case key_string(key) do
        "and" ->
          {key, map_filter_list(resource, value)}

        "or" ->
          {key, map_filter_list(resource, value)}

        "not" ->
          {key, to_internal_filter(resource, value)}

        _ ->
          {to_internal_field_key(resource, key), filter_value(value)}
      end
    end)
  end

  def to_internal_filter(resource, filters) when is_list(filters) do
    Enum.map(filters, &to_internal_filter(resource, &1))
  end

  def to_internal_filter(_resource, filter), do: filter

  @doc "Rewrites field names in a sort input."
  @spec to_internal_sort(module(), term()) :: term()
  def to_internal_sort(resource, sort) when is_binary(sort) do
    {prefix, name} =
      case sort do
        "-" <> rest -> {"-", rest}
        other -> {"", other}
      end

    prefix <> to_internal_field_string(resource, name)
  end

  def to_internal_sort(resource, sort) when is_atom(sort) do
    sort
    |> Atom.to_string()
    |> then(&to_internal_sort(resource, &1))
  end

  def to_internal_sort(resource, sort) when is_list(sort) do
    Enum.map(sort, &to_internal_sort(resource, &1))
  end

  def to_internal_sort(_resource, sort), do: sort

  @doc ~S(Rewrites field names in read operation descriptors like `{ "sum", "total" }`.)
  @spec to_internal_operation(module(), term()) :: term()
  def to_internal_operation(resource, [op, field]) when is_binary(field) or is_atom(field) do
    [op, to_internal_field_string(resource, field)]
  end

  def to_internal_operation(_resource, operation), do: operation

  @doc "Returns the internal field name as a string for Ash string-keyed inputs."
  @spec to_internal_field_string(module(), atom() | String.t()) :: String.t()
  def to_internal_field_string(resource, field_name) do
    resource
    |> to_internal_field_name(field_name)
    |> to_string()
  end

  defp to_internal_field_key(resource, field_name) do
    resource
    |> to_internal_field_name(field_name)
    |> to_string()
  end

  defp field_names(resource) do
    AshLua.Resource.Info.field_names(resource)
  end

  defp argument_names(resource, action_name) do
    resource
    |> AshLua.Resource.Info.argument_names()
    |> Keyword.get(action_name, [])
  end

  defp reverse_field_names(resource) do
    Map.new(field_names(resource), fn {internal, external} ->
      {external, internal}
    end)
  end

  defp reverse_argument_names(resource, action_name) do
    Map.new(argument_names(resource, action_name), fn {internal, external} ->
      {external, internal}
    end)
  end

  defp field_atom(name) when is_atom(name), do: name

  defp field_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp field_atom(_name), do: nil

  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key) when is_binary(key), do: key
  defp key_string(key), do: to_string(key)

  defp map_filter_list(resource, filters) when is_list(filters) do
    Enum.map(filters, &to_internal_filter(resource, &1))
  end

  defp map_filter_list(resource, filter), do: to_internal_filter(resource, filter)

  defp filter_value(value) when is_map(value), do: value
  defp filter_value(value) when is_list(value), do: Enum.map(value, &filter_value/1)
  defp filter_value(value), do: value
end
