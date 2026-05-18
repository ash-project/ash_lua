# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Fields do
  @moduledoc """
  Manifest-driven field selection for Lua-side queries.

  Translates a `fields` tree supplied by a Lua script into the three things Ash needs:

    * `select` — the list of attribute atoms to pass to `Ash.Query.select/2`
    * `load`   — the load statement to pass to `Ash.Query.load/2` (or `Ash.Changeset.load/2`)
    * `template` — an opaque structure the encoder walks to emit only the requested fields

  The Lua side accepts a list of strings and one-key maps:

      fields = {
        "id", "title",
        { author = { "id", "name" } },                          -- nested relationship
        { comments = { "id", "body" } },                        -- has_many
        { title_prefixed = { args = { prefix = "x: " } } },     -- calc with args
        { metadata = { "priority", "category" } },              -- typed map sub-selection
        { coordinates = { "latitude", "longitude" } },          -- typed tuple
        { content = { text = { "body" } } },                    -- union member sub-selection
      }

  Default (no `fields` provided) returns primary-key attributes only for resource records.
  For non-resource return types (typed map, tuple, primitive, etc.) the whole value is
  rendered.

  Type dispatch and template construction are driven entirely from
  `Ash.Info.Manifest.generate/1` IR — no `Ash.Resource.Info.*` traversal here.
  """

  alias Ash.Info.Manifest
  alias AshLua.Errors.FieldsError

  # Local constructor — builds the structured error at the throw site so the
  # rendering layer doesn't have to enumerate cases. The error flows through
  # `AshLua.Error` protocol like any Ash error.
  defp err(message, code, fields \\ [], vars \\ %{}) do
    %FieldsError{
      message: message,
      short_message: String.replace(code, "_", " "),
      code: code,
      fields: Enum.map(fields, &name_str/1),
      vars: vars
    }
  end

  defp name_str(name) when is_atom(name), do: Atom.to_string(name)
  defp name_str(name) when is_binary(name), do: name
  defp name_str(name) when is_integer(name), do: Integer.to_string(name)
  defp name_str(name), do: to_string(name)

  defp describe_kind(item) when is_binary(item), do: "a string"
  defp describe_kind(item) when is_atom(item), do: "an atom"
  defp describe_kind(item) when is_integer(item), do: "an integer"
  defp describe_kind(item) when is_float(item), do: "a number"
  defp describe_kind(item) when is_list(item), do: "a list"
  defp describe_kind(item) when is_map(item), do: "a table"
  defp describe_kind(item) when is_tuple(item), do: "a tuple"
  defp describe_kind(_), do: "an unknown value"

  @doc """
  Builds `{select, load, template}` for the given resource + action.

  `requested` is the already-decoded Lua input (the value of the `fields` key) — either
  `nil`/empty (defaults apply) or a list of items produced by `AshLua.Encoder.decode_input/1`.
  """
  @spec for_action(Manifest.t(), atom(), Manifest.Action.t(), term()) ::
          {:ok, {[atom()], term(), term()}} | {:error, term()}
  def for_action(%Manifest{} = manifest, resource, %Manifest.Action{} = action, requested) do
    lookup = Manifest.resource_lookup(manifest)
    type_lookup = Manifest.type_lookup(manifest)
    ctx = %{lookup: lookup, type_lookup: type_lookup}

    case parse(requested) do
      {:ok, ast} ->
        type = action_return_type(resource, action)

        try do
          {select, load, template} = select_for_type(type, ast, ctx)
          {:ok, {select, load, template}}
        catch
          {:error, _} = err -> err
        end

      err ->
        err
    end
  end

  @doc """
  Parses a Lua-decoded fields input into the internal AST.

  Returns `{:ok, :default}` when no fields were supplied, `{:ok, ast}` otherwise.
  """
  @spec parse(term()) :: {:ok, :default | list()} | {:error, term()}
  def parse(nil), do: {:ok, :default}
  def parse(:default), do: {:ok, :default}
  def parse([]), do: {:ok, :default}

  def parse(list) when is_list(list) do
    list
    |> Enum.reduce_while([], fn item, acc ->
      case parse_item(item) do
        {:ok, items} -> {:cont, acc ++ items}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:error, _} = err -> err
      ast -> {:ok, ast}
    end
  end

  def parse(_), do: {:error, err("`fields` must be a list", "invalid_fields")}

  defp parse_item(name) when is_binary(name) do
    case to_field_atom(name) do
      nil ->
        {:error, err("unknown field `#{name}`", "unknown_field", [name], %{"name" => name})}

      atom ->
        {:ok, [{:simple, atom}]}
    end
  end

  defp parse_item(name) when is_atom(name), do: {:ok, [{:simple, name}]}

  defp parse_item(%{} = map) do
    map
    |> Enum.reduce_while([], fn {key, value}, acc ->
      case parse_entry(key, value) do
        {:ok, node} -> {:cont, [node | acc]}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:error, _} = err -> err
      nodes -> {:ok, Enum.reverse(nodes)}
    end
  end

  defp parse_item(other) do
    kind = describe_kind(other)

    {:error,
     err(
       "invalid field item — must be a name or a one-key table, got #{kind}",
       "invalid_field_item",
       [],
       %{"kind" => kind}
     )}
  end

  defp parse_entry(key, value) do
    case to_field_atom(key) do
      nil ->
        s = name_str(key)
        {:error, err("unknown field `#{s}`", "unknown_field", [s], %{"name" => s})}

      name ->
        case parse_value(value) do
          {:with_args, args, sub} -> {:ok, {:with_args, name, args, sub}}
          {:nested, sub} -> {:ok, {:nested, name, sub}}
          {:error, _} = err -> err
        end
    end
  end

  defp parse_value([]), do: {:nested, :default}

  defp parse_value(list) when is_list(list) do
    case parse(list) do
      {:ok, ast} -> {:nested, ast}
      err -> err
    end
  end

  defp parse_value(%{} = map) when map_size(map) == 0 do
    {:nested, :default}
  end

  defp parse_value(%{} = map) do
    if Map.has_key?(map, "args") or Map.has_key?(map, "fields") do
      args = stringify_args(Map.get(map, "args", %{}))
      fields = Map.get(map, "fields", [])

      case parse(fields) do
        {:ok, ast} -> {:with_args, args, ast}
        err -> err
      end
    else
      # Map without args/fields keys → treat as nested with the map's entries
      # E.g. `{ content = { text = { "body" } } }` — union member dispatch
      # The map's keys become the sub-AST.
      case parse_item(map) do
        {:ok, nodes} -> {:nested, nodes}
        err -> err
      end
    end
  end

  defp parse_value(other) do
    kind = describe_kind(other)

    {:error,
     err(
       "invalid field value — must be a list, a one-key table, or `{ args = …, fields = … }`",
       "invalid_field_value",
       [],
       %{"kind" => kind}
     )}
  end

  defp stringify_args(map) when is_map(map), do: map
  defp stringify_args(list) when is_list(list), do: Map.new(list)
  defp stringify_args(_), do: %{}

  defp to_field_atom(name) when is_atom(name), do: name

  defp to_field_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp to_field_atom(_), do: nil

  defp action_return_type(resource, %Manifest.Action{type: type})
       when type in [:create, :update, :destroy] do
    %Manifest.Type{kind: :resource, resource_module: resource}
  end

  defp action_return_type(resource, %Manifest.Action{type: :read, get?: true}) do
    %Manifest.Type{kind: :resource, resource_module: resource}
  end

  defp action_return_type(resource, %Manifest.Action{type: :read}) do
    %Manifest.Type{
      kind: :array,
      item_type: %Manifest.Type{kind: :resource, resource_module: resource}
    }
  end

  defp action_return_type(_resource, %Manifest.Action{type: :action, returns: nil}) do
    %Manifest.Type{kind: :any}
  end

  defp action_return_type(_resource, %Manifest.Action{
         type: :action,
         returns: %Manifest.Type{} = t
       }),
       do: t

  defp select_for_type(%Manifest.Type{kind: :array, item_type: inner}, ast, ctx) do
    {select, load, template} = select_for_type(inner, ast, ctx)
    {select, load, {:array, template}}
  end

  defp select_for_type(%Manifest.Type{kind: kind, resource_module: mod}, ast, ctx)
       when kind in [:resource, :embedded_resource] and not is_nil(mod) do
    resource = Manifest.get_resource!(ctx.lookup, mod)
    select_for_resource(resource, ast, ctx)
  end

  defp select_for_type(%Manifest.Type{kind: :type_ref, module: mod}, ast, ctx) do
    resolved = Manifest.get_type!(ctx.type_lookup, mod)
    select_for_type(resolved, ast, ctx)
  end

  defp select_for_type(%Manifest.Type{kind: :union, members: members} = type, ast, ctx)
       when is_list(members) do
    select_for_union(type, ast, ctx)
  end

  defp select_for_type(%Manifest.Type{kind: :tuple, element_types: ets} = type, ast, ctx)
       when is_list(ets) do
    select_for_tuple(type, ast, ctx)
  end

  defp select_for_type(%Manifest.Type{kind: kind, fields: fields} = type, ast, ctx)
       when kind in [:map, :struct, :keyword] and is_list(fields) do
    select_for_typed_map(type, ast, ctx)
  end

  # Primitive — no sub-selection possible
  defp select_for_type(%Manifest.Type{}, :default, _ctx), do: {[], [], :passthrough}
  defp select_for_type(%Manifest.Type{}, [], _ctx), do: {[], [], :passthrough}

  defp select_for_type(%Manifest.Type{kind: kind}, _ast, _ctx) do
    k = name_str(kind)

    throw(
      {:error,
       err(
         "primitive type `#{k}` cannot have sub-fields",
         "invalid_field_selection",
         [],
         %{"kind" => k}
       )}
    )
  end

  defp select_for_resource(%Manifest.Resource{} = resource, :default, _ctx) do
    pk_template =
      resource.primary_key
      |> Enum.map(fn name -> {:attr, name, :passthrough} end)

    {resource.primary_key, [], {:resource, pk_template}}
  end

  defp select_for_resource(%Manifest.Resource{} = resource, ast, ctx) when is_list(ast) do
    {select, load, template} =
      Enum.reduce(ast, {[], [], []}, fn node, {sel, ld, tmpl} ->
        {sub_sel, sub_ld, entry} = select_resource_field(resource, node, ctx)
        {sel ++ sub_sel, ld ++ sub_ld, [entry | tmpl]}
      end)

    {Enum.uniq(select), load, {:resource, Enum.reverse(template)}}
  end

  defp select_resource_field(resource, {:simple, name}, ctx) do
    case classify_resource_field(resource, name) do
      {:attribute, field} ->
        {[name], [], {:attr, name, primitive_or_sub(field.type, :default, ctx)}}

      {:calculation, field} ->
        if has_required_args?(field) do
          s = name_str(name)

          throw(
            {:error,
             err(
               "calculation `#{s}` requires arguments — use `{ #{s} = { args = { … } } }`",
               "calculation_requires_args",
               [s],
               %{"name" => s}
             )}
          )
        else
          {[], [name], {:calc, name, primitive_or_sub(field.type, :default, ctx)}}
        end

      {:aggregate, _field} ->
        {[], [name], {:agg, name}}

      {:relationship, rel} ->
        # Default sub-selection: pk-only on destination
        dest_resource = Manifest.get_resource!(ctx.lookup, rel.destination)

        {_sel, sub_load, sub_template} =
          select_for_resource(dest_resource, :default, ctx)

        load_entry = if sub_load == [], do: rel.name, else: {rel.name, sub_load}
        kind = rel_kind(rel.cardinality)
        {[], [load_entry], {kind, rel.name, sub_template}}

      :unknown ->
        s = name_str(name)

        throw({:error, err("unknown field `#{s}`", "unknown_field", [s], %{"name" => s})})
    end
  end

  defp select_resource_field(resource, {:nested, name, sub_ast}, ctx) do
    case classify_resource_field(resource, name) do
      {:attribute, field} ->
        {sub_sel, sub_ld, sub_tmpl} = select_for_type(field.type, sub_ast, ctx)

        if sub_sel != [] or sub_ld != [] do
          s = name_str(name)

          throw(
            {:error,
             err(
               "cannot select or load fields under attribute `#{s}`",
               "cannot_select_under_attribute",
               [s],
               %{"name" => s}
             )}
          )
        end

        {[name], [], {:attr, name, sub_tmpl}}

      {:calculation, field} ->
        if has_required_args?(field) do
          s = name_str(name)

          throw(
            {:error,
             err(
               "calculation `#{s}` requires arguments — use `{ #{s} = { args = { … } } }`",
               "calculation_requires_args",
               [s],
               %{"name" => s}
             )}
          )
        end

        {sub_sel, sub_ld, sub_tmpl} = select_for_type(field.type, sub_ast, ctx)

        if sub_sel != [] or sub_ld != [] do
          s = name_str(name)

          throw(
            {:error,
             err(
               "cannot select or load fields under calculation `#{s}`",
               "cannot_select_under_calculation",
               [s],
               %{"name" => s}
             )}
          )
        end

        {[], [name], {:calc, name, sub_tmpl}}

      {:relationship, rel} ->
        dest_resource = Manifest.get_resource!(ctx.lookup, rel.destination)
        {_sel, sub_load, sub_tmpl} = select_for_resource(dest_resource, sub_ast, ctx)

        load_entry = if sub_load == [], do: rel.name, else: {rel.name, sub_load}
        kind = rel_kind(rel.cardinality)
        {[], [load_entry], {kind, rel.name, sub_tmpl}}

      {:aggregate, _field} ->
        s = name_str(name)

        throw(
          {:error,
           err(
             "cannot nest fields under aggregate `#{s}`",
             "cannot_nest_under_aggregate",
             [s],
             %{"name" => s}
           )}
        )

      :unknown ->
        s = name_str(name)

        throw({:error, err("unknown field `#{s}`", "unknown_field", [s], %{"name" => s})})
    end
  end

  defp select_resource_field(resource, {:with_args, name, args, sub_ast}, ctx) do
    case classify_resource_field(resource, name) do
      {:calculation, field} ->
        {sub_sel, sub_ld, sub_tmpl} = select_for_type(field.type, sub_ast, ctx)

        if sub_sel != [] or sub_ld != [] do
          s = name_str(name)

          throw(
            {:error,
             err(
               "cannot select or load fields under calculation `#{s}`",
               "cannot_select_under_calculation",
               [s],
               %{"name" => s}
             )}
          )
        end

        # Ash supports `{calc_name, %{arg => value}}` in load.
        load_entry = {name, atomize_arg_keys(args, field)}
        {[], [load_entry], {:calc, name, sub_tmpl}}

      _ ->
        s = name_str(name)

        throw(
          {:error,
           err(
             "`args` is only supported on calculations (field `#{s}`)",
             "args_only_supported_for_calculations",
             [s],
             %{"name" => s}
           )}
        )
    end
  end

  defp classify_resource_field(%Manifest.Resource{} = resource, name) do
    case Manifest.Resource.get_field(resource, name) do
      %Manifest.Field{kind: :attribute} = f ->
        {:attribute, f}

      %Manifest.Field{kind: :calculation} = f ->
        {:calculation, f}

      %Manifest.Field{kind: :aggregate} = f ->
        {:aggregate, f}

      nil ->
        case Manifest.Resource.get_relationship(resource, name) do
          %Manifest.Relationship{} = r -> {:relationship, r}
          nil -> :unknown
        end
    end
  end

  defp rel_kind(:one), do: :rel_one
  defp rel_kind(:many), do: :rel_many

  defp has_required_args?(%Manifest.Field{arguments: nil}), do: false

  defp has_required_args?(%Manifest.Field{arguments: args}) do
    Enum.any?(args, fn arg ->
      not arg.allow_nil? and not arg.has_default?
    end)
  end

  defp atomize_arg_keys(args, %Manifest.Field{arguments: defs}) when is_map(args) do
    name_set = MapSet.new(defs || [], & &1.name)

    Map.new(args, fn {k, v} ->
      atom = if is_atom(k), do: k, else: safe_atom!(k)

      unless MapSet.member?(name_set, atom) do
        s = name_str(atom)

        throw(
          {:error,
           err(
             "unknown argument `#{s}` for calculation",
             "unknown_calculation_arg",
             [s],
             %{"name" => s}
           )}
        )
      end

      {atom, v}
    end)
  end

  defp atomize_arg_keys(_, _), do: %{}

  defp safe_atom!(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError ->
      s = name_str(name)

      throw(
        {:error,
         err(
           "unknown argument `#{s}` for calculation",
           "unknown_calculation_arg",
           [s],
           %{"name" => s}
         )}
      )
  end

  defp primitive_or_sub(%Manifest.Type{} = type, ast, ctx) do
    {_sel, _ld, tmpl} = select_for_type(type, ast, ctx)
    tmpl
  end

  defp select_for_typed_map(%Manifest.Type{fields: fields}, :default, ctx) do
    entries =
      Enum.map(fields, fn %{name: name, type: type} ->
        {:typed_map_field, name, primitive_or_sub(type, :default, ctx)}
      end)

    {[], [], {:typed_map, entries}}
  end

  defp select_for_typed_map(%Manifest.Type{fields: fields} = type, ast, ctx) when is_list(ast) do
    entries =
      Enum.map(ast, fn node ->
        case node do
          {:simple, name} ->
            case find_field(fields, name) do
              nil ->
                s = name_str(name)

                throw(
                  {:error,
                   err(
                     "unknown field `#{s}` in typed map",
                     "unknown_typed_map_field",
                     [s],
                     %{"name" => s}
                   )}
                )

              %{type: t} ->
                {:typed_map_field, name, primitive_or_sub(t, :default, ctx)}
            end

          {:nested, name, sub_ast} ->
            case find_field(fields, name) do
              nil ->
                s = name_str(name)

                throw(
                  {:error,
                   err(
                     "unknown field `#{s}` in typed map",
                     "unknown_typed_map_field",
                     [s],
                     %{"name" => s}
                   )}
                )

              %{type: t} ->
                {:typed_map_field, name, primitive_or_sub(t, sub_ast, ctx)}
            end

          {:with_args, name, _, _} ->
            s = name_str(name)

            throw(
              {:error,
               err(
                 "`args` is not supported in typed map fields (field `#{s}`)",
                 "args_not_supported_in_typed_map",
                 [s],
                 %{"name" => s}
               )}
            )
        end
      end)

    _ = type
    {[], [], {:typed_map, entries}}
  end

  defp find_field(fields, name), do: Enum.find(fields, &(&1.name == name))

  defp select_for_tuple(%Manifest.Type{element_types: ets}, :default, ctx) do
    entries =
      ets
      |> Enum.with_index()
      |> Enum.map(fn {%{name: name, type: type}, idx} ->
        {:tuple_field, name, idx, primitive_or_sub(type, :default, ctx)}
      end)

    {[], [], {:tuple, entries}}
  end

  defp select_for_tuple(%Manifest.Type{element_types: ets}, ast, ctx) when is_list(ast) do
    indexed =
      ets
      |> Enum.with_index()
      |> Enum.map(fn {field, idx} -> Map.put(field, :index, idx) end)

    entries =
      Enum.map(ast, fn
        {:simple, name} ->
          case Enum.find(indexed, &(&1.name == name)) do
            nil ->
              s = name_str(name)

              throw(
                {:error,
                 err(
                   "unknown field `#{s}` in tuple",
                   "unknown_tuple_field",
                   [s],
                   %{"name" => s}
                 )}
              )

            %{type: t, index: idx} ->
              {:tuple_field, name, idx, primitive_or_sub(t, :default, ctx)}
          end

        {:nested, name, sub_ast} ->
          case Enum.find(indexed, &(&1.name == name)) do
            nil ->
              s = name_str(name)

              throw(
                {:error,
                 err(
                   "unknown field `#{s}` in tuple",
                   "unknown_tuple_field",
                   [s],
                   %{"name" => s}
                 )}
              )

            %{type: t, index: idx} ->
              {:tuple_field, name, idx, primitive_or_sub(t, sub_ast, ctx)}
          end

        {:with_args, name, _, _} ->
          s = name_str(name)

          throw(
            {:error,
             err(
               "`args` is not supported in tuple fields (field `#{s}`)",
               "args_not_supported_in_tuple",
               [s],
               %{"name" => s}
             )}
          )
      end)

    {[], [], {:tuple, entries}}
  end

  defp select_for_union(%Manifest.Type{members: members}, :default, ctx) do
    entries =
      Enum.map(members, fn %{name: name, type: type} ->
        {:union_member, name, primitive_or_sub(type, :default, ctx)}
      end)

    {[], [], {:union, entries}}
  end

  defp select_for_union(%Manifest.Type{members: members}, ast, ctx) when is_list(ast) do
    overrides =
      ast
      |> Enum.map(fn
        {:simple, _name} ->
          throw(
            {:error,
             err(
               "union members must be referenced as `{ member_name = { ... sub-fields ... } }`",
               "union_member_requires_sub_selection"
             )}
          )

        {:nested, name, sub_ast} ->
          {name, sub_ast}

        {:with_args, name, _, _} ->
          s = name_str(name)

          throw(
            {:error,
             err(
               "`args` is not supported in union members (member `#{s}`)",
               "args_not_supported_in_union",
               [s],
               %{"name" => s}
             )}
          )
      end)
      |> Map.new()

    entries =
      Enum.map(members, fn %{name: name, type: type} ->
        case Map.fetch(overrides, name) do
          {:ok, sub_ast} -> {:union_member, name, primitive_or_sub(type, sub_ast, ctx)}
          :error -> {:union_member, name, primitive_or_sub(type, :default, ctx)}
        end
      end)

    unknown_overrides =
      overrides
      |> Map.keys()
      |> Enum.reject(fn name -> Enum.any?(members, &(&1.name == name)) end)

    case unknown_overrides do
      [] ->
        :ok

      [name | _] ->
        s = name_str(name)

        throw(
          {:error,
           err(
             "unknown union member `#{s}`",
             "unknown_union_member",
             [s],
             %{"name" => s}
           )}
        )
    end

    {[], [], {:union, entries}}
  end
end
