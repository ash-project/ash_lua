# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Test.Posts.Slug do
  @moduledoc false
  use Ash.Type.NewType, subtype_of: :string, constraints: [min_length: 1, max_length: 100]
end
