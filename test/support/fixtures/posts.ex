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
  end
end
