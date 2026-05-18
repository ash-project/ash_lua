# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Encoder do
  @moduledoc """
  Conversions between Elixir/Ash values and the plain shapes that `:luerl` (via the `:lua` package)
  can encode as Lua tables.

  Lua doesn't have atoms or sigils — atoms are rendered as strings, `Decimal`/`Date`/`DateTime`/
  `NaiveDateTime`/`Time` as their canonical string forms, and structs as plain attribute maps
  (no relationships, no calculations, no aggregates unless they happen to be already loaded as a
  field value).
  """

  @doc """
  Decodes a Lua-side input value into the shape Ash actions expect for `params`/arguments.

  Luerl decodes Lua tables as a list of two-tuples — keyed by integers for sequences and by
  strings for maps. We normalize:

    * integer-keyed (sequence) tables → plain lists, sorted by index
    * string-keyed tables → maps with string keys (Ash accepts string-keyed params)
    * empty tables → empty maps (Ash actions are always invoked with a map of params)

  Recurses into values.
  """
  @spec decode_input(term()) :: term()
  def decode_input(value)

  def decode_input([]), do: %{}

  def decode_input(list) when is_list(list) do
    cond do
      integer_keyed?(list) ->
        list
        |> Enum.sort_by(fn {k, _v} -> k end)
        |> Enum.map(fn {_k, v} -> decode_input(v) end)

      keyword_pairs?(list) ->
        Map.new(list, fn {k, v} -> {stringify_key(k), decode_input(v)} end)

      true ->
        Enum.map(list, &decode_input/1)
    end
  end

  def decode_input(other), do: other

  defp integer_keyed?([{k, _} | _] = list) when is_integer(k) do
    Enum.all?(list, fn
      {k, _} -> is_integer(k)
      _ -> false
    end)
  end

  defp integer_keyed?(_), do: false

  defp keyword_pairs?([{_, _} | _] = list) do
    Enum.all?(list, &match?({_, _}, &1))
  end

  defp keyword_pairs?(_), do: false

  @doc """
  Encodes an Ash action result to a Lua-friendly value (plain Elixir maps/lists/primitives
  that `Lua.encode!/2` knows how to convert).
  """
  @spec encode_result(term()) :: term()
  def encode_result(value)

  def encode_result(nil), do: nil
  def encode_result(true), do: true
  def encode_result(false), do: false
  def encode_result(value) when is_binary(value), do: value
  def encode_result(value) when is_number(value), do: value
  def encode_result(value) when is_atom(value), do: Atom.to_string(value)

  def encode_result(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  def encode_result(%Date{} = d), do: Date.to_iso8601(d)
  def encode_result(%Time{} = t), do: Time.to_iso8601(t)
  def encode_result(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def encode_result(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)

  def encode_result(%Ash.Page.Offset{} = page) do
    %{
      "results" => encode_result(page.results),
      "count" => page.count,
      "limit" => page.limit,
      "offset" => page.offset,
      "more?" => page.more?
    }
  end

  def encode_result(%Ash.Page.Keyset{} = page) do
    %{
      "results" => encode_result(page.results),
      "count" => page.count,
      "limit" => page.limit,
      "before" => page.before,
      "after" => page.after,
      "more?" => page.more?
    }
  end

  # Luerl decodes Lua tables as keyword-list-of-2-tuples — integer-keyed for
  # sequences, string-keyed for maps. Flatten the same way `decode_input/1`
  # does on the input side, so a script's returned table comes through as a
  # plain list or map instead of a verbose nested `{type:"tuple", values:[...]}`
  # tree.
  def encode_result(value) when is_list(value) do
    cond do
      integer_keyed?(value) ->
        value
        |> Enum.sort_by(fn {k, _v} -> k end)
        |> Enum.map(fn {_k, v} -> encode_result(v) end)

      keyword_pairs?(value) ->
        Map.new(value, fn {k, v} -> {stringify_key(k), encode_result(v)} end)

      true ->
        Enum.map(value, &encode_result/1)
    end
  end

  # Luerl reference records — Lua functions / userdata / raw table refs that
  # decoding leaves in place because there's no Elixir equivalent. They reach
  # us when a script returns a table containing methods (e.g. `return loop.item`)
  # or returns a function directly (e.g. `return print`). Render them as an
  # opaque marker so the consumer knows the slot is non-data, instead of
  # crashing Jason downstream.
  def encode_result({:funref, _, _}), do: %{"opaque" => "function"}
  def encode_result({:erl_func, _}), do: %{"opaque" => "function"}
  def encode_result({:erl_mfa, _, _, _}), do: %{"opaque" => "function"}
  def encode_result({:tref, _}), do: %{"opaque" => "table_reference"}
  def encode_result({:usdref, _}), do: %{"opaque" => "userdata"}
  # Luerl also returns the decoded shape `{module, function, arity_or_undefined}`
  # for built-in callables like `print` (module=:luerl_lib_basic).
  def encode_result({m, f, a})
      when is_atom(m) and is_atom(f) and (is_integer(a) or is_atom(a)),
      do: %{"opaque" => "function"}

  # Any other Erlang tuple shouldn't normally appear in a Lua-decoded result,
  # but the eval action's `:term` slot can carry one when an Ash action
  # returns a tuple (e.g. a `:tuple`-typed attribute that bypassed the
  # template path). Wrap it as a self-describing map so Jason doesn't crash;
  # an unexpected wrap is also a useful signal that something leaked.
  def encode_result(value) when is_tuple(value) do
    %{
      "type" => "tuple",
      "values" => value |> Tuple.to_list() |> Enum.map(&encode_result/1)
    }
  end

  def encode_result(%_struct{} = record) do
    record
    |> Map.from_struct()
    |> Enum.reject(fn {k, _v} -> skip_struct_field?(k) end)
    |> Enum.into(%{}, fn {k, v} ->
      {Atom.to_string(k), encode_field(v)}
    end)
  end

  def encode_result(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {stringify_key(k), encode_result(v)} end)
  end

  def encode_result(value), do: value

  # Within a struct, an unloaded association comes back as
  # %Ash.NotLoaded{}; render those as nil rather than as Ash internals.
  defp encode_field(%Ash.NotLoaded{}), do: nil
  defp encode_field(%Ash.ForbiddenField{}), do: nil
  defp encode_field(other), do: encode_result(other)

  defp skip_struct_field?(:__meta__), do: true
  defp skip_struct_field?(:__order__), do: true
  defp skip_struct_field?(:__lateral_join_source__), do: true
  defp skip_struct_field?(:aggregates), do: true
  defp skip_struct_field?(:calculations), do: true
  defp skip_struct_field?(:__metadata__), do: true
  defp skip_struct_field?(_), do: false

  defp stringify_key(k) when is_atom(k), do: Atom.to_string(k)
  defp stringify_key(k) when is_binary(k), do: k
  defp stringify_key(k), do: to_string(k)

  @doc """
  Encodes a result against a template produced by `AshLua.Fields.for_action/4`.

  Walks the template recursively, pulling only the requested fields from records,
  typed maps, tuples, and union values. `:passthrough` template nodes fall back to
  the unconstrained `encode_result/1` path.
  """
  @spec encode_with_template(term(), term()) :: term()
  def encode_with_template(value, template)

  def encode_with_template(nil, _template), do: nil
  def encode_with_template(value, :passthrough), do: encode_result(value)

  def encode_with_template(%Ash.Page.Offset{} = page, {:array, sub}) do
    results = Enum.map(page.results, &encode_with_template(&1, sub))

    %{
      "results" => results,
      "count" => page.count,
      "limit" => page.limit,
      "offset" => page.offset,
      "more?" => page.more?
    }
  end

  def encode_with_template(%Ash.Page.Keyset{} = page, {:array, sub}) do
    results = Enum.map(page.results, &encode_with_template(&1, sub))

    %{
      "results" => results,
      "count" => page.count,
      "limit" => page.limit,
      "before" => page.before,
      "after" => page.after,
      "more?" => page.more?
    }
  end

  def encode_with_template(list, {:array, sub}) when is_list(list) do
    Enum.map(list, &encode_with_template(&1, sub))
  end

  def encode_with_template(record, {:resource, entries}) when is_map(record) do
    Map.new(entries, fn entry -> encode_resource_entry(record, entry) end)
  end

  def encode_with_template(value, {:typed_map, entries}) do
    normalized = normalize_typed_map(value)

    Map.new(entries, fn {:typed_map_field, name, sub} ->
      {Atom.to_string(name), encode_with_template(Map.get(normalized, name), sub)}
    end)
  end

  def encode_with_template(tuple, {:tuple, entries}) when is_tuple(tuple) do
    Map.new(entries, fn {:tuple_field, name, idx, sub} ->
      value = if idx < tuple_size(tuple), do: elem(tuple, idx), else: nil
      {Atom.to_string(name), encode_with_template(value, sub)}
    end)
  end

  def encode_with_template(%Ash.Union{type: member, value: inner}, {:union, entries}) do
    case Enum.find(entries, fn {:union_member, name, _} -> name == member end) do
      {:union_member, _, sub} ->
        %{"type" => Atom.to_string(member), "value" => encode_with_template(inner, sub)}

      nil ->
        %{"type" => Atom.to_string(member), "value" => encode_result(inner)}
    end
  end

  def encode_with_template(value, {:union, _entries}), do: encode_result(value)

  def encode_with_template(value, _template), do: encode_result(value)

  defp encode_resource_entry(record, {:attr, name, sub}) do
    {Atom.to_string(name), encode_with_template(Map.get(record, name), sub)}
  end

  defp encode_resource_entry(record, {:calc, name, sub}) do
    {Atom.to_string(name), encode_with_template(unwrap_loaded(Map.get(record, name)), sub)}
  end

  defp encode_resource_entry(record, {:agg, name}) do
    {Atom.to_string(name), encode_result(unwrap_loaded(Map.get(record, name)))}
  end

  defp encode_resource_entry(record, {:rel_one, name, sub}) do
    value = Map.get(record, name)

    encoded =
      case value do
        %Ash.NotLoaded{} -> nil
        %Ash.ForbiddenField{} -> nil
        nil -> nil
        record_or_struct -> encode_with_template(record_or_struct, sub)
      end

    {Atom.to_string(name), encoded}
  end

  defp encode_resource_entry(record, {:rel_many, name, sub}) do
    value = Map.get(record, name)

    encoded =
      case value do
        %Ash.NotLoaded{} -> []
        %Ash.ForbiddenField{} -> []
        list when is_list(list) -> Enum.map(list, &encode_with_template(&1, sub))
        _ -> []
      end

    {Atom.to_string(name), encoded}
  end

  defp unwrap_loaded(%Ash.NotLoaded{}), do: nil
  defp unwrap_loaded(%Ash.ForbiddenField{}), do: nil
  defp unwrap_loaded(value), do: value

  defp normalize_typed_map(nil), do: %{}
  defp normalize_typed_map(%_{} = struct), do: Map.from_struct(struct)
  defp normalize_typed_map(map) when is_map(map), do: map
  defp normalize_typed_map(list) when is_list(list), do: Map.new(list)
  defp normalize_typed_map(_), do: %{}

  @doc """
  Encodes an Ash error tree into a Lua-friendly table.

  Walks `Ash.Error.Invalid`/`Ash.Error.Forbidden` classes to their leaves, then dispatches each
  leaf through the `AshLua.Error` protocol. Leaves without a protocol impl render as an opaque
  "unknown error" entry with a uuid that's logged via `Logger.warning/1` so operators can
  correlate the surfaced uuid with full stacktrace details.

  The envelope carries a `class` tag (`"invalid" | "forbidden" | "framework" | "unknown"`)
  and the full per-error list in `errors`. Consumers that want a one-line summary should pick
  the appropriate entry from `errors` themselves rather than read a top-level message — joining
  or first-pick'ing here would silently mislead in the multi-error case.
  """
  @spec encode_error(term()) :: map()
  def encode_error(error) do
    %{
      "class" => error_class(error),
      "errors" => error |> unwrap_errors() |> Enum.map(&render_error/1)
    }
  end

  # Ash actions return errors already wrapped in an error class struct, so
  # we just read the wrapper. Bare `AshLua.Errors.FieldsError`s (from our
  # own field-selection layer) are always input-shape — classify as invalid.
  defp error_class(%Ash.Error.Invalid{}), do: "invalid"
  defp error_class(%Ash.Error.Forbidden{}), do: "forbidden"
  defp error_class(%Ash.Error.Framework{}), do: "framework"
  defp error_class(%Ash.Error.Unknown{}), do: "unknown"
  defp error_class(%AshLua.Errors.FieldsError{}), do: "invalid"
  defp error_class(_), do: "unknown"

  defp unwrap_errors([]), do: []

  defp unwrap_errors(errors) do
    errors
    |> List.wrap()
    |> Enum.flat_map(fn
      %class{errors: errors} when class in [Ash.Error.Invalid, Ash.Error.Forbidden] ->
        unwrap_errors(List.wrap(errors))

      other ->
        List.wrap(other)
    end)
  end

  defp render_error(error) do
    if AshLua.Error.impl_for(error) do
      error
      |> AshLua.Error.to_error()
      |> stringify_error_map()
    else
      log_unknown_error(error)
    end
  end

  defp stringify_error_map(%{} = err) do
    %{
      "message" => err.message,
      "short_message" => err.short_message,
      "code" => err.code,
      "fields" => err |> Map.get(:fields, []) |> Enum.map(&stringify_optional/1),
      "vars" => err |> Map.get(:vars, %{}) |> stringify_vars()
    }
  end

  defp stringify_vars(vars) when is_map(vars) do
    Map.new(vars, fn {k, v} -> {stringify_optional(k), stringify_var_value(v)} end)
  end

  defp stringify_vars(vars) when is_list(vars) do
    stringify_vars(Map.new(vars))
  end

  defp stringify_vars(_), do: %{}

  defp stringify_var_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp stringify_var_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_var_value(value) when is_list(value), do: Enum.map(value, &stringify_var_value/1)
  defp stringify_var_value(value) when is_map(value), do: stringify_vars(value)
  defp stringify_var_value(value), do: inspect(value)

  defp log_unknown_error(error) do
    uuid = Ash.UUID.generate()

    stacktrace =
      case error do
        %{stacktrace: %{stacktrace: v}} -> v
        _ -> nil
      end

    require Logger

    Logger.warning(
      "`#{uuid}`: AshLua.Error not implemented for error:\n\n#{Exception.format(:error, error, stacktrace)}"
    )

    %{
      "message" => "Something went wrong. Unique error id: `#{uuid}`",
      "short_message" => "unknown_error",
      "code" => "unknown_error",
      "fields" => [],
      "vars" => %{"uuid" => uuid}
    }
  end

  defp stringify_optional(nil), do: nil
  defp stringify_optional(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_optional(value) when is_binary(value), do: value
  defp stringify_optional(value), do: to_string(value)
end
