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

  def encode_result(value) when is_list(value) do
    Enum.map(value, &encode_result/1)
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
  Encodes an Ash error tree into a Lua-friendly table.

  Walks `Ash.Error.Invalid`/`Ash.Error.Forbidden` classes to their leaves, then dispatches each
  leaf through the `AshLua.Error` protocol. Leaves without a protocol impl render as an opaque
  "unknown error" entry with a uuid that's logged via `Logger.warning/1` so operators can
  correlate the surfaced uuid with full stacktrace details.
  """
  @spec encode_error(term()) :: map()
  def encode_error(error) do
    errors =
      error
      |> unwrap_errors()
      |> Enum.map(&render_error/1)

    %{
      "message" => top_message(errors),
      "errors" => errors
    }
  end

  defp top_message([]), do: "unknown error"
  defp top_message([%{"message" => msg} | _]), do: msg

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
