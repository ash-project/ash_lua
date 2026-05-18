# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.EvalActions.Expose do
  @moduledoc """
  Internal struct backing one `resource Mod, actions: [...]` entry inside an
  `eval_actions do ... end` block.
  """

  @type t :: %__MODULE__{
          resource: module(),
          actions: [atom()] | :all,
          __spark_metadata__: term()
        }

  defstruct [:resource, :actions, __spark_metadata__: nil]
end
