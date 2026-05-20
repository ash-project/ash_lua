# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Test.Posts.MnesiaNote do
  @moduledoc false
  use Ash.Resource,
    domain: AshLua.Test.Posts,
    data_layer: Ash.DataLayer.Mnesia,
    extensions: [AshLua.Resource]

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    uuid_primary_key :id

    attribute :body, :string do
      allow_nil? false
      public? true
    end
  end
end
