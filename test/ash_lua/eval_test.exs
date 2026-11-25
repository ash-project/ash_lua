# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.EvalTest do
  use ExUnit.Case, async: false

  alias AshLua.Test.Surface.MCPActions
  alias AshLua.Test.Surface.Page

  defp eval_manifest_cache do
    :persistent_term.get({AshLua.Surface, :eval_manifest_cache}, %{})
  end

  test "manifest/1 resolves eval resource scopes" do
    assert {:ok, manifest} = AshLua.Eval.manifest(eval_resource: MCPActions)

    callables = AshLua.Docs.list_callables(manifest)

    assert "surface.page_list" in callables
    refute "surface.admin.page_rename" in callables
  end

  test "manifest/1 caches eval resource scopes when requested" do
    AshLua.Surface.clear_eval_manifest_cache!()

    try do
      assert {:ok, _manifest} = AshLua.Eval.manifest(eval_resource: MCPActions)
      refute Map.has_key?(eval_manifest_cache(), MCPActions)

      assert {:ok, _manifest} = AshLua.Eval.manifest(eval_resource: MCPActions, cache?: true)
      assert Map.has_key?(eval_manifest_cache(), MCPActions)
    after
      AshLua.Surface.clear_eval_manifest_cache!()
    end
  end

  test "manifest/1 resolves otp app label scopes" do
    assert {:ok, manifest} = AshLua.Eval.manifest(otp_app: :ash_lua, labels: [:read_model])

    assert AshLua.Docs.list_callables(manifest) == ["surface.page_list"]
  end

  test "run/2 evaluates against a prebuilt scoped manifest" do
    title = unique_title("Runtime")
    {:ok, _page} = Ash.create(Page, %{title: title}, action: :create)
    manifest = AshLua.Eval.manifest!(eval_resource: MCPActions)

    assert {:ok, %{result: ^title, error: nil, print_output: ["loaded"]}} =
             AshLua.Eval.run(
               """
               local rows = assert(surface.page_list({
                 fields = { "headline" },
                 filter = { headline = "#{title}" }
               }))

               print("loaded")
               return rows[1].headline
               """,
               manifest: manifest
             )
  end

  test "run/2 accepts Lua safety options" do
    assert {:ok, %{result: nil, error: err, print_output: []}} =
             AshLua.Eval.run("while true do end",
               eval_resource: MCPActions,
               lua_options: [max_instructions: 1_000]
             )

    assert err["class"] == "lua_error"
    assert [%{"code" => "lua_error"} | _] = err["errors"]
    assert err["message"] =~ "instruction budget exceeded"
  end

  describe "host exceptions during a call" do
    import ExUnit.CaptureLog

    test "a malformed filter returns an invalid_filter_value error instead of aborting" do
      assert {:ok, %{result: nil, error: err, print_output: ["before", "after"]}} =
               AshLua.Eval.run(
                 """
                 print("before")
                 local r, err = posts.post.read({ filter = { ["or"] = {} } })
                 print("after")
                 return r, err
                 """,
                 otp_app: :ash_lua
               )

      assert err["class"] == "invalid"

      assert [
               %{
                 "code" => "invalid_filter_value",
                 "vars" => %{"detail" => "expected a non-empty list or map"}
               }
             ] = err["errors"]
    end

    test "a malformed sort returns an invalid_sort error instead of aborting" do
      assert {:ok, %{result: nil, error: err, print_output: []}} =
               AshLua.Eval.run(
                 """
                 local r, err = posts.post.read({ sort = 5 })
                 return r, err
                 """,
                 otp_app: :ash_lua
               )

      assert err["class"] == "invalid"
      assert [%{"code" => "invalid_sort", "fields" => ["sort"]}] = err["errors"]
    end

    test "a raise inside an action is returned as an opaque unknown_error" do
      {result, log} =
        with_log(fn ->
          AshLua.Eval.run(
            """
            print("before")
            local r, err = posts.post.explode({})
            print("after")
            return r, err
            """,
            otp_app: :ash_lua
          )
        end)

      assert {:ok, %{result: nil, error: err, print_output: ["before", "after"]}} = result
      assert err["class"] == "unknown"
      assert [%{"code" => "unknown_error", "message" => message, "vars" => vars}] = err["errors"]

      refute message =~ "kaboom"
      refute inspect(err) =~ "kaboom"

      assert log =~ vars["uuid"]
      assert log =~ "kaboom"
    end
  end

  describe "query input errors" do
    test "an unknown field in a filter renders as unknown_field" do
      assert {:ok, %{error: err}} =
               AshLua.Eval.run(
                 ~S|local r, err = posts.post.read({ filter = { nope = "x" } }) return r, err|,
                 otp_app: :ash_lua
               )

      assert %{"class" => "invalid", "errors" => [leaf]} = err

      assert %{
               "code" => "unknown_field",
               "fields" => ["nope"],
               "vars" => %{"name" => "nope", "path" => ["filter"]}
             } = leaf

      refute inspect(err) =~ "AshLua.Test"
    end

    test "an unknown filter predicate renders as no_such_filter_predicate" do
      assert {:ok, %{error: err}} =
               AshLua.Eval.run(
                 ~S|local r, err = posts.post.read({ filter = { title = { nope = "x" } } }) return r, err|,
                 otp_app: :ash_lua
               )

      assert %{"class" => "invalid", "errors" => [leaf]} = err
      assert %{"code" => "no_such_filter_predicate", "vars" => %{"predicate" => "nope"}} = leaf
      refute inspect(err) =~ "AshLua.Test"
    end

    test "an invalid filter value renders as invalid_filter_value naming the field" do
      assert {:ok, %{error: err}} =
               AshLua.Eval.run(
                 ~S|local r, err = posts.post.read({ filter = { title = { ["in"] = 5 } } }) return r, err|,
                 otp_app: :ash_lua
               )

      assert %{"class" => "invalid", "errors" => [leaf]} = err
      assert %{"code" => "invalid_filter_value", "fields" => ["title"], "vars" => vars} = leaf
      assert vars["value"] == "title in 5"
      refute inspect(err) =~ "AshLua.Test"
    end

    test "an unknown field in a sort renders as unknown_field" do
      assert {:ok, %{error: err}} =
               AshLua.Eval.run(
                 ~S|local r, err = posts.post.read({ sort = "-nope" }) return r, err|,
                 otp_app: :ash_lua
               )

      assert %{"class" => "invalid", "errors" => [leaf]} = err

      assert %{"code" => "unknown_field", "fields" => ["nope"], "vars" => %{"path" => ["sort"]}} =
               leaf
    end

    test "an unknown action input renders as no_such_input" do
      assert {:ok, %{error: err}} =
               AshLua.Eval.run(
                 ~S|local r, err = posts.post.create({ input = { title = "t", titel = "x" } }) return r, err|,
                 otp_app: :ash_lua
               )

      assert %{"class" => "invalid", "errors" => [leaf]} = err
      assert %{"code" => "no_such_input", "fields" => ["titel"], "vars" => vars} = leaf
      assert vars["did_you_mean"] == ["title"]
      refute inspect(err) =~ "AshLua.Test"
    end
  end

  describe "returned error tables" do
    test "a returned error table is converted at every depth and is JSON-encodable" do
      assert {:ok, %{result: nil, error: err} = run_result} =
               AshLua.Eval.run(
                 """
                 local r, err = posts.post.create({ input = { body = "no title" } })
                 return r, err
                 """,
                 otp_app: :ash_lua
               )

      assert %{"class" => "invalid", "errors" => [leaf]} = err
      assert %{"code" => "required", "fields" => ["title"], "vars" => %{}} = leaf
      assert {:ok, _json} = Jason.encode(run_result)
    end

    test "empty Lua tables in the envelope come back as lists" do
      assert {:ok, %{error: err}} =
               AshLua.Eval.run(
                 """
                 return nil, { class = "invalid", errors = { { message = "m", fields = {} } } }
                 """,
                 otp_app: :ash_lua
               )

      assert %{"class" => "invalid", "errors" => [%{"message" => "m", "fields" => []}]} = err

      assert {:ok, %{error: %{"errors" => []}}} =
               AshLua.Eval.run(~S|return nil, { class = "invalid", errors = {} }|,
                 otp_app: :ash_lua
               )
    end

    test "a bare value in the error slot is wrapped in a lua_error envelope" do
      assert {:ok, %{result: nil, error: err}} =
               AshLua.Eval.run(~S|return nil, "oops"|, otp_app: :ash_lua)

      assert %{"class" => "lua_error", "message" => "oops", "errors" => [leaf]} = err
      assert %{"code" => "lua_error", "message" => "oops", "fields" => []} = leaf
      assert {:ok, _json} = Jason.encode(err)
    end

    test "a script runtime error is a lua_error envelope" do
      assert {:ok, %{result: nil, error: err}} =
               AshLua.Eval.run(~S|local t = nil return t.x|, otp_app: :ash_lua)

      assert %{"class" => "lua_error", "errors" => [%{"code" => "lua_error"}]} = err
      assert is_binary(err["message"])
    end
  end

  # Runs `script` and asserts that the whole reply encodes as JSON, which is
  # what an MCP server does with it.
  defp run_encodable(script, opts \\ []) do
    assert {:ok, reply} = AshLua.Eval.run(script, Keyword.put_new(opts, :otp_app, :ash_lua))
    assert {:ok, _json} = Jason.encode(reply)
    reply
  end

  defp host_vm do
    {_, lua} = Lua.eval!(Lua.new(), ~S|function helper(s) return s .. "HOST_CONSTANT" end|)
    lua
  end

  # A host VM holding a userdata value, which Lua code cannot read.
  defp userdata_vm do
    {ud, lua} = Lua.encode!(Lua.new(), {:userdata, %{token: "USERDATA_SECRET"}})
    Lua.set!(lua, [:ud], ud)
  end

  describe "returned values that are not plain data" do
    test "every value returns a reply that encodes as JSON" do
      for script <- [
            "return nil, print",
            "return nil, function() end",
            "return nil, { print }",
            "return nil, { function() end }",
            "return nil, { [print] = 1 }",
            "return nil, { [{}] = 1 }",
            "return nil, { f = print }",
            "return nil, { class = 'invalid', errors = { { code = 'x', message = 'm', vars = { f = print } } } }",
            "local t = {} t.a = t return nil, t",
            "local t = {} t[1] = t return nil, t",
            ~S|return nil, "\255"|,
            ~S|return nil, { ["\255"] = 1 }|,
            "return { [print] = 1 }",
            "return { [{}] = 1 }",
            ~S|return { ["\255"] = 1 }|,
            ~S|print("\255") return 1|,
            "error({ [print] = 1 })",
            "error({ class = 'invalid', errors = {}, f = print })",
            ~S|error({ class = "invalid", errors = { { message = "\255" } } })|
          ] do
        run_encodable(script)
      end
    end

    test "a function as the error value is a lua_error envelope" do
      for script <- ["return nil, print", "return nil, function() end"] do
        assert %{result: nil, error: err} = run_encodable(script)

        assert %{
                 "class" => "lua_error",
                 "message" => ~S|{"opaque":"function"}|,
                 "errors" => [%{"code" => "lua_error", "message" => ~S|{"opaque":"function"}|}]
               } = err
      end
    end

    test "a sequence as the error value reads as the JSON it converts to" do
      assert %{error: %{"class" => "lua_error", "message" => ~S|["a","b"]|}} =
               run_encodable(~S|return nil, { "a", "b" }|)

      assert %{error: %{"message" => ~S|[{"opaque":"function"}]|}} =
               run_encodable("return nil, { print }")

      assert %{error: %{"message" => ~S|[{"opaque":"table_reference"}]|}} =
               run_encodable("local t = {} t[1] = t return nil, t")
    end

    test "a Lua function the host defined does not expose its code" do
      for script <- [
            "return nil, { helper }",
            ~S|return nil, { class = "invalid", errors = { { code = "x", message = "m", vars = { f = helper } } } }|
          ] do
        json = script |> run_encodable(lua: host_vm()) |> Jason.encode!()

        refute json =~ "HOST_CONSTANT"
        refute json =~ "Prototype"
      end

      assert %{error: %{"errors" => [%{"vars" => %{"f" => %{"opaque" => "function"}}}]}} =
               run_encodable(
                 ~S|return nil, { class = "invalid", errors = { { code = "x", message = "m", vars = { f = helper } } } }|,
                 lua: host_vm()
               )
    end

    test "Lua references inside an error table become opaque markers" do
      assert %{error: %{"f" => %{"opaque" => "function"}}} =
               run_encodable("return nil, { f = print }")

      assert %{error: %{"a" => %{"opaque" => "table_reference"}}} =
               run_encodable("local t = {} t.a = t return nil, t")
    end

    test "text that is not valid UTF-8 is base64-encoded, as in the result slot" do
      assert %{error: %{"message" => "/w=="}} = run_encodable(~S|return nil, "\255"|)
      assert %{error: %{"/w==" => 1}} = run_encodable(~S|return nil, { ["\255"] = 1 }|)
      assert %{result: %{"/w==" => 1}} = run_encodable(~S|return { ["\255"] = 1 }|)
    end

    test "a table key that is a function or a table is a lua_error envelope" do
      assert %{result: nil, error: err} = run_encodable("return nil, { [print] = 1 }")

      assert %{
               "class" => "lua_error",
               "message" =>
                 "a table key must be a string, a number, or a boolean, not a function",
               "errors" => [%{"vars" => vars}]
             } = err

      assert vars == %{"key" => "function"}

      assert %{error: %{"message" => message}} =
               run_encodable("return nil, { a = { [print] = 1 } }")

      assert message ==
               "a table key must be a string, a number, or a boolean, not a function (in `a`)"

      assert %{result: nil, error: err, print_output: ["before"]} =
               run_encodable(~S|print("before") return { [{}] = 1 }|)

      assert %{
               "class" => "lua_error",
               "message" => "a table key must be a string, a number, or a boolean, not a table"
             } = err
    end

    test "a raised error envelope is converted like a returned one" do
      assert %{result: nil, error: err} =
               run_encodable("error({ class = 'invalid', errors = {}, f = print })")

      assert %{"class" => "invalid", "errors" => [], "f" => %{"opaque" => "function"}} = err
    end

    test "a raised table with a function key is a lua_error envelope, not a raise" do
      assert %{
               result: nil,
               error: %{"class" => "lua_error", "errors" => [%{"code" => "lua_error"}]}
             } =
               run_encodable("error({ [print] = 1 })")
    end

    test "userdata the host gave the script comes back only as an opaque marker" do
      assert %{result: %{"opaque" => "userdata"}} =
               run_encodable("return ud", lua: userdata_vm())

      assert %{error: %{"u" => %{"opaque" => "userdata"}}} =
               run_encodable("return nil, { u = ud }", lua: userdata_vm())

      assert %{error: %{"message" => ~S|{"opaque":"userdata"}|}} =
               run_encodable("return nil, ud", lua: userdata_vm())

      for script <- [
            "return ud",
            "return nil, { u = ud }",
            "return nil, ud",
            "print({ ud }) return 1"
          ] do
        refute script |> run_encodable(lua: userdata_vm()) |> Jason.encode!() =~ "USERDATA_SECRET"
      end
    end

    test "a value with no JSON number form reads as its name" do
      assert %{error: %{"message" => "nan"}} = run_encodable("return nil, 0/0")
    end

    test "the :eval action returns a function error value instead of raising" do
      input = Ash.ActionInput.for_action(MCPActions, :eval, %{script: "return nil, print"})

      assert {:ok, %{result: nil, error: %{"class" => "lua_error"}}} = Ash.run_action(input)
    end
  end

  describe "a key that is not text in a call's arguments" do
    import ExUnit.CaptureLog

    test "is an invalid_table_key error that names where it is" do
      log =
        capture_log(fn ->
          assert {:ok, %{result: nil, error: err}} =
                   AshLua.Eval.run(
                     """
                     local r, err = posts.post.create({ input = { title = "t", metadata = { [print] = "v" } } })
                     return r, err
                     """,
                     otp_app: :ash_lua
                   )

          assert err["class"] == "invalid"

          assert [
                   %{
                     "code" => "invalid_table_key",
                     "message" =>
                       "a table key must be a string, a number, or a boolean, not a function (in `input.metadata`)",
                     "fields" => ["metadata"],
                     "vars" => %{"key" => "function", "path" => ["input", "metadata"]}
                   }
                 ] = err["errors"]
        end)

      refute log =~ "AshLua.Error not implemented"
    end

    test "at the top level it has no path" do
      assert {:ok, %{error: err}} =
               AshLua.Eval.run("return posts.post.read({ [print] = 1 })", otp_app: :ash_lua)

      assert [%{"code" => "invalid_table_key", "fields" => [], "vars" => vars}] = err["errors"]
      assert vars == %{"key" => "function"}
    end

    test "a table used as a key is reported the same way" do
      assert {:ok, %{error: err}} =
               AshLua.Eval.run(
                 """
                 local r, err = posts.post.read({ filter = { [{}] = 1 } })
                 return r, err
                 """,
                 otp_app: :ash_lua
               )

      assert [
               %{
                 "code" => "invalid_table_key",
                 "vars" => %{"key" => "table", "path" => ["filter"]}
               }
             ] = err["errors"]
    end
  end

  describe "a value with no data form in a call's arguments" do
    test "a function is an invalid_value error that names where it is" do
      for {args, path} <- [
            {"{ limit = helper }", ["limit"]},
            {"{ offset = helper }", ["offset"]},
            {"{ sort = helper }", ["sort"]},
            {"{ filter = helper }", ["filter"]},
            {"{ filter = { title = helper } }", ["filter", "title"]},
            {"{ input = { title = helper } }", ["input", "title"]}
          ] do
        reply = run_encodable("return posts.post.read(#{args})", lua: host_vm())

        assert %{result: nil, error: %{"class" => "invalid", "errors" => [leaf]}} = reply

        assert %{
                 "code" => "invalid_value",
                 "fields" => [field],
                 "vars" => %{"value" => "function", "path" => ^path}
               } = leaf

        assert field == List.last(path)

        assert leaf["message"] ==
                 "a function has no data form and cannot be passed to an action (in `#{Enum.join(path, ".")}`)"

        refute Jason.encode!(reply) =~ "HOST_CONSTANT"
      end
    end

    test "a function as the whole argument is an invalid_value error" do
      assert %{error: %{"errors" => [%{"code" => "invalid_value", "vars" => vars}]}} =
               run_encodable("return posts.post.read(helper)", lua: host_vm())

      assert vars == %{"value" => "function"}
    end

    test "a function inside a map field is rejected even where its constraints would drop it" do
      assert {:ok, %{error: err}} =
               AshLua.Eval.run(
                 """
                 return posts.post.create({
                   input = { title = "t", metadata = { priority = 1, cb = print } },
                   fields = { "title", "metadata" }
                 })
                 """,
                 otp_app: :ash_lua
               )

      assert [%{"code" => "invalid_value", "vars" => %{"path" => ["input", "metadata", "cb"]}}] =
               err["errors"]
    end

    test "userdata is an invalid_value error" do
      reply = run_encodable("return posts.post.read({ limit = ud })", lua: userdata_vm())

      assert %{error: %{"class" => "invalid", "errors" => [leaf]}} = reply

      assert %{"code" => "invalid_value", "vars" => %{"value" => "userdata", "path" => ["limit"]}} =
               leaf

      assert leaf["message"] == "a userdata value cannot be passed to an action (in `limit`)"
      refute Jason.encode!(reply) =~ "USERDATA_SECRET"
    end

    test "a table that contains itself is an invalid_value error" do
      assert %{error: %{"errors" => [leaf]}} =
               run_encodable(
                 "local t = {} t.a = t return posts.post.read({ filter = t })",
                 lua: host_vm()
               )

      assert %{"code" => "invalid_value", "vars" => %{"value" => "table"}} = leaf
      assert leaf["message"] =~ "a table that contains itself"
      refute leaf["message"] =~ "tref"
    end
  end

  test "run/2 returns structured Lua syntax errors" do
    assert {:ok, %{result: nil, error: err, print_output: []}} =
             AshLua.Eval.run(
               """
               local x =
               return x
               """,
               eval_resource: MCPActions,
               source: "agent_script.lua"
             )

    assert err["class"] == "lua_error"
    assert [%{"code" => "lua_error", "vars" => vars} | _] = err["errors"]
    refute String.contains?(err["message"], <<27>>)
    assert vars["type"] == "unexpected_token"
    assert vars["source"] == "agent_script.lua"
    assert vars["line"] == 2
    assert vars["source_context"]["pointer_column"] == 1

    assert Enum.any?(vars["source_context"]["lines"], fn line ->
             line["number"] == 2 and line["highlight"] == true
           end)
  end

  test "docs/2 dispatches against a scoped manifest" do
    manifest = AshLua.Eval.manifest!(eval_resource: MCPActions)

    assert {:ok, index} = AshLua.Eval.docs(manifest)
    assert index =~ "- `surface.page_list`"
    refute index =~ "surface.admin.page_rename"

    assert {:ok, callable} = AshLua.Eval.docs(manifest, name: "surface.page_list")
    assert callable =~ "# `surface.page_list`"

    assert {:error, %Ash.Error.Action.InvalidArgument{field: :search}} =
             AshLua.Eval.docs(manifest, name: "surface.page_list", search: "page")
  end

  defp unique_title(prefix) do
    "#{prefix} #{System.unique_integer([:positive])}"
  end
end
