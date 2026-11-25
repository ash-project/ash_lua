# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Test.FieldNames.Note do
  @moduledoc false
  use Ash.Resource,
    domain: AshLua.Test.FieldNames,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshLua.Resource]

  ets do
    private? true
  end

  # `:relabel` and `:private_label` have an argument whose name is the renamed
  # field's Lua name, so the atom `:label` always exists. `:relabel` also takes
  # the field as input, so both claim the Lua name there.
  lua do
    field_names title: "label"
  end

  actions do
    defaults [:read]

    create :create do
      accept [:title]
    end

    update :relabel do
      accept [:title]
      argument :label, :string
      change set_attribute(:title, arg(:label))
    end

    create :private_label do
      accept [:title]
      argument :label, :string, public?: false
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      public? true
    end
  end
end
