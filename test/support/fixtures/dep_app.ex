# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Test.DepApp do
  @moduledoc false

  # Simulates a domain declared by a dependency: it is listed in
  # `config :ash_lua, ash_domains: [...]` but its own `otp_app` is
  # `:ash_lua_dep`, which has no `ash_domains` config of its own.
  use Ash.Domain,
    otp_app: :ash_lua_dep,
    extensions: [AshLua.Domain]

  lua do
    namespace "dep" do
      action :widget_list, AshLua.Test.DepApp.Widget, :read
    end
  end

  resources do
    resource AshLua.Test.DepApp.Widget
  end
end
