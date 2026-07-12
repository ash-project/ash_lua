# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Domain.Namespace do
  @moduledoc """
  Internal struct backing one explicit Lua namespace declared in a domain.
  """

  @type t :: %__MODULE__{
          name: String.t() | [String.t()],
          labels: [atom()],
          actions: [AshLua.Domain.Action.t()],
          __spark_metadata__: term()
        }

  defstruct [:name, labels: [], actions: [], __spark_metadata__: nil]
end
