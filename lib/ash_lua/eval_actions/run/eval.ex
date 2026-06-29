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
    resource = input.resource
    script = Map.get(input.arguments, :script)
    source_context = Map.get(context, :source_context)

    if is_binary(script) do
      AshLua.Eval.run(script,
        eval_resource: resource,
        actor: context.actor,
        tenant: context.tenant,
        context: if(is_map(source_context), do: source_context, else: %{}),
        forbidden_fields: AshLua.EvalActions.Info.forbidden_fields(resource)
      )
    else
      {:error,
       Ash.Error.Action.InvalidArgument.exception(
         field: :script,
         message: "must be a string"
       )}
    end
  end
end
