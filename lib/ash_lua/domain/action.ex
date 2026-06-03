# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Domain.Action do
  @moduledoc """
  Internal struct backing one explicit Lua surface action declared in a domain.
  """

  @type t :: %__MODULE__{
          name: atom(),
          resource: module(),
          action: atom(),
          __spark_metadata__: term()
        }

  defstruct [:name, :resource, :action, __spark_metadata__: nil]
end
