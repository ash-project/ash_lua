# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Test.Posts do
  @moduledoc false
  use Ash.Domain,
    otp_app: :ash_lua,
    extensions: [AshLua.Domain]

  resources do
    resource AshLua.Test.Posts.Post
    resource AshLua.Test.Posts.User
    resource AshLua.Test.Posts.Comment
    resource AshLua.Test.Posts.MCPActions
    resource AshLua.Test.Posts.CustomMCPActions
    resource AshLua.Test.Posts.MnesiaNote
    resource AshLua.Test.Posts.SecretPost
    resource AshLua.Test.Posts.ForbiddenDisplayMCPActions
  end
end
