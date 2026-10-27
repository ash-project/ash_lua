# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Two unions whose enum members share module basenames (`Rating.Current` and
# `Stage.Current`), which Ash's manifest names identically.
defmodule AshLua.Test.CollidingTypeNames.Rating do
  @moduledoc false
  defmodule Current do
    @moduledoc false
    use Ash.Type.Enum, values: [:low, :high]
  end

  defmodule Archived do
    @moduledoc false
    use Ash.Type.Enum, values: [:legacy]
  end

  use Ash.Type.NewType,
    subtype_of: :union,
    constraints: [
      types: [current: [type: __MODULE__.Current], archived: [type: __MODULE__.Archived]]
    ]
end

defmodule AshLua.Test.CollidingTypeNames.Stage do
  @moduledoc false
  defmodule Current do
    @moduledoc false
    use Ash.Type.Enum, values: [:screening, :closed]
  end

  defmodule Archived do
    @moduledoc false
    use Ash.Type.Enum, values: [:on_hold]
  end

  use Ash.Type.NewType,
    subtype_of: :union,
    constraints: [
      types: [current: [type: __MODULE__.Current], archived: [type: __MODULE__.Archived]]
    ]
end

defmodule AshLua.Test.CollidingTypeNames do
  @moduledoc false
  use Ash.Domain, otp_app: :ash_lua_colliding_type_names, validate_config_inclusion?: false

  resources do
    resource AshLua.Test.CollidingTypeNames.Deal
    resource AshLua.Test.CollidingTypeNames.Agent
  end
end

defmodule AshLua.Test.CollidingTypeNames.Deal do
  @moduledoc false
  use Ash.Resource,
    domain: AshLua.Test.CollidingTypeNames,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  actions do
    defaults [:read, create: [:rating, :stage]]
  end

  attributes do
    uuid_primary_key :id
    attribute :rating, AshLua.Test.CollidingTypeNames.Rating, public?: true
    attribute :stage, AshLua.Test.CollidingTypeNames.Stage, public?: true
  end
end

defmodule AshLua.Test.CollidingTypeNames.Agent do
  @moduledoc false
  use Ash.Resource,
    domain: AshLua.Test.CollidingTypeNames,
    extensions: [AshLua.EvalActions]

  eval_actions do
    resource AshLua.Test.CollidingTypeNames.Deal, actions: [:read, :create]
  end
end
