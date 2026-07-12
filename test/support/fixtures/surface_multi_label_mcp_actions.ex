# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Test.Surface.MultiLabelMCPActions do
  @moduledoc false
  use Ash.Resource,
    domain: AshLua.Test.Surface,
    extensions: [AshLua.EvalActions]

  eval_actions do
    labels [:writes, :read_model]
  end
end
