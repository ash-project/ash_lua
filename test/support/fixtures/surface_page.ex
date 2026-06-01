# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Test.Surface.Page do
  @moduledoc false
  use Ash.Resource,
    domain: AshLua.Test.Surface,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshLua.Resource]

  ets do
    private? true
  end

  lua do
    field_names title: "headline", featured?: "featured"
    argument_names(summarize: [title_text: "headlineText"])
  end

  actions do
    create :create do
      primary? true
      accept [:title, :featured?]
    end

    read :list_for_storefront do
      primary? true
    end

    update :rename do
      accept [:title, :featured?]
    end

    action :summarize, :string do
      argument :title_text, :string do
        allow_nil? false
      end

      run fn input, _context ->
        {:ok, "summary: " <> input.arguments.title_text}
      end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :featured?, :boolean do
      default false
      public? true
    end
  end
end
