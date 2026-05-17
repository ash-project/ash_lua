# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

import Config

config :ash, policies: [show_policy_breakdowns?: true]

config :ash_lua,
  ash_domains: [AshLua.Test.Posts]
