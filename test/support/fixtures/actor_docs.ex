# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# A surface whose policies differ per actor: anyone may read, reading your own
# posts is a filter check, and only editors may create.
defmodule AshLua.Test.ActorDocs do
  @moduledoc false
  use Ash.Domain, otp_app: :ash_lua_actor_docs, validate_config_inclusion?: false

  resources do
    resource AshLua.Test.ActorDocs.Post
    resource AshLua.Test.ActorDocs.Agent
    resource AshLua.Test.ActorDocs.FilteredAgent
  end
end

defmodule AshLua.Test.ActorDocs.Post do
  @moduledoc false
  use Ash.Resource,
    domain: AshLua.Test.ActorDocs,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer]

  ets do
    private? true
  end

  actions do
    defaults [:read, create: [:title, :author]]

    read :mine
  end

  policies do
    policy action(:read) do
      authorize_if always()
    end

    policy action(:mine) do
      authorize_if expr(author == ^actor(:name))
    end

    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :editor)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true
    attribute :author, :string, public?: true
  end
end

defmodule AshLua.Test.ActorDocs.Agent do
  @moduledoc false
  use Ash.Resource,
    domain: AshLua.Test.ActorDocs,
    extensions: [AshLua.EvalActions]

  eval_actions do
    resource AshLua.Test.ActorDocs.Post, actions: [:read, :mine, :create]
  end
end

defmodule AshLua.Test.ActorDocs.FilteredAgent do
  @moduledoc false
  use Ash.Resource,
    domain: AshLua.Test.ActorDocs,
    extensions: [AshLua.EvalActions]

  eval_actions do
    filter_docs_by_actor? true
    resource AshLua.Test.ActorDocs.Post, actions: [:read, :mine, :create]
  end
end
