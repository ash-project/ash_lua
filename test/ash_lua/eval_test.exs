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

    assert [%{"code" => "lua_error"} | _] = err["errors"]
    assert err["message"] =~ "instruction budget exceeded"
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
