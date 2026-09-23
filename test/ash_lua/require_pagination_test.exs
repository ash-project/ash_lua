# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.RequirePaginationTest do
  use ExUnit.Case, async: true

  alias AshLua.Test.Posts.PaginatedMCPActions
  alias AshLua.Test.Posts.Post

  setup do
    for title <- ["a", "b", "c"] do
      Ash.create!(Post, %{title: title}, authorize?: false)
    end

    :ok
  end

  defp eval(script) do
    input = Ash.ActionInput.for_action(PaginatedMCPActions, :eval, %{script: script})
    {:ok, %{result: result, error: nil}} = Ash.run_action(input)
    result
  end

  describe "require_pagination? on the eval surface" do
    test "a read without page returns a page of the default size" do
      page = eval(~s|return assert(posts.post.read({ fields = { "title" }, sort = "title" }))|)

      assert %{"more?" => true, "limit" => 2, "results" => results} = page
      assert Enum.map(results, & &1["title"]) == ["a", "b"]
    end

    test "limit and offset become the page" do
      page =
        eval(
          ~s|return assert(posts.post.read({ fields = { "title" }, sort = "title", limit = 1, offset = 2 }))|
        )

      assert %{"more?" => false, "limit" => 1, "offset" => 2, "results" => [%{"title" => "c"}]} =
               page
    end

    test "an explicit page.limit is kept" do
      page =
        eval(~s|return assert(posts.post.read({ fields = { "title" }, page = { limit = 3 } }))|)

      assert %{"limit" => 3, "results" => results} = page
      assert length(results) == 3
    end

    test "a page without a limit gets the default size" do
      page =
        eval(~s|return assert(posts.post.read({ fields = { "title" }, page = { offset = 1 } }))|)

      assert %{"limit" => 2, "offset" => 1} = page
    end

    test "reads on actions without pagination still return a list" do
      result = eval(~s|return assert(posts.post.search({ fields = { "title" } }))|)

      assert is_list(result)
      assert length(result) == 3
    end
  end

  test "reads return a flat list when pagination is not required" do
    {[result, nil], _lua} =
      AshLua.eval!(~s|return posts.post.read({ fields = { "title" } })|, otp_app: :ash_lua)

    assert length(result) == 3
  end

  describe "docs" do
    test "the index notes that pagination is required" do
      input = Ash.ActionInput.for_action(PaginatedMCPActions, :docs, %{})
      assert {:ok, doc} = Ash.run_action(input)
      assert doc =~ "Pagination is required on this surface"
      assert doc =~ "(2 unless the action sets its own)"
    end

    test "the abridged page notes that pagination is required" do
      input = Ash.ActionInput.for_action(PaginatedMCPActions, :docs, %{name: "abridged"})
      assert {:ok, doc} = Ash.run_action(input)
      assert doc =~ "Pagination is required on this surface"
    end

    test "focused pages do not repeat the note" do
      input = Ash.ActionInput.for_action(PaginatedMCPActions, :docs, %{name: "posts.post.read"})
      assert {:ok, doc} = Ash.run_action(input)
      refute doc =~ "Pagination is required on this surface"
    end
  end
end
