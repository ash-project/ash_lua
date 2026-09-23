# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Test.Colliding do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshLua.Test.Colliding.Invoice.Item
    resource AshLua.Test.Colliding.Subscription.Item
    resource AshLua.Test.Colliding.Renamed.Item
  end
end

defmodule AshLua.Test.Colliding.Invoice.Item do
  @moduledoc false
  use Ash.Resource, domain: AshLua.Test.Colliding, data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read]
  end

  attributes do
    uuid_primary_key :id
  end
end

defmodule AshLua.Test.Colliding.Subscription.Item do
  @moduledoc false
  use Ash.Resource, domain: AshLua.Test.Colliding, data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read]
  end

  attributes do
    uuid_primary_key :id
  end
end

defmodule AshLua.Test.Colliding.Renamed.Item do
  @moduledoc false
  use Ash.Resource,
    domain: AshLua.Test.Colliding,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshLua.Resource]

  lua do
    name "renamed_item"
  end

  actions do
    defaults [:read]
  end

  attributes do
    uuid_primary_key :id
  end
end
