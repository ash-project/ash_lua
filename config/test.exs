# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

import Config

config :ash, policies: [show_policy_breakdowns?: true]

# AshLua.Test.DepApp simulates a dependency-declared domain: it is listed here
# but its own otp_app is :ash_lua_dep, which intentionally has no config.
config :ash_lua,
  ash_domains: [AshLua.Test.Posts, AshLua.Test.Surface, AshLua.Test.DepApp]
