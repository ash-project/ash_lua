# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.FieldsTest do
  use ExUnit.Case, async: false

  alias AshLua.Test.Posts.Comment
  alias AshLua.Test.Posts.Post
  alias AshLua.Test.Posts.User

  defp deep(value), do: Lua.Table.deep_cast(value)
  defp first_record(lua_table), do: lua_table |> deep() |> List.first()

  defp run!(script) do
    {[result], _lua} = AshLua.eval!(script, otp_app: :ash_lua)
    result
  end

  describe "Tier 1 — defaults and basic resource fields" do
    test "default (no fields key) returns only primary key" do
      {:ok, _} = Ash.create(Post, %{title: "PK only"}, action: :create)

      result =
        run!("""
        local r = assert(posts.post.read({}))
        return r
        """)

      record = first_record(result)
      assert is_binary(record["id"])
      assert Map.keys(record) == ["id"]
    end

    test "selecting specific attributes returns only those + omits the rest" do
      {:ok, _} = Ash.create(Post, %{title: "Hello", body: "World"}, action: :create)

      result =
        run!("""
        local r = assert(posts.post.read({ fields = { "title", "body" } }))
        return r
        """)

      record = first_record(result)
      assert Map.keys(record) |> Enum.sort() == ["body", "title"]
      assert record["title"] == "Hello"
      assert record["body"] == "World"
    end

    test "loading a calculation without args" do
      {:ok, _} = Ash.create(Post, %{title: "Hello"}, action: :create)

      result =
        run!("""
        local r = assert(posts.post.read({ fields = { "title", "title_downcase" } }))
        return r
        """)

      record = first_record(result)
      assert record["title"] == "Hello"
      assert record["title_downcase"] == "hello"
    end

    test "loading an aggregate" do
      {:ok, post} = Ash.create(Post, %{title: "Post"}, action: :create)
      {:ok, _} = Ash.create(Comment, %{body: "c1", post_id: post.id}, action: :create)
      {:ok, _} = Ash.create(Comment, %{body: "c2", post_id: post.id}, action: :create)

      result =
        run!("""
        local r = assert(posts.post.read({ fields = { "title", "comment_count" } }))
        return r
        """)

      record = first_record(result)
      assert record["title"] == "Post"
      assert record["comment_count"] == 2
    end

    test "nested belongs_to relationship — pk-only default" do
      {:ok, user} = Ash.create(User, %{name: "Zach"}, action: :create)

      {:ok, _} =
        Ash.create(Post, %{title: "His post", author_id: user.id}, action: :create)

      result =
        run!("""
        local r = assert(posts.post.read({ fields = { "title", { author = {} } } }))
        return r
        """)

      record = first_record(result)
      assert record["title"] == "His post"
      assert is_map(record["author"]) or is_list(record["author"])
      author = deep(record["author"])
      assert Map.keys(author) == ["id"]
      assert author["id"] == user.id
    end

    test "nested belongs_to with explicit sub-fields" do
      {:ok, user} = Ash.create(User, %{name: "Zach", email: "z@x"}, action: :create)
      {:ok, _} = Ash.create(Post, %{title: "Post", author_id: user.id}, action: :create)

      result =
        run!("""
        local r = assert(posts.post.read({
          fields = { "title", { author = { "name", "email" } } }
        }))
        return r
        """)

      record = first_record(result)
      author = deep(record["author"])
      assert author["name"] == "Zach"
      assert author["email"] == "z@x"
      assert Map.keys(author) |> Enum.sort() == ["email", "name"]
    end

    test "nested has_many relationship" do
      {:ok, post} = Ash.create(Post, %{title: "Post"}, action: :create)
      {:ok, _} = Ash.create(Comment, %{body: "first", post_id: post.id}, action: :create)
      {:ok, _} = Ash.create(Comment, %{body: "second", post_id: post.id}, action: :create)

      result =
        run!("""
        local r = assert(posts.post.read({
          fields = { "title", { comments = { "body" } } }
        }))
        return r
        """)

      record = first_record(result)
      comments = record["comments"] |> Enum.map(& &1["body"]) |> Enum.sort()
      assert comments == ["first", "second"]
    end

    test "ci_string attribute encodes as a plain Lua string" do
      {:ok, _} = Ash.create(Post, %{title: "Post", tag: "Featured"}, action: :create)

      result =
        run!("""
        local r = assert(posts.post.read({ fields = { "title", "tag" } }))
        return r
        """)

      record = first_record(result)
      # %Ash.CiString{} must come through as a bare string, not a struct map.
      assert record["tag"] == "Featured"
      assert is_binary(record["tag"])
    end

    test "custom type controls its own encoding via to_lua/2" do
      {:ok, _} = Ash.create(Post, %{title: "Post", price: 1599}, action: :create)

      result =
        run!("""
        local r = assert(posts.post.read({ fields = { "title", "price" } }))
        return r
        """)

      record = first_record(result)
      # AshLua.Test.Posts.Money implements to_lua/2 → map, not a bare integer.
      price = deep(record["price"])
      assert price["cents"] == 1599
      assert price["dollars"] == 15.99
    end

    test "unknown field surfaces a Lua-side error" do
      {[nil, err], _lua} =
        AshLua.eval!(
          """
          return posts.post.read({ fields = { "nope" } })
          """,
          otp_app: :ash_lua
        )

      err_map = Map.new(err)
      assert err_map["class"] == "invalid"
      refute Map.has_key?(err_map, "message")
      first = err_map["errors"] |> List.first() |> elem(1)
      first_map = Map.new(first)
      assert first_map["message"] == "unknown field `nope`"
      assert first_map["code"] == "unknown_field"
      assert Lua.Table.as_list(first_map["fields"]) == ["nope"]
    end
  end

  describe "Tier 2 — calculations with arguments" do
    test "calculation with arg" do
      {:ok, _} = Ash.create(Post, %{title: "abc"}, action: :create)

      result =
        run!("""
        local r = assert(posts.post.read({
          fields = { "title", { title_prefixed = { args = { prefix = ">>" } } } }
        }))
        return r
        """)

      record = first_record(result)
      assert record["title"] == "abc"
      assert record["title_prefixed"] == ">>abc"
    end

    test "unknown calculation argument surfaces an error" do
      {[nil, err], _lua} =
        AshLua.eval!(
          """
          return posts.post.read({
            fields = { { title_prefixed = { args = { wrongarg = "x" } } } }
          })
          """,
          otp_app: :ash_lua
        )

      err_map = Map.new(err)
      assert err_map["class"] == "invalid"
      refute Map.has_key?(err_map, "message")
      first = err_map["errors"] |> List.first() |> elem(1)
      first_map = Map.new(first)
      assert first_map["message"] == "unknown argument `wrongarg` for calculation"
      assert first_map["code"] == "unknown_calculation_arg"
      assert Lua.Table.as_list(first_map["fields"]) == ["wrongarg"]
    end
  end

  describe "Tier 3 — typed maps, tuples, unions" do
    test "typed map sub-selection" do
      {:ok, _} =
        Ash.create(
          Post,
          %{title: "Post", metadata: %{priority: 7, category: "x", notify: true}},
          action: :create
        )

      result =
        run!("""
        local r = assert(posts.post.read({
          fields = { "title", { metadata = { "priority", "category" } } }
        }))
        return r
        """)

      record = first_record(result)
      meta = deep(record["metadata"])
      assert meta["priority"] == 7
      assert meta["category"] == "x"
      refute Map.has_key?(meta, "notify")
    end

    test "tuple sub-selection" do
      {:ok, _} =
        Ash.create(Post, %{title: "Geo", coordinates: {37.7, -122.4}}, action: :create)

      result =
        run!("""
        local r = assert(posts.post.read({
          fields = { "title", { coordinates = { "latitude" } } }
        }))
        return r
        """)

      record = first_record(result)
      coords = deep(record["coordinates"])
      assert coords["latitude"] == 37.7
      refute Map.has_key?(coords, "longitude")
    end

    test "union member sub-selection" do
      {:ok, _} =
        Ash.create(
          Post,
          %{title: "Post", content: %{"kind" => "text", "body" => "hi", "word_count" => 1}},
          action: :create
        )

      result =
        run!("""
        local r = assert(posts.post.read({
          fields = { "title", { content = { text = { "body" } } } }
        }))
        return r
        """)

      record = first_record(result)
      content = deep(record["content"])
      assert content["type"] == "text"
      value = deep(content["value"])
      assert value["body"] == "hi"
      refute Map.has_key?(value, "word_count")
    end
  end

  describe "operation key on list operations" do
    test "count returns an integer for matching records" do
      {:ok, _} = Ash.create(Post, %{title: "a"}, action: :create)
      {:ok, _} = Ash.create(Post, %{title: "b", published: true}, action: :create)
      {:ok, _} = Ash.create(Post, %{title: "c", published: true}, action: :create)

      {[total], _lua} =
        AshLua.eval!(
          """
          local n = assert(posts.post.read({ operation = "count" }))
          return n
          """,
          otp_app: :ash_lua
        )

      assert total == 3

      {[published], _lua} =
        AshLua.eval!(
          """
          local n = assert(posts.post.read({
            filter = { published = true },
            operation = "count"
          }))
          return n
          """,
          otp_app: :ash_lua
        )

      assert published == 2
    end

    test "exists returns a boolean" do
      {:ok, _} = Ash.create(Post, %{title: "anything"}, action: :create)

      {[any], _lua} =
        AshLua.eval!(
          """
          local b = assert(posts.post.read({ operation = "exists" }))
          return b
          """,
          otp_app: :ash_lua
        )

      assert any == true
    end

    test "avg over a field" do
      {:ok, post} = Ash.create(Post, %{title: "p"}, action: :create)

      for r <- [2, 4, 6] do
        {:ok, _} = Ash.create(Comment, %{body: "c", rating: r, post_id: post.id}, action: :create)
      end

      {[avg], _lua} =
        AshLua.eval!(
          """
          local a = assert(posts.comment.read({ operation = { "avg", "rating" } }))
          return a
          """,
          otp_app: :ash_lua
        )

      assert avg in [4, 4.0, "4"]
    end

    test "sum over a field with a filter" do
      {:ok, post} = Ash.create(Post, %{title: "p"}, action: :create)
      {:ok, _} = Ash.create(Comment, %{body: "low", rating: 1, post_id: post.id}, action: :create)
      {:ok, _} = Ash.create(Comment, %{body: "mid", rating: 5, post_id: post.id}, action: :create)

      {:ok, _} =
        Ash.create(Comment, %{body: "high", rating: 10, post_id: post.id}, action: :create)

      {[sum], _lua} =
        AshLua.eval!(
          """
          local s = assert(posts.comment.read({
            filter = { rating = { greater_than_or_equal = 5 } },
            operation = { "sum", "rating" }
          }))
          return s
          """,
          otp_app: :ash_lua
        )

      assert sum == 15
    end

    test "filter accepts long-form operator names (equals, not_equals, less_than, less_than_or_equal, greater_than, greater_than_or_equal)" do
      {:ok, _} = Ash.create(Post, %{title: "apple"}, action: :create)
      {:ok, _} = Ash.create(Post, %{title: "banana"}, action: :create)
      {:ok, _} = Ash.create(Post, %{title: "cherry"}, action: :create)

      for {expr, expected} <- [
            {~s/{ equals = "banana" }/, 1},
            {~s/{ not_equals = "banana" }/, 2},
            {~s/{ less_than = "cherry" }/, 2},
            {~s/{ less_than_or_equal = "cherry" }/, 3},
            {~s/{ greater_than = "apple" }/, 2},
            {~s/{ greater_than_or_equal = "apple" }/, 3}
          ] do
        {[count, _], _lua} =
          AshLua.eval!(
            """
            return assert(posts.post.read({
              filter = { title = #{expr} },
              operation = "count"
            }))
            """,
            otp_app: :ash_lua
          )

        assert count == expected, "expected #{expected} for filter title #{expr}, got #{count}"
      end
    end

    test "list over a field returns an array of values" do
      {:ok, post} = Ash.create(Post, %{title: "p"}, action: :create)

      for r <- [3, 1, 2] do
        {:ok, _} = Ash.create(Comment, %{body: "c", rating: r, post_id: post.id}, action: :create)
      end

      {[ratings], _lua} =
        AshLua.eval!(
          """
          local r = assert(posts.comment.read({
            sort = "rating",
            operation = { "list", "rating" }
          }))
          return r
          """,
          otp_app: :ash_lua
        )

      assert Lua.Table.as_list(ratings) == [1, 2, 3]
    end

    test "first over a field returns the leading value" do
      {:ok, post} = Ash.create(Post, %{title: "p"}, action: :create)

      for r <- [5, 2, 9] do
        {:ok, _} = Ash.create(Comment, %{body: "c", rating: r, post_id: post.id}, action: :create)
      end

      {[lowest], _lua} =
        AshLua.eval!(
          """
          local r = assert(posts.comment.read({
            sort = "rating",
            operation = { "first", "rating" }
          }))
          return r
          """,
          otp_app: :ash_lua
        )

      assert lowest == 2
    end

    test "unknown operation surfaces an error" do
      {[nil, err], _lua} =
        AshLua.eval!(
          """
          return posts.post.read({ operation = "bogus" })
          """,
          otp_app: :ash_lua
        )

      err_map = Map.new(err)
      assert err_map["class"] == "invalid"
      first = err_map["errors"] |> List.first() |> elem(1)
      first_map = Map.new(first)
      assert first_map["message"] == "unknown operation `bogus`"
      assert first_map["code"] == "unknown_operation"
    end

    test "operation on a non-list operation is rejected" do
      {[nil, err], _lua} =
        AshLua.eval!(
          """
          return posts.post.create({ input = { title = "x" }, operation = "count" })
          """,
          otp_app: :ash_lua
        )

      err_map = Map.new(err)
      assert err_map["class"] == "invalid"
      first = err_map["errors"] |> List.first() |> elem(1)
      first_map = Map.new(first)
      assert first_map["message"] =~ "only supported on list operations"
      assert first_map["code"] == "operation_only_on_list_operations"
    end
  end

  describe "across all action types" do
    test "create honors fields" do
      {:ok, user} = Ash.create(User, %{name: "Author", email: "a@b"}, action: :create)

      {[post], _lua} =
        AshLua.eval!(
          """
          local p = assert(posts.post.create({
            input = { title = "Created", body = "B", author_id = "#{user.id}" },
            fields = { "title", { author = { "name" } } }
          }))
          return p
          """,
          otp_app: :ash_lua
        )

      record = deep(post)
      assert record["title"] == "Created"
      author = deep(record["author"])
      assert author["name"] == "Author"
    end

    test "update honors fields" do
      {:ok, post} = Ash.create(Post, %{title: "Old"}, action: :create)

      {[updated], _lua} =
        AshLua.eval!(
          """
          local p = assert(posts.post.update({
            input = { id = "#{post.id}", title = "New" },
            fields = { "title", "title_downcase" }
          }))
          return p
          """,
          otp_app: :ash_lua
        )

      record = deep(updated)
      assert record["title"] == "New"
      assert record["title_downcase"] == "new"
    end

    test "destroy honors fields on the destroyed record" do
      {:ok, post} = Ash.create(Post, %{title: "Bye"}, action: :create)

      {[destroyed], _lua} =
        AshLua.eval!(
          """
          local p = assert(posts.post.destroy({
            input = { id = "#{post.id}" },
            fields = { "title" }
          }))
          return p
          """,
          otp_app: :ash_lua
        )

      record = deep(destroyed)
      assert record["title"] == "Bye"
    end

    test "generic action ignores fields gracefully" do
      {[count], _lua} =
        AshLua.eval!(
          """
          local n = assert(posts.post.word_count({
            input = { text = "one two three" }
          }))
          return n
          """,
          otp_app: :ash_lua
        )

      assert count == 3
    end
  end
end
