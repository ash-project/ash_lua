# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.VerifiersTest do
  use ExUnit.Case, async: true

  alias AshLua.Domain.{Action, Namespace}
  alias AshLua.Test.Surface.Page

  test "resource verifier rejects field_names for missing fields" do
    dsl = put_lua_opt(Page.spark_dsl_config(), :field_names, missing: "missing")

    assert {:error, error} = AshLua.Resource.Verifiers.VerifyNames.verify(dsl)
    assert Exception.message(error) =~ "field :missing does not exist"
  end

  test "resource verifier rejects argument_names for missing arguments" do
    dsl = put_lua_opt(Page.spark_dsl_config(), :argument_names, summarize: [missing: "missing"])

    assert {:error, error} = AshLua.Resource.Verifiers.VerifyNames.verify(dsl)
    assert Exception.message(error) =~ "argument for action :summarize :missing does not exist"
  end

  test "domain verifier rejects duplicate public paths and missing actions" do
    namespace = %Namespace{
      name: "pages",
      actions: [
        %Action{name: :list, resource: Page, action: :list_for_storefront},
        %Action{name: :list, resource: Page, action: :missing}
      ]
    }

    dsl =
      put_in(AshLua.Test.Surface.spark_dsl_config(), [Access.key([:lua]), :entities], [namespace])

    assert {:error, error} = AshLua.Domain.Verifiers.VerifySurface.verify(dsl)

    message = Exception.message(error)
    assert message =~ "duplicate Lua surface path"
    assert message =~ "missing action :missing"
  end

  defp put_lua_opt(dsl, key, value) do
    put_in(dsl, [Access.key([:lua]), :opts, key], value)
  end
end
