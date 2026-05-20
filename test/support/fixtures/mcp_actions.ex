# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Test.Posts.MCPActions do
  @moduledoc false
  use Ash.Resource,
    domain: AshLua.Test.Posts,
    extensions: [AshLua.EvalActions]

  eval_actions do
    resource AshLua.Test.Posts.Post, actions: [:read, :create]
    resource AshLua.Test.Posts.Comment, actions: [:read]
    resource AshLua.Test.Posts.MnesiaNote, actions: [:read, :create]
  end
end
