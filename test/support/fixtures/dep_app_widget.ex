# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Test.DepApp.Widget do
  @moduledoc false
  use Ash.Resource,
    domain: AshLua.Test.DepApp,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshLua.Resource]

  ets do
    private? true
  end

  actions do
    defaults [:read, create: [:name]]
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      public? true
    end
  end
end
