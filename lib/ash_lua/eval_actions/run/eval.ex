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

  alias AshLua.EvalActions.Info

  @impl true
  def run(input, _opts, context) do
    script = input.arguments.script
    resource = input.resource
    otp_app = Info.otp_app(resource)
    entrypoints = Info.action_entrypoints(resource)

    with {:ok, manifest} <-
           Ash.Info.Manifest.generate(otp_app: otp_app, action_entrypoints: entrypoints) do
      do_run(script, manifest, context)
    end
  end

  defp do_run(script, manifest, context) do
    eval_opts =
      [
        manifest: manifest,
        actor: context.actor,
        tenant: context.tenant,
        context: Map.get(context, :source_context, %{}) || %{}
      ]

    try do
      {values, _lua} = AshLua.eval!(script, eval_opts)
      {result, error} = split_lua_return(values)
      # Pass the script's return value through the encoder so any Luerl
      # reference records (function/userdata/table refs from e.g. `return
      # loop.item`) become opaque markers rather than crashing Jason in the
      # downstream MCP serializer.
      {:ok, %{result: AshLua.Encoder.encode_result(result), error: error}}
    rescue
      e in [Lua.CompilerException, Lua.RuntimeException] ->
        {:ok, %{result: nil, error: format_lua_error(e)}}
    end
  end

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
