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

    attribute :status, AshLua.Test.Posts.Post.Status do
      default :draft
      public? true
    end

    attribute :slug, AshLua.Test.Posts.Slug do
      public? true
    end

    attribute :schedule_config, AshLua.Test.Posts.ScheduleConfig do
      public? true
    end

    attribute :metadata, :map do
      public? true

      constraints fields: [
                    priority: [type: :integer, allow_nil?: true],
                    category: [type: :string, allow_nil?: true],
                    notify: [type: :boolean, allow_nil?: true]
                  ]
    end

    attribute :content, :union do
      public? true

      constraints types: [
                    text: [
                      type: :map,
                      tag: :kind,
                      tag_value: "text",
                      constraints: [
                        fields: [
                          body: [type: :string, allow_nil?: false],
                          word_count: [type: :integer, allow_nil?: true]
                        ]
                      ]
                    ],
                    link: [
                      type: :map,
                      tag: :kind,
                      tag_value: "link",
                      constraints: [
                        fields: [
                          url: [type: :string, allow_nil?: false],
                          title: [type: :string, allow_nil?: true]
                        ]
                      ]
                    ],
                    note: [type: :string]
                  ]
    end

    attribute :coordinates, :tuple do
      public? true

      constraints fields: [
                    latitude: [type: :float, allow_nil?: false],
                    longitude: [type: :float, allow_nil?: false]
                  ]
    end
  end

  relationships do
    belongs_to :author, AshLua.Test.Posts.User do
      public? true
    end

    has_many :comments, AshLua.Test.Posts.Comment do
      public? true
    end
  end

  calculations do
    calculate :title_downcase, :string, expr(string_downcase(title)) do
      public? true
    end

    calculate :title_prefixed, :string, expr(^arg(:prefix) <> title) do
      public? true

      argument :prefix, :string do
        allow_nil? false
        default ""
      end
    end
  end

  aggregates do
    count :comment_count, :comments do
      public? true
    end
  end
end
