# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.ActorDocsTest do
  use ExUnit.Case, async: true

  alias AshLua.Test.ActorDocs.{Agent, FilteredAgent}

  @reader %{role: :reader, name: "rita"}
  @editor %{role: :editor, name: "ed"}

  describe "with filter_docs_by_actor?" do
    test "leaves out operations the actor cannot run" do
      abridged = docs!(FilteredAgent, @reader, %{})

      assert abridged =~ "`actor_docs.post.read`"
      refute abridged =~ "actor_docs.post.create"
    end

    test "keeps operations the actor may be able to run" do
      assert docs!(FilteredAgent, @reader, %{}) =~ "`actor_docs.post.mine`"
    end

    test "documents everything an authorized actor can run" do
      abridged = docs!(FilteredAgent, @editor, %{})

      for op <- ~w(read mine create) do
        assert abridged =~ "`actor_docs.post.#{op}`"
      end
    end

    test "applies to the full page, search and name lookups" do
      refute docs!(FilteredAgent, @reader, %{name: "full"}) =~ "actor_docs.post.create"
      refute docs!(FilteredAgent, @reader, %{search: "create"}) =~ "actor_docs.post.create"

      assert {:error, %Ash.Error.Invalid{}} =
               docs(FilteredAgent, @reader, %{name: "actor_docs.post.create"})

      assert {:ok, _} = docs(FilteredAgent, @editor, %{name: "actor_docs.post.create"})
    end

    test "leaves eval authorization unchanged" do
      assert %{result: "forbidden"} = create(FilteredAgent, @reader)
      assert %{result: "created"} = create(FilteredAgent, @editor)
    end
  end

  test "without the option, every operation is documented" do
    assert docs!(Agent, @reader, %{}) =~ "`actor_docs.post.create`"
  end

  defp docs(agent, actor, input) do
    agent
    |> Ash.ActionInput.for_action(:docs, input, actor: actor)
    |> Ash.run_action()
  end

  defp docs!(agent, actor, input) do
    {:ok, doc} = docs(agent, actor, input)
    doc
  end

  defp create(agent, actor) do
    agent
    |> Ash.ActionInput.for_action(
      :eval,
      %{
        script: """
        local post, err = actor_docs.post.create({ input = { title = "Hello" } })
        if err then return err.class end
        return "created"
        """
      },
      actor: actor
    )
    |> Ash.run_action!()
  end
end
