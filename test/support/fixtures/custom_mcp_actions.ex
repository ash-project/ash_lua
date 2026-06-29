# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Test.Posts.CustomMCPActions do
  @moduledoc false
  use Ash.Resource,
    domain: AshLua.Test.Posts,
    extensions: [AshLua.EvalActions]

  eval_actions do
    eval_action_name :run
    docs_action_name :describe

    resource AshLua.Test.Posts.Post, actions: [:read]
  end
end
