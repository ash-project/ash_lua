# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.ForbiddenFieldsTest do
  use ExUnit.Case, async: false

  alias AshLua.Encoder
  alias AshLua.Test.Posts.ForbiddenDisplayMCPActions
  alias AshLua.Test.Posts.SecretPost

  @read_secret """
  local r = assert(posts.secret_post.read({ fields = { "title", "secret" } }))
  return r[1]
  """

  setup do
    {:ok, post} =
      Ash.create(SecretPost, %{title: "T", secret: "shh"}, action: :create, authorize?: false)

    %{post: post}
  end

  describe "Encoder forbidden-field mode" do
    test "defaults to hiding (rendering as nil)" do
      forbidden = %Ash.ForbiddenField{field: :secret, type: :attribute}

      assert Encoder.encode_result(forbidden) == nil
      assert Encoder.encode_result(forbidden, :hide) == nil
    end

    test ":display renders the opaque forbidden marker" do
      forbidden = %Ash.ForbiddenField{field: :secret, type: :attribute}

      assert Encoder.encode_result(forbidden, :display) == %{"opaque" => "forbidden"}
    end

    test "restores the previous mode after encoding (no process-dict leak)" do
      # An inner :display encode must not change what a subsequent default
      # (hide) encode does.
      assert Encoder.encode_result(%Ash.ForbiddenField{field: :x, type: :attribute}, :display) ==
               %{"opaque" => "forbidden"}

      assert Encoder.encode_result(%Ash.ForbiddenField{field: :x, type: :attribute}) == nil
    end
  end

  describe "AshLua.eval!/2 :forbidden_fields option" do
    test "hides forbidden fields by default" do
      {[record], _lua} = AshLua.eval!(@read_secret, otp_app: :ash_lua, actor: nil)

      record = Map.new(record)
      assert record["title"] == "T"
      refute Map.has_key?(record, "secret")
    end

    test ":display surfaces forbidden fields as the opaque marker" do
      {[record], _lua} =
        AshLua.eval!(@read_secret, otp_app: :ash_lua, actor: nil, forbidden_fields: :display)

      record = Map.new(record)
      assert record["title"] == "T"
      assert Map.new(record["secret"]) == %{"opaque" => "forbidden"}
    end

    test "an authorized actor sees the real value regardless of mode" do
      {[record], _lua} =
        AshLua.eval!(@read_secret,
          otp_app: :ash_lua,
          actor: %{admin: true},
          forbidden_fields: :display
        )

      assert Map.new(record)["secret"] == "shh"
    end

    test "rejects an invalid :forbidden_fields value" do
      assert_raise ArgumentError, ~r/:forbidden_fields must be :hide or :display/, fn ->
        AshLua.eval!("return 1", otp_app: :ash_lua, forbidden_fields: :nonsense)
      end
    end
  end

  describe "eval_actions forbidden_fields DSL option" do
    test ":display surface renders forbidden fields as the opaque marker" do
      input =
        Ash.ActionInput.for_action(ForbiddenDisplayMCPActions, :eval, %{script: @read_secret})

      assert {:ok, %{result: result, error: nil}} = Ash.run_action(input)
      assert result == %{"title" => "T", "secret" => %{"opaque" => "forbidden"}}
    end
  end

  describe ":docs action annotates protected fields" do
    test "fields covered by a field policy are flagged; unprotected ones are not" do
      input = Ash.ActionInput.for_action(ForbiddenDisplayMCPActions, :docs, %{name: "full"})

      assert {:ok, doc} = Ash.run_action(input)

      secret_row = doc_line(doc, "| `secret`")
      title_row = doc_line(doc, "| `title`")

      assert secret_row =~ "may be hidden by authorization"
      refute title_row =~ "may be hidden by authorization"
    end
  end

  defp doc_line(doc, prefix) do
    doc
    |> String.split("\n")
    |> Enum.find("", &String.starts_with?(String.trim_leading(&1), prefix))
  end
end
