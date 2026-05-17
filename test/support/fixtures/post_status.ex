# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Test.Posts.Post.Status do
  @moduledoc false
  use Ash.Type.Enum, values: [:draft, :published, :archived]
end
