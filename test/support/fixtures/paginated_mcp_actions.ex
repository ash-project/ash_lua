# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Test.Posts.PaginatedMCPActions do
  @moduledoc false
  use Ash.Resource,
    domain: AshLua.Test.Posts,
    extensions: [AshLua.EvalActions]

  eval_actions do
    require_pagination? true
    default_page_size 2
    resource AshLua.Test.Posts.Post, actions: [:read, :search]
  end
end
