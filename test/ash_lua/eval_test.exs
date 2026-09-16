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

    test "a malformed filter returns an invalid_filter error instead of aborting" do
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
      assert [%{"code" => "invalid_filter", "fields" => ["filter"]}] = err["errors"]
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
