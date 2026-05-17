# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Test.Posts.Post do
  @moduledoc false
  use Ash.Resource,
    domain: AshLua.Test.Posts,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshLua.Resource]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :body, :string do
      public? true
    end

    attribute :published, :boolean do
      default false
      public? true
    end
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    update :publish do
      accept []
      change set_attribute(:published, true)
    end

    action :word_count, :integer do
      argument :text, :string, allow_nil?: false

      run fn input, _context ->
        count =
          input.arguments.text
          |> String.split(~r/\s+/, trim: true)
          |> Enum.count()

        {:ok, count}
      end
    end
  end
end
