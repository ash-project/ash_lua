# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Test.Posts.User do
  @moduledoc false
  use Ash.Resource,
    domain: AshLua.Test.Posts,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshLua.Resource]

  ets do
    private? true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :email, :string do
      public? true
    end
  end

  relationships do
    has_many :posts, AshLua.Test.Posts.Post do
      destination_attribute :author_id
      public? true
    end
  end
end
