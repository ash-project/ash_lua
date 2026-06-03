# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Resource.Verifiers.VerifyNames do
  @moduledoc false

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @reserved_input_keys ~w(fields filter sort limit offset page operation)

  @impl true
  def verify(dsl) do
    resource = Verifier.get_persisted(dsl, :module)
    field_names = Verifier.get_option(dsl, [:lua], :field_names) || []
    argument_names = Verifier.get_option(dsl, [:lua], :argument_names) || []

    errors =
      []
      |> validate_field_names(resource, field_names)
      |> validate_argument_names(resource, argument_names, field_names)

    case Enum.reverse(errors) do
      [] -> :ok
      errors -> {:error, dsl_error(errors)}
    end
  end

  defp validate_field_names(errors, _resource, []), do: errors

  defp validate_field_names(errors, resource, mappings) do
    public_fields = public_field_names(resource)

    errors =
      Enum.reduce(mappings, errors, fn {internal, lua_name}, acc ->
        acc
        |> validate_known(:field, internal, public_fields, resource)
        |> validate_string(:field, internal, lua_name)
        |> validate_not_reserved(:field, internal, lua_name)
      end)

    lua_names =
      Enum.map(public_fields, fn field ->
        Keyword.get(mappings, field, Atom.to_string(field))
      end)

    validate_unique_names(errors, :field, lua_names, resource)
  end

  defp validate_argument_names(errors, _resource, [], _field_names), do: errors

  defp validate_argument_names(errors, resource, mappings, field_names) do
    Enum.reduce(mappings, errors, fn {action_name, action_mappings}, acc ->
      case Ash.Resource.Info.action(resource, action_name) do
        nil ->
          [
            "argument_names references missing action #{inspect(action_name)} on #{inspect(resource)}"
            | acc
          ]

        action ->
          validate_action_argument_names(
            acc,
            resource,
            action,
            List.wrap(action_mappings),
            field_names
          )
      end
    end)
  end

  defp validate_action_argument_names(errors, resource, action, mappings, field_names) do
    public_arguments =
      action
      |> Map.get(:arguments, [])
      |> Enum.filter(& &1.public?)
      |> Enum.map(& &1.name)

    errors =
      Enum.reduce(mappings, errors, fn {internal, lua_name}, acc ->
        acc
        |> validate_known({:argument, action.name}, internal, public_arguments, resource)
        |> validate_string({:argument, action.name}, internal, lua_name)
        |> validate_not_reserved({:argument, action.name}, internal, lua_name)
      end)

    argument_lua_names =
      Enum.map(public_arguments, fn argument ->
        Keyword.get(mappings, argument, Atom.to_string(argument))
      end)

    errors = validate_unique_names(errors, {:argument, action.name}, argument_lua_names, resource)

    if action.type == :action do
      errors
    else
      field_lua_names =
        resource
        |> action_field_inputs(action)
        |> Enum.map(fn field -> Keyword.get(field_names, field, Atom.to_string(field)) end)

      validate_unique_names(
        errors,
        {:action_input, action.name},
        argument_lua_names ++ field_lua_names,
        resource
      )
    end
  end

  defp action_field_inputs(resource, action) do
    fields = MapSet.new(public_field_names(resource))
    inputs = Ash.Resource.Info.action_inputs(resource, action.name)

    inputs
    |> Enum.filter(&MapSet.member?(fields, &1))
  end

  defp public_field_names(resource) do
    [
      Ash.Resource.Info.public_attributes(resource),
      Ash.Resource.Info.public_relationships(resource),
      Ash.Resource.Info.public_calculations(resource),
      Ash.Resource.Info.public_aggregates(resource)
    ]
    |> List.flatten()
    |> Enum.map(& &1.name)
  end

  defp validate_known(errors, kind, internal, known, resource) do
    if internal in known do
      errors
    else
      ["#{kind_label(kind)} #{inspect(internal)} does not exist on #{inspect(resource)}" | errors]
    end
  end

  defp validate_string(errors, kind, internal, lua_name) when is_binary(lua_name) do
    _ = kind
    _ = internal
    errors
  end

  defp validate_string(errors, kind, internal, lua_name) do
    [
      "#{kind_label(kind)} #{inspect(internal)} maps to #{inspect(lua_name)}, but Lua-facing names must be strings"
      | errors
    ]
  end

  defp validate_not_reserved(errors, kind, internal, lua_name) when is_binary(lua_name) do
    if lua_name in @reserved_input_keys do
      [
        "#{kind_label(kind)} #{inspect(internal)} maps to reserved Lua input key #{inspect(lua_name)}"
        | errors
      ]
    else
      errors
    end
  end

  defp validate_not_reserved(errors, _kind, _internal, _lua_name), do: errors

  defp validate_unique_names(errors, kind, lua_names, resource) do
    lua_names
    |> Enum.group_by(& &1)
    |> Enum.reduce(errors, fn
      {_name, [_one]}, acc ->
        acc

      {name, duplicates}, acc ->
        [
          "#{kind_label(kind)} names on #{inspect(resource)} collide on Lua-facing name #{inspect(name)} (#{length(duplicates)} entries)"
          | acc
        ]
    end)
  end

  defp kind_label(:field), do: "field"
  defp kind_label({:argument, action}), do: "argument for action #{inspect(action)}"
  defp kind_label({:action_input, action}), do: "input for action #{inspect(action)}"

  defp dsl_error(errors) do
    Spark.Error.DslError.exception(
      message: """
      Invalid AshLua resource naming configuration:

      #{Enum.map_join(errors, "\n", &("- " <> &1))}
      """
    )
  end
end
