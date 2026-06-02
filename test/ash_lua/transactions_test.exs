# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.TransactionsTest do
  use ExUnit.Case, async: false

  alias AshLua.Test.Posts.MnesiaNote

  setup do
    # MnesiaNote is the only transactional fixture; other tests share state
    # so we wipe it between runs. Mnesia tables are named after the resource
    # module by default.
    :mnesia.clear_table(MnesiaNote)
    :ok
  end

  describe "utils.transaction" do
    test "commits — return value flows back as the first return value" do
      {[value, err], _lua} =
        AshLua.eval!(
          """
          return utils.transaction.transact({ "posts.mnesia_note" }, function()
            local n = assert(posts.mnesia_note.create({
              input = { body = "alpha" },
              fields = { "id", "body" }
            }))
            return n.body
          end)
          """,
          otp_app: :ash_lua
        )

      assert err == nil
      assert value == "alpha"
      assert {:ok, [%MnesiaNote{body: "alpha"}]} = Ash.read(MnesiaNote, action: :read)
    end

    test "rolls back when an inner `assert(...)` raises — no rows persisted" do
      {[value, err], _lua} =
        AshLua.eval!(
          """
          return utils.transaction.transact({ "posts.mnesia_note" }, function()
            assert(posts.mnesia_note.create({ input = { body = "first" } }))
            -- intentionally pass an empty body to trigger an action-level error
            assert(posts.mnesia_note.create({}))
            return "should not reach"
          end)
          """,
          otp_app: :ash_lua
        )

      assert value == nil
      assert is_list(err) or is_map(err)
      err_map = if is_list(err), do: Map.new(err), else: err
      assert err_map["class"] == "invalid"

      # Mnesia really rolled back — neither row is in the table.
      assert {:ok, []} = Ash.read(MnesiaNote, action: :read)
    end

    test "passing the body's `(nil, err)` through commits the surrounding work" do
      # The body's `(nil, err)` return is propagated as-is to the caller —
      # the script didn't `assert`, so the transaction commits with the
      # body's literal return values. This documents the behavior: only
      # raises (or Ash-side errors) roll back. Use `assert()` for
      # transactional semantics.
      {[value, err | _], _lua} =
        AshLua.eval!(
          """
          return utils.transaction.transact({ "posts.mnesia_note" }, function()
            assert(posts.mnesia_note.create({ input = { body = "first" } }))
            return posts.mnesia_note.create({}) -- returns (nil, err) instead of asserting
          end)
          """,
          otp_app: :ash_lua
        )

      assert value == nil
      # The err from the inner create propagated through as the body's
      # second return value.
      assert is_list(err) or is_map(err)
      # The earlier `assert(create({body = "first"}))` committed because the
      # script didn't trigger rollback.
      assert [%MnesiaNote{body: "first"}] = Ash.read!(MnesiaNote, action: :read)
    end

    test "unknown resource path surfaces a structured error" do
      {[value, err], _lua} =
        AshLua.eval!(
          """
          return utils.transaction.transact({ "posts.bogus" }, function()
            return "ok"
          end)
          """,
          otp_app: :ash_lua
        )

      assert value == nil
      err_map = Map.new(err)
      assert err_map["class"] == "invalid"
      first = err_map["errors"] |> List.first() |> elem(1) |> Map.new()
      assert first["code"] == "unknown_resource"
      assert first["message"] == "unknown resource `posts.bogus`"
    end

    test "non-list resources argument errors cleanly" do
      {[value, err], _lua} =
        AshLua.eval!(
          """
          return utils.transaction.transact("posts.mnesia_note", function() return 1 end)
          """,
          otp_app: :ash_lua
        )

      assert value == nil
      err_map = Map.new(err)
      first = err_map["errors"] |> List.first() |> elem(1) |> Map.new()
      assert first["code"] == "invalid_transaction_resources"
    end

    test "passing a resource whose data layer doesn't support transactions errors" do
      # `posts.post` is ETS-backed — no transaction support — so this should
      # be rejected before any work is done.
      {[value, err], _lua} =
        AshLua.eval!(
          """
          return utils.transaction.transact({ "posts.post" }, function() return 1 end)
          """,
          otp_app: :ash_lua
        )

      assert value == nil
      err_map = Map.new(err)
      first = err_map["errors"] |> List.first() |> elem(1) |> Map.new()
      assert first["code"] == "not_transactional"
      assert first["message"] == "record type `posts.post` does not support transactions"
    end

    test "utils.transaction.rollback aborts the transaction with a structured error" do
      {[value, err], _lua} =
        AshLua.eval!(
          """
          return utils.transaction.transact({ "posts.mnesia_note" }, function()
            assert(posts.mnesia_note.create({ input = { body = "will roll back" } }))
            utils.transaction.rollback("business rule failed")
            return "should not reach"
          end)
          """,
          otp_app: :ash_lua
        )

      assert value == nil
      err_map = Map.new(err)
      assert err_map["class"] == "invalid"
      first = err_map["errors"] |> List.first() |> elem(1) |> Map.new()
      assert first["code"] == "rolled_back"
      assert first["message"] == "business rule failed"
      # Mnesia really rolled back — the create that ran before rollback is gone.
      assert {:ok, []} = Ash.read(MnesiaNote, action: :read)
    end

    test "utils.transaction.rollback with no argument uses a default message" do
      {[_value, err], _lua} =
        AshLua.eval!(
          """
          return utils.transaction.transact({ "posts.mnesia_note" }, function()
            utils.transaction.rollback()
          end)
          """,
          otp_app: :ash_lua
        )

      err_map = Map.new(err)
      first = err_map["errors"] |> List.first() |> elem(1) |> Map.new()
      assert first["code"] == "rolled_back"
      assert first["message"] == "transaction rolled back"
    end

    test "a raw `error(table)` rolls back and surfaces the table as a leaf error" do
      {[value, err], _lua} =
        AshLua.eval!(
          ~S"""
          return utils.transaction.transact({ "posts.mnesia_note" }, function()
            assert(posts.mnesia_note.create({ input = { body = "before error" } }))
            error({ code = "custom_thing", message = "i raised this directly" })
          end)
          """,
          otp_app: :ash_lua
        )

      assert value == nil
      err_map = Map.new(err)
      assert err_map["class"] == "invalid"
      first = err_map["errors"] |> List.first() |> elem(1) |> Map.new()
      assert first["code"] == "custom_thing"
      assert first["message"] == "i raised this directly"

      # Transaction really rolled back.
      assert {:ok, []} = Ash.read(MnesiaNote, action: :read)
    end

    test "a raw `error(\"string\")` rolls back with the string as the leaf message" do
      {[value, err], _lua} =
        AshLua.eval!(
          ~S"""
          return utils.transaction.transact({ "posts.mnesia_note" }, function()
            assert(posts.mnesia_note.create({ input = { body = "before error" } }))
            error("boom")
          end)
          """,
          otp_app: :ash_lua
        )

      assert value == nil
      err_map = Map.new(err)
      first = err_map["errors"] |> List.first() |> elem(1) |> Map.new()
      assert first["code"] == "lua_error"
      assert first["message"] == "boom"
      assert {:ok, []} = Ash.read(MnesiaNote, action: :read)
    end

    test "closures: the function body can read outer Lua locals" do
      {[id, _], _lua} =
        AshLua.eval!(
          """
          local prefix = "from-outer-"
          return utils.transaction.transact({ "posts.mnesia_note" }, function()
            local n = assert(posts.mnesia_note.create({
              input = { body = prefix .. "scope" },
              fields = { "body" }
            }))
            return n.body
          end)
          """,
          otp_app: :ash_lua
        )

      assert id == "from-outer-scope"
    end
  end
end
