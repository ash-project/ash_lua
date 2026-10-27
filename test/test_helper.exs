# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Mnesia schema lives on-disk by default; for tests we want a fresh in-memory
# setup every run. `Ash.DataLayer.Mnesia.start/1` calls `:mnesia.create_schema/1`
# (which errors if a schema already exists), so stop + delete first.
:mnesia.stop()
:mnesia.delete_schema([node()])
Ash.DataLayer.Mnesia.start(AshLua.Test.Posts)

# Fixture domains that need a surface of their own. Configured here rather than
# in config/test.exs, which warns about configuring apps that don't exist.
Application.put_env(:ash_lua_colliding_type_names, :ash_domains, [AshLua.Test.CollidingTypeNames])
Application.put_env(:ash_lua_actor_docs, :ash_domains, [AshLua.Test.ActorDocs])

ExUnit.start()
