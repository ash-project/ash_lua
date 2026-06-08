# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Test.Posts.Money do
  @moduledoc false
  # Integer-backed custom type that controls its own Lua encoding via the
  # `AshLua.Type.to_lua/2` callback.
  use Ash.Type.NewType, subtype_of: :integer
  use AshLua.Type

  @impl AshLua.Type
  def to_lua(cents, _constraints) when is_integer(cents) do
    %{"cents" => cents, "dollars" => cents / 100}
  end
end
