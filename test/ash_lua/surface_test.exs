# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.SurfaceTest do
  use ExUnit.Case, async: false

  alias AshLua.Test.Surface.MCPActions
  alias AshLua.Test.Surface.Page

  defp opts, do: [otp_app: :ash_lua]

  test "surface metadata is stored on manifest entrypoints" do
    assert {:ok, %Ash.Info.Manifest{} = manifest} = AshLua.Surface.for_otp_app(:ash_lua)
    assert {:ok, entrypoint} = AshLua.Surface.find_entrypoint(manifest, "surface.page_list")

    assert entrypoint.config.ash_lua.path == ["surface", "page_list"]
    assert entrypoint.config.ash_lua.path_string == "surface.page_list"
    assert entrypoint.config.ash_lua.path_source == :explicit
  end

  test "domain lua namespace exposes public action paths" do
    title = unique_title("Landing")
    {:ok, _page} = Ash.create(Page, %{title: title}, action: :create)

    script = """
    local rows = assert(surface.page_list({
      fields = { "id", "headline", "featured" },
      filter = { headline = "#{title}", featured = false },
      sort = "headline"
    }))

    return rows[1]
    """

    {[record], _lua} = AshLua.eval!(script, opts())

    record = Map.new(record)

    assert record["headline"] == title
    assert record["featured"] == false
    assert is_binary(record["id"])
    refute Map.has_key?(record, "title")
    refute Map.has_key?(record, "featured?")
  end

  test "domain explicit surface does not expose legacy resource/action paths" do
    callables = AshLua.Docs.list_callables(opts())

    assert "surface.page_list" in callables
    assert "surface.page_create" in callables
    assert "surface.page_rename" in callables
    assert "surface.page_summarize" in callables
    refute "pages.list" in callables
    refute "surface.page.list_for_storefront" in callables
    refute "surface.page.rename" in callables
  end

  test "docs render public surface paths" do
    {:ok, md} = AshLua.Docs.callable_doc(opts(), "surface.page_list")

    assert md =~ "# `surface.page_list`"
    assert md =~ "**Operation:** `list`"
    assert md =~ "A list of [`surface.page`](#surface-page) records."
    refute md =~ "list_for_storefront"
  end

  test "field_names rewrite input fields and output keys" do
    title = unique_title("Before")
    renamed = unique_title("After")
    {:ok, page} = Ash.create(Page, %{title: title}, action: :create)

    script = """
     local page = assert(surface.page_rename({
       input = {
         id = "#{page.id}",
         headline = "#{renamed}",
         featured = true
       },
       fields = { "id", "headline", "featured" }
     }))

    return page
    """

    {[record], _lua} = AshLua.eval!(script, opts())

    record = Map.new(record)

    assert record["id"] == page.id
    assert record["headline"] == renamed
    assert record["featured"] == true
    refute Map.has_key?(record, "title")
    refute Map.has_key?(record, "featured?")
  end

  test "argument_names rewrite generic action inputs" do
    script = """
    return assert(surface.page_summarize({
      input = { headlineText = "About" }
    }))
    """

    {[result, nil], _lua} = AshLua.eval!(script, opts())

    assert result == "summary: About"
  end

  test "explicit surface action inputs must be nested under input" do
    script = """
    local _result, err = surface.page_summarize({ headlineText = "About" })

    return err.errors[1].code, err.errors[1].fields[1]
    """

    {[code, field], _lua} = AshLua.eval!(script, opts())

    assert code == "invalid_input_shape"
    assert field == "headlineText"
  end

  test "docs use field_names in resource-facing rows" do
    {:ok, callable_md} = AshLua.Docs.callable_doc(opts(), "surface.page_rename")
    {:ok, type_md} = AshLua.Docs.type_doc(opts(), "surface.page")

    assert callable_md =~ "| `input` | table | yes |"
    assert callable_md =~ "| `input.headline` |"
    assert callable_md =~ "| `input.featured` |"
    refute callable_md =~ "| `title` |"
    refute callable_md =~ "| `featured?` |"

    assert type_md =~ "| `headline` | `string`"
    assert type_md =~ "| `featured` | `boolean`"
    assert type_md =~ "### `headline` (`string`)"
    assert type_md =~ "- `headline`"
    refute type_md =~ "| `title` |"
    refute type_md =~ "| `featured?` |"

    {:ok, generic_md} = AshLua.Docs.callable_doc(opts(), "surface.page_summarize")
    assert generic_md =~ "| `input.headlineText` | `string` | yes"
    refute generic_md =~ "| `title_text` |"
  end

  test "Ash errors rewrite field names back to Lua names" do
    script = """
    local _page, err = surface.page_create({
      fields = { "headline" }
    })

    return err.errors[1].fields[1]
    """

    {[field], _lua} = AshLua.eval!(script, opts())

    assert field == "headline"
  end

  test "eval_actions scopes to the resolved public surface" do
    title = unique_title("Eval")
    {:ok, _page} = Ash.create(Page, %{title: title}, action: :create)

    input =
      Ash.ActionInput.for_action(MCPActions, :eval, %{
        script: """
        local rows = assert(surface.page_list({
          fields = { "headline" },
          filter = { headline = "#{title}" }
        }))

        return rows[1].headline
        """
      })

    assert {:ok, %{result: ^title, error: nil}} = Ash.run_action(input)
  end

  test "eval_actions map field_names through returned records" do
    title = unique_title("Eval Record")
    {:ok, _page} = Ash.create(Page, %{title: title}, action: :create)

    input =
      Ash.ActionInput.for_action(MCPActions, :eval, %{
        script: """
        local rows = assert(surface.page_list({
          fields = { "headline", "featured" },
          filter = { headline = "#{title}", featured = false },
          sort = "headline"
        }))

        return rows
        """
      })

    assert {:ok, %{result: [record], error: nil}} = Ash.run_action(input)

    assert record["headline"] == title
    assert record["featured"] == false
    refute Map.has_key?(record, "title")
    refute Map.has_key?(record, "featured?")
  end

  test "eval_actions docs index uses public paths" do
    input = Ash.ActionInput.for_action(MCPActions, :docs, %{})

    assert {:ok, md} = Ash.run_action(input)
    assert md =~ "- `surface.page_list`"
    assert md =~ "- `surface.page_rename`"
    assert md =~ "- `surface.page_summarize`"
    assert md =~ "- `surface.page`"
    assert md =~ ~s(name = "full")
    refute md =~ "surface.page.list_for_storefront"
  end

  test "eval_actions docs resolve field_names on focused pages" do
    callable_input = Ash.ActionInput.for_action(MCPActions, :docs, %{name: "surface.page_rename"})
    type_input = Ash.ActionInput.for_action(MCPActions, :docs, %{name: "surface.page"})

    assert {:ok, callable_md} = Ash.run_action(callable_input)
    assert callable_md =~ "# `surface.page_rename`"
    assert callable_md =~ "| `input` | table | yes |"
    assert callable_md =~ "| `input.headline` |"
    assert callable_md =~ "| `input.featured` |"
    refute callable_md =~ "| `title` |"

    assert {:ok, type_md} = Ash.run_action(type_input)
    assert type_md =~ "# Record type `surface.page`"
    assert type_md =~ "| `headline` | `string`"
    assert type_md =~ "| `featured` | `boolean`"
    refute type_md =~ "| `featured?` |"

    generic_input =
      Ash.ActionInput.for_action(MCPActions, :docs, %{name: "surface.page_summarize"})

    assert {:ok, generic_md} = Ash.run_action(generic_input)
    assert generic_md =~ "| `input.headlineText` | `string` | yes"
    refute generic_md =~ "| `title_text` |"
  end

  defp unique_title(prefix) do
    "#{prefix} #{System.unique_integer([:positive])}"
  end
end
