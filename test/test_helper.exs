# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Mnesia schema lives on-disk by default; for tests we want a fresh in-memory
# setup every run. `Ash.DataLayer.Mnesia.start/1` calls `:mnesia.create_schema/1`
# (which errors if a schema already exists), so stop + delete first.
:mnesia.stop()
:mnesia.delete_schema([node()])
Ash.DataLayer.Mnesia.start(AshLua.Test.Posts)

ExUnit.start()
