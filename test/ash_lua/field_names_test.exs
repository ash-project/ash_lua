# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.FieldNamesTest do
  use ExUnit.Case, async: true

  alias AshLua.FieldNames
  alias AshLua.Test.FieldNames.Note
  alias AshLua.Test.Surface.Page

  # Makes an atom at runtime. A literal `String.to_atom("...")` is folded into
  # this module's atom table, so that atom would exist before any test ran.
  defp make_atom(parts), do: parts |> Enum.join() |> String.to_atom()

  defp action(resource, name), do: Ash.Resource.Info.action(resource, name)

  describe "to_internal_action_input/3" do
    test "a field_names rename applies when an atom with the Lua name exists" do
      _ = make_atom(["head", "line"])

      assert FieldNames.to_internal_action_input(Page, action(Page, :rename), %{
               "headline" => "x",
               "featured" => true
             }) == %{"title" => "x", "featured?" => true}
    end

    test "a field_names rename applies when another action has an argument of that name" do
      assert FieldNames.to_internal_action_input(Note, action(Note, :create), %{"label" => "x"}) ==
               %{"title" => "x"}
    end

    test "an argument keeps the key on an action that also takes the renamed field" do
      assert FieldNames.to_internal_action_input(Note, action(Note, :relabel), %{"label" => "x"}) ==
               %{"label" => "x"}
    end

    test "a private argument does not take the key from the renamed field" do
      assert FieldNames.to_internal_action_input(Note, action(Note, :private_label), %{
               "label" => "x"
             }) == %{"title" => "x"}
    end

    test "an action given without its arguments is looked up" do
      _ = make_atom(["head", "line"])

      assert FieldNames.to_internal_action_input(Page, %{name: :rename, type: :update}, %{
               "headline" => "x"
             }) == %{"title" => "x"}

      assert FieldNames.to_internal_action_input(Page, %{name: :summarize, type: :action}, %{
               "headlineText" => "a"
             }) == %{"title_text" => "a"}
    end

    test "an argument_names rename and the argument's own name both map to the argument" do
      summarize = action(Page, :summarize)

      assert FieldNames.to_internal_action_input(Page, summarize, %{"headlineText" => "a"}) ==
               %{"title_text" => "a"}

      assert FieldNames.to_internal_action_input(Page, summarize, %{"title_text" => "a"}) ==
               %{"title_text" => "a"}
    end

    test "a field's own name and an unknown key pass through" do
      assert FieldNames.to_internal_action_input(Page, action(Page, :rename), %{
               "title" => "x",
               "nope" => 1
             }) == %{"title" => "x", "nope" => 1}
    end
  end

  describe "to_internal_argument_name/3" do
    test "maps an argument_names name and an argument's own name to the argument" do
      assert FieldNames.to_internal_argument_name(Page, :summarize, "headlineText") == :title_text
      assert FieldNames.to_internal_argument_name(Page, :summarize, "title_text") == :title_text
    end

    test "leaves a name that is no public argument's name as a string, whatever atoms exist" do
      _ = make_atom(["head", "line"])

      assert FieldNames.to_internal_argument_name(Page, :rename, "headline") == "headline"
      assert FieldNames.to_internal_argument_name(Note, :private_label, "label") == "label"
      assert FieldNames.to_internal_argument_name(Page, :missing, "headline") == "headline"
    end
  end

  describe "to_internal_input/3" do
    test "a field_names rename applies when an atom with the Lua name exists" do
      _ = make_atom(["head", "line"])

      assert FieldNames.to_internal_input(Page, action(Page, :list_for_storefront), %{
               "headline" => "x",
               "limit" => 1
             }) == %{"title" => "x", "limit" => 1}
    end
  end
end
