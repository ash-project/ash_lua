# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.EvalActions.Run.Eval do
  @moduledoc """
  Implementation backing the synthesized `:eval` action.

  Evaluates the script through `AshLua.eval!/2` against a manifest scoped to
  the `eval_actions` configuration, with the caller's actor / tenant / context
  threaded through.

  The action returns a typed map `%{result, error}` mirroring the in-script
  `(result, err)` convention — successful runs populate `result`; failed runs
  populate `error`.
  """

  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context) do
    script = input.arguments.script
    resource = input.resource

    with {:ok, manifest} <- AshLua.Surface.for_eval_resource(resource) do
      do_run(script, manifest, AshLua.EvalActions.Info.forbidden_fields(resource), context)
    end
  end

  defp do_run(script, manifest, forbidden_fields, context) do
    eval_opts =
      [
        manifest: manifest,
        actor: context.actor,
        tenant: context.tenant,
        context: Map.get(context, :source_context, %{}) || %{},
        forbidden_fields: forbidden_fields
      ]

    try do
      {values, lua} = AshLua.eval!(script, eval_opts)
      {result, error} = split_lua_return(values)
      # Pass the script's return value through the encoder so any Luerl
      # reference records (function/userdata/table refs from e.g. `return
      # loop.item`) become opaque markers rather than crashing Jason in the
      # downstream MCP serializer.
      {:ok,
       %{
         result: AshLua.Encoder.encode_result(result),
         error: error,
         print_output: AshLua.Runtime.print_output(lua)
       }}
    rescue
      e in [Lua.CompilerException, Lua.RuntimeException] ->
        # On Lua-side raise we lost the post-call state, so we can't surface
        # the prints from this particular run. Future improvement: thread
        # `lua` out via the exception so partial print output survives.
        {:ok,
         %{
           result: nil,
           error: extract_structured_error(e) || format_lua_error(e),
           print_output: []
         }}
    end
  end

  # When a Lua script does `assert(action_call())` and `action_call()` returns
  # `(nil, err_table)`, Lua raises with the err_table as the error object. The
  # default `Lua.RuntimeException` message is the opaque "error object is a
  # table!" — useless for diagnosing `invalid_fields` / `not_found` / etc.
  # Detect that case and decode the original error table back out so the
  # action's `error` slot carries the same structured shape the script would
  # have seen on the unwrapped path.
  defp extract_structured_error(%Lua.RuntimeException{original: original, state: state}) do
    case {raised_value(original), lua_state(original, state)} do
      {nil, _state} -> nil
      {_value, nil} -> nil
      {value, lua_state} -> value |> safe_decode(lua_state) |> normalize_error_table()
    end
  end

  defp extract_structured_error(_), do: nil

  # Pull the actual raised Lua value out of the VM error shape. Older Luerl
  # paths raise `{:assert_error, err}` / `{:error_call, [err]}`; the native VM
  # raises error structs with the Lua value in `:value`.
  defp raised_value({:assert_error, value}), do: value
  defp raised_value({:error_call, [value | _]}), do: value
  defp raised_value(error) when is_struct(error), do: Map.get(error, :value)
  defp raised_value(_), do: nil

  defp lua_state(original, nil) when is_struct(original), do: Map.get(original, :state)
  defp lua_state(_original, state), do: state

  defp safe_decode(value, state) do
    Lua.decode!(%Lua{state: state}, value)
  rescue
    _ -> nil
  end

  defp normalize_error_table(list) when is_list(list) do
    case AshLua.Encoder.decode_input(list) do
      %{"class" => _, "errors" => _} = err -> err
      _ -> nil
    end
  end

  defp normalize_error_table(_), do: nil

  defp split_lua_return([]), do: {nil, nil}
  defp split_lua_return([value]), do: {value, nil}
  defp split_lua_return([value, nil | _]), do: {value, nil}
  defp split_lua_return([nil, err | _]), do: {nil, normalize_error(err)}
  defp split_lua_return([value, err | _]), do: {value, normalize_error(err)}

  defp normalize_error(err) when is_list(err), do: Map.new(err)
  defp normalize_error(err) when is_map(err), do: err
  defp normalize_error(err), do: %{"message" => inspect(err)}

  defp format_lua_error(e) do
    %{
      "message" => Exception.message(e),
      "errors" => [
        %{
          "message" => Exception.message(e),
          "short_message" => "lua_error",
          "code" => "lua_error",
          "fields" => [],
          "vars" => %{}
        }
      ]
    }
  end
end
