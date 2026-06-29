# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Test.Posts.ForbiddenDisplayMCPActions do
  @moduledoc false
  use Ash.Resource,
    domain: AshLua.Test.Posts,
    extensions: [AshLua.EvalActions]

  eval_actions do
    forbidden_fields :display
    resource AshLua.Test.Posts.SecretPost, actions: [:read]
  end
end
