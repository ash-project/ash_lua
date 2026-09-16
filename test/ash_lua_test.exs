# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLuaTest do
  use ExUnit.Case, async: false

  alias AshLua.Test.Posts.Post

  describe "create" do
    test "exposes a create action and returns the created record as a table" do
      {[id], _lua} =
        AshLua.eval!(
          """
          local post, err = posts.post.create({
            input = { title = "Hello", body = "World" },
            fields = { "id" }
          })
          assert(err == nil)
          return post.id
          """,
          otp_app: :ash_lua
        )

      assert is_binary(id)
      assert {:ok, %Post{title: "Hello"}} = Ash.get(Post, id)
    end

    test "returns (nil, error_table) on failure with AshLua.Error protocol shape" do
      {[nil, err], _lua} =
        AshLua.eval!(
          """
          local post, err = posts.post.create({ input = { body = "no title" } })
          return post, err
          """,
          otp_app: :ash_lua
        )

      err_map = Map.new(err)
      assert err_map["class"] == "invalid"
      refute Map.has_key?(err_map, "message")

      [first | _] = Enum.map(err_map["errors"], &Map.new(elem(&1, 1)))

      assert first["code"] == "required"
      assert first["short_message"] == "is required"
      assert Lua.Table.as_list(first["fields"]) == ["title"]
      assert is_list(first["vars"]) or is_map(first["vars"])
    end

    test "assert() unwraps successful results and raises on errors" do
      {[title], _lua} =
        AshLua.eval!(
          """
          local post = assert(posts.post.create({
            input = { title = "Assert works", body = "yes" },
            fields = { "title" }
          }))
          return post.title
          """,
          otp_app: :ash_lua
        )

      assert title == "Assert works"

      assert_raise Lua.RuntimeException, fn ->
        AshLua.eval!(
          """
          assert(posts.post.create({ input = { body = "no title" } }))
          """,
          otp_app: :ash_lua
        )
      end
    end

    test "forwards source names into Lua runtime errors" do
      error =
        assert_raise Lua.RuntimeException, fn ->
          AshLua.eval!(
            """
            local f = nil
            return f()
            """,
            otp_app: :ash_lua,
            source: "agent_script.lua"
          )
        end

      assert error.source == "agent_script.lua"
      assert error.line == 2
      assert Exception.message(error) =~ "agent_script.lua:2"
    end
  end

  describe "read / update / destroy / generic action" do
    test "read returns a list of records as Lua tables" do
      {:ok, _} = Ash.create(Post, %{title: "Read me", body: "..."}, action: :create)

      {[results], _lua} =
        AshLua.eval!(
          """
          local r = assert(posts.post.read({ fields = { "title" } }))
          return r
          """,
          otp_app: :ash_lua
        )

      records = Lua.Table.deep_cast(results)
      assert is_list(records)
      assert "Read me" in Enum.map(records, & &1["title"])
    end

    test "read accepts filter / sort / limit / offset from Lua" do
      for title <- ~w(Apple Banana Cherry) do
        {:ok, _} = Ash.create(Post, %{title: title, published: true}, action: :create)
      end

      {:ok, _} = Ash.create(Post, %{title: "Draft", published: false}, action: :create)

      {[results], _lua} =
        AshLua.eval!(
          """
          local r = assert(posts.post.read({
            filter = { published = true },
            sort   = "title",
            limit  = 2,
            offset = 1,
            fields = { "title" }
          }))
          return r
          """,
          otp_app: :ash_lua
        )

      titles =
        results
        |> Lua.Table.deep_cast()
        |> Enum.map(& &1["title"])

      assert titles == ["Banana", "Cherry"]
    end

    test "an action argument named `limit` reaches the action instead of the query" do
      for title <- ~w(ab abcd abcdef) do
        {:ok, _} = Ash.create(Post, %{title: title}, action: :create)
      end

      {[titles, control], _lua} =
        AshLua.eval!(
          """
          local short = assert(posts.post.search({
            input = { limit = 4 },
            sort = "title",
            fields = { "title" }
          }))

          local one = assert(posts.post.search({ limit = 1, fields = { "title" } }))

          local titles = {}
          for i, post in ipairs(short) do titles[i] = post.title end
          return titles, #one
          """,
          otp_app: :ash_lua
        )

      assert Lua.Table.as_list(titles) == ["ab", "abcd"]
      assert control == 1
    end

    test "`input.limit` and the `limit` control apply independently" do
      for title <- ~w(ab abcd abcdef) do
        {:ok, _} = Ash.create(Post, %{title: title}, action: :create)
      end

      {[titles], _lua} =
        AshLua.eval!(
          """
          local r = assert(posts.post.search({
            input = { limit = 4 },
            limit = 1,
            sort = "-title",
            fields = { "title" }
          }))

          local titles = {}
          for i, post in ipairs(r) do titles[i] = post.title end
          return titles
          """,
          otp_app: :ash_lua
        )

      assert Lua.Table.as_list(titles) == ["abcd"]
    end

    test "an invalid `input.limit` argument renders as invalid_argument" do
      {[nil, err], _lua} =
        AshLua.eval!(
          """
          local r, err = posts.post.search({ input = { limit = 2^63 } })
          return r, err
          """,
          otp_app: :ash_lua
        )

      [first] = error_leaves(err)
      assert first["code"] == "invalid_argument"
      assert first["fields"] == ["limit"]
    end

    test "invalid `limit` / `offset` / `page` controls render as errors" do
      {[limit_err, offset_err, page_err], _lua} =
        AshLua.eval!(
          """
          local _, limit_err = posts.post.read({ limit = "x" })
          local _, offset_err = posts.post.read({ offset = "x" })
          local _, page_err = posts.post.read({ page = { limit = "x" } })
          return limit_err, offset_err, page_err
          """,
          otp_app: :ash_lua
        )

      [limit] = error_leaves(limit_err)
      assert limit["code"] == "invalid_limit"
      assert limit["short_message"] == "invalid limit"
      assert limit["fields"] == ["limit"]
      assert Map.new(limit["vars"])["value"] == ~s("x")

      [offset] = error_leaves(offset_err)
      assert offset["code"] == "invalid_offset"
      assert offset["fields"] == ["offset"]

      [page] = error_leaves(page_err)
      assert page["code"] == "invalid_page"
      assert page["fields"] == ["page"]
    end

    test "update + destroy work via primary-key input" do
      {:ok, post} = Ash.create(Post, %{title: "Old"}, action: :create)

      {[updated], _lua} =
        AshLua.eval!(
          """
          local p = assert(posts.post.update({
            input = { id = "#{post.id}", title = "Updated" },
            fields = { "title" }
          }))
          return p.title
          """,
          otp_app: :ash_lua
        )

      assert updated == "Updated"

      {[true_value], _lua} =
        AshLua.eval!(
          """
          local _, err = posts.post.destroy({ input = { id = "#{post.id}" } })
          return err == nil
          """,
          otp_app: :ash_lua
        )

      assert true_value == true
      assert {:error, _} = Ash.get(Post, post.id)
    end

    test "publish (update with no input) flips :published" do
      {:ok, post} = Ash.create(Post, %{title: "Draft"}, action: :create)

      {[published], _lua} =
        AshLua.eval!(
          """
          local p = assert(posts.post.publish({
            input = { id = "#{post.id}" },
            fields = { "published" }
          }))
          return p.published
          """,
          otp_app: :ash_lua
        )

      assert published == true
    end

    test "generic action returns its result" do
      {[count], _lua} =
        AshLua.eval!(
          """
          local n = assert(posts.post.word_count({
            input = { text = "one two three four" }
          }))
          return n
          """,
          otp_app: :ash_lua
        )

      assert count == 4
    end
  end

  defp error_leaves(err) do
    err
    |> Map.new()
    |> Map.fetch!("errors")
    |> Enum.map(fn {_i, leaf} ->
      leaf
      |> Map.new()
      |> Map.update("fields", [], &Lua.Table.as_list/1)
    end)
  end
end
