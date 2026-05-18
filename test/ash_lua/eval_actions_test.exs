# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.EvalActionsTest do
  use ExUnit.Case, async: false

  alias AshLua.Test.Posts.MCPActions
  alias AshLua.Test.Posts.Post

  describe "synthesized :eval action" do
    test "runs a Lua script against the scoped Lua surface" do
      {:ok, _} = Ash.create(Post, %{title: "Hello"}, action: :create)

      input =
        Ash.ActionInput.for_action(MCPActions, :eval, %{
          script: """
          local records = assert(posts.post.read({ fields = { "title" } }))
          return records[1].title
          """
        })

      assert {:ok, %{result: "Hello", error: nil}} = Ash.run_action(input)
    end

    test "captures a Lua-side (nil, err) into the structured response" do
      input =
        Ash.ActionInput.for_action(MCPActions, :eval, %{
          script: """
          return posts.post.create({ body = "missing title" })
          """
        })

      assert {:ok, %{result: nil, error: err}} = Ash.run_action(input)
      assert is_map(err)
      err_map = Map.new(err)
      assert is_binary(err_map["message"])
    end

    test "wraps Lua function references as opaque markers so JSON encoding survives" do
      # `return print` hands us a `{:funref, ...}` Luerl record. The action's
      # `result` slot is typed `:term`, so without normalization the funref
      # would reach Jason and crash. Verify it renders as a self-describing
      # opaque marker instead.
      input = Ash.ActionInput.for_action(MCPActions, :eval, %{script: "return print"})

      assert {:ok, %{result: %{"opaque" => "function"}, error: nil}} = Ash.run_action(input)
      assert {:ok, _} = Jason.encode(%{result: %{"opaque" => "function"}, error: nil})
    end

    test "wraps function references inside a returned table" do
      # A script that returns a Lua table containing functions (think
      # `return loop.item` where `loop.item` exposes methods alongside data).
      # The decoded table flattens to a plain string-keyed map; function
      # values become opaque markers instead of crashing Jason.
      input =
        Ash.ActionInput.for_action(MCPActions, :eval, %{
          script: """
          return { data = "hello", method = print }
          """
        })

      assert {:ok, %{result: result, error: nil}} = Ash.run_action(input)
      assert result == %{"data" => "hello", "method" => %{"opaque" => "function"}}
      assert {:ok, _} = Jason.encode(%{result: result})
    end

    test "Luerl-decoded Lua arrays come back as plain lists, not nested tuple-maps" do
      input =
        Ash.ActionInput.for_action(MCPActions, :eval, %{
          script: """
          return { 10, 20, 30 }
          """
        })

      assert {:ok, %{result: [10, 20, 30], error: nil}} = Ash.run_action(input)
    end

    test "an array of records flattens cleanly through the JSON-safe encoder" do
      {:ok, _} = Ash.create(Post, %{title: "p1", body: "b1"}, action: :create)
      {:ok, _} = Ash.create(Post, %{title: "p2", body: "b2"}, action: :create)

      input =
        Ash.ActionInput.for_action(MCPActions, :eval, %{
          script: """
          return assert(posts.post.read({ fields = { "title" }, sort = "title" }))
          """
        })

      assert {:ok, %{result: result, error: nil}} = Ash.run_action(input)
      assert is_list(result)
      assert Enum.map(result, &Map.get(&1, "title")) == ["p1", "p2"]
      assert {:ok, _} = Jason.encode(%{result: result})
    end

    test "captures a Lua syntax error as a structured response" do
      input =
        Ash.ActionInput.for_action(MCPActions, :eval, %{
          script: """
          this is not valid lua;
          """
        })

      assert {:ok, %{result: nil, error: err}} = Ash.run_action(input)
      assert [%{"code" => "lua_error"} | _] = err["errors"]
    end

    test "an assert(...) on a failed action surfaces the structured error, not 'object is a table'" do
      # A script that asserts a known-bad call. The eval action should
      # decode the err table back out of the Lua exception and surface the
      # original `invalid_fields` / etc. shape, not a generic Lua error.
      input =
        Ash.ActionInput.for_action(MCPActions, :eval, %{
          script: """
          return assert(posts.post.read({ fields = { "totally_not_a_real_field" } }))
          """
        })

      assert {:ok, %{result: nil, error: err}} = Ash.run_action(input)
      refute err["message"] =~ "error object is a table"
      assert err["message"] == "unknown field `totally_not_a_real_field`"
      assert [first | _] = err["errors"]
      first_map = if is_map(first), do: first, else: Map.new(first)
      assert first_map["code"] == "unknown_field"
      first_fields = first_map["fields"]
      first_fields_list = if is_list(first_fields), do: first_fields, else: [first_fields]
      # `fields` is a Lua array → comes back as either a list or a [{1,v}] kv-list
      flat =
        Enum.map(first_fields_list, fn
          {_, v} -> v
          v -> v
        end)

      assert "totally_not_a_real_field" in flat
    end

    test "scopes the surface — actions outside `eval_actions` are not callable" do
      # MCPActions exposes Post[:read, :create] and Comment[:read]. Try to call
      # a write action on Comment that wasn't listed.
      input =
        Ash.ActionInput.for_action(MCPActions, :eval, %{
          script: """
          local _, err = posts.comment.create({ body = "x" })
          return err == nil
          """
        })

      # `create` isn't exposed on Comment → the call itself raises in Lua
      # because `posts.comment.create` doesn't exist as a callable. That
      # surfaces as a Lua runtime error captured into the err field.
      {:ok, %{result: result, error: error}} = Ash.run_action(input)

      assert result == nil or result == false
      assert is_nil(result) or is_map(error)
    end
  end

  describe "synthesized :docs action" do
    test "with no name returns the full scoped markdown page" do
      input = Ash.ActionInput.for_action(MCPActions, :docs, %{})

      assert {:ok, md} = Ash.run_action(input)
      assert md =~ "# API reference"
      assert md =~ "# `posts.post.read`"
      assert md =~ "# `posts.post.create`"
      assert md =~ "# `posts.comment.read`"
      # Out-of-scope actions are not in the docs.
      refute md =~ "# `posts.comment.create`"
      refute md =~ "# `posts.user.read`"
    end

    test "with a callable name returns just that page" do
      input = Ash.ActionInput.for_action(MCPActions, :docs, %{name: "posts.post.read"})

      assert {:ok, md} = Ash.run_action(input)
      assert md =~ "# `posts.post.read`"
      assert md =~ "**Operation:** `list`"
    end

    test "with a record type name returns the type page" do
      input = Ash.ActionInput.for_action(MCPActions, :docs, %{name: "posts.post"})

      assert {:ok, md} = Ash.run_action(input)
      assert md =~ "# Record type `posts.post`"
    end

    test "with a topic id returns the topic page" do
      input = Ash.ActionInput.for_action(MCPActions, :docs, %{name: "filters"})

      assert {:ok, md} = Ash.run_action(input)
      assert md =~ "# Filters"
    end

    test "with an unknown name returns an invalid_argument error" do
      input = Ash.ActionInput.for_action(MCPActions, :docs, %{name: "nope.does.not.exist"})

      assert {:error, %Ash.Error.Invalid{errors: [err | _]}} = Ash.run_action(input)
      assert err.field == :name
    end

    test "with `search` set returns ranked matches over the scoped surface" do
      input = Ash.ActionInput.for_action(MCPActions, :docs, %{search: "post"})

      assert {:ok, md} = Ash.run_action(input)
      assert md =~ "# Search results for `post`"
      assert md =~ "`posts.post.read`"
      assert md =~ "`posts.post.create`"
      # `posts.user.read` is out of scope on MCPActions — search must respect it.
      refute md =~ "`posts.user.read`"
    end

    test "search with no matches returns the no-matches blurb" do
      input = Ash.ActionInput.for_action(MCPActions, :docs, %{search: "totally-not-a-thing"})

      assert {:ok, md} = Ash.run_action(input)
      assert md =~ "_No matches._"
    end

    test "passing both `name` and `search` is an error" do
      input =
        Ash.ActionInput.for_action(MCPActions, :docs, %{
          name: "posts.post.read",
          search: "post"
        })

      assert {:error, %Ash.Error.Invalid{errors: [err | _]}} = Ash.run_action(input)
      assert err.field == :search
    end
  end

  describe "custom eval_action_name / docs_action_name" do
    alias AshLua.Test.Posts.CustomMCPActions

    test "exposes the actions under the configured names" do
      action_names =
        CustomMCPActions
        |> Ash.Resource.Info.actions()
        |> Enum.map(& &1.name)

      assert :run in action_names
      assert :describe in action_names
      refute :eval in action_names
      refute :docs in action_names
    end

    test "the renamed eval action behaves like :eval" do
      input = Ash.ActionInput.for_action(CustomMCPActions, :run, %{script: "return 42"})
      assert {:ok, %{result: 42, error: nil}} = Ash.run_action(input)
    end

    test "the renamed docs action behaves like :docs" do
      input = Ash.ActionInput.for_action(CustomMCPActions, :describe, %{})
      assert {:ok, md} = Ash.run_action(input)
      assert md =~ "# API reference"
    end
  end
end
