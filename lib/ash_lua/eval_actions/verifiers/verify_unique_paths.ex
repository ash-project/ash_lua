# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.EvalActions.Verifiers.VerifyUniquePaths do
  @moduledoc false

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    dsl
    |> Verifier.get_entities([:eval_actions])
    |> List.wrap()
    |> Enum.map(& &1.resource)
    |> AshLua.DerivedPaths.collisions()
    |> case do
      [] ->
        :ok

      collisions ->
        {:error,
         Spark.Error.DslError.exception(
           module: Verifier.get_persisted(dsl, :module),
           path: [:eval_actions],
           message: """
           Exposed resources collide on their Lua path:

           #{Enum.map_join(AshLua.DerivedPaths.messages(collisions), "\n", &("- " <> &1))}
           """
         )}
    end
  end
end
