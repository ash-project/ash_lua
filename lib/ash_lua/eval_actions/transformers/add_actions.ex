# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.EvalActions.Transformers.AddActions do
  @moduledoc false

  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias AshLua.EvalActions.Info

  def transform(dsl_state) do
    eval_name = Info.eval_action_name(dsl_state)
    docs_name = Info.docs_action_name(dsl_state)

    with {:ok, dsl_state} <- add_eval_action(dsl_state, eval_name) do
      add_docs_action(dsl_state, docs_name)
    end
  end

  def after?(_), do: true

  defp add_eval_action(dsl_state, name) do
    with {:ok, script_arg} <- Builder.build_action_argument(:script, :string, allow_nil?: false) do
      Builder.add_new_action(dsl_state, :action, name,
        returns: :map,
        constraints: [
          fields: [
            result: [type: :term, allow_nil?: true],
            error: [type: :map, allow_nil?: true],
            print_output: [type: {:array, :string}, allow_nil?: true]
          ]
        ],
        arguments: [script_arg],
        run: AshLua.EvalActions.Run.Eval
      )
    end
  end

  defp add_docs_action(dsl_state, name) do
    with {:ok, name_arg} <- Builder.build_action_argument(:name, :string, allow_nil?: true),
         {:ok, search_arg} <- Builder.build_action_argument(:search, :string, allow_nil?: true) do
      Builder.add_new_action(dsl_state, :action, name,
        returns: :string,
        arguments: [name_arg, search_arg],
        run: AshLua.EvalActions.Run.Docs
      )
    end
  end
end
