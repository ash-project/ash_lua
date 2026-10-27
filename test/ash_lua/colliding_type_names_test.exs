# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.CollidingTypeNamesTest do
  use ExUnit.Case, async: true

  alias AshLua.Test.CollidingTypeNames.Agent

  test "every enum's values are documented" do
    full = docs("full")

    for value <- ~w(low high legacy screening closed on_hold) do
      assert full =~ ~r/\b#{value}\b/, "#{value} is missing from the full docs"
    end
  end

  test "colliding names are qualified with their parent module" do
    assert docs("Stage.Current") =~ "# Type `Stage.Current`"
    assert docs("Stage.Current") =~ "`screening`"
    assert docs("Rating.Current") =~ "`low`"
    refute docs("Rating.Current") =~ "screening"
  end

  test "unions link to their own members" do
    stage = docs("Stage")

    assert stage =~ "[`Stage.Current`](#stage-current)"
    assert stage =~ "[`Stage.Archived`](#stage-archived)"
    refute stage =~ "(#rating-"
  end

  test "union pages list their enum members' values" do
    assert docs("Stage") =~ ~r/`Stage.Current`\]\(#stage-current\)\s*\|\s*`screening`, `closed`/
  end

  test "the abridged docs name each member unambiguously" do
    abridged = docs(nil)

    assert abridged =~ "`Stage.Current` — enum: screening | closed"
    assert abridged =~ "`Rating.Current` — enum: low | high"
  end

  test "the short name no longer resolves to one of the colliding types" do
    assert {:error, %Ash.Error.Invalid{}} =
             Agent
             |> Ash.ActionInput.for_action(:docs, %{name: "Current"})
             |> Ash.run_action()
  end

  test "the documented values are the ones the action accepts" do
    assert %{result: "created"} = create_with_stage("screening")
    assert %{result: "invalid"} = create_with_stage("low")
  end

  defp docs(name) do
    Agent
    |> Ash.ActionInput.for_action(:docs, %{name: name})
    |> Ash.run_action!()
  end

  defp create_with_stage(stage) do
    Agent
    |> Ash.ActionInput.for_action(:eval, %{
      script: """
      local deal, err = colliding_type_names.deal.create({ input = { stage = "#{stage}" } })
      if err then return err.class end
      return "created"
      """
    })
    |> Ash.run_action!()
  end
end
