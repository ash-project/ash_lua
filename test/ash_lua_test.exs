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
            title = "Hello", body = "World",
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
          local post, err = posts.post.create({ body = "no title" })
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
            title = "Assert works", body = "yes",
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
          assert(posts.post.create({ body = "no title" }))
          """,
          otp_app: :ash_lua
        )
      end
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

    test "update + destroy work via primary-key input" do
      {:ok, post} = Ash.create(Post, %{title: "Old"}, action: :create)

      {[updated], _lua} =
        AshLua.eval!(
          """
          local p = assert(posts.post.update({
            id = "#{post.id}", title = "Updated",
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
          local _, err = posts.post.destroy({ id = "#{post.id}" })
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
            id = "#{post.id}",
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
          local n = assert(posts.post.word_count({ text = "one two three four" }))
          return n
          """,
          otp_app: :ash_lua
        )

      assert count == 4
    end
  end
end
