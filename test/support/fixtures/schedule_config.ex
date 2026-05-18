# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Test.Posts.ScheduleConfig do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :cadence, :atom do
      public? true
      constraints one_of: [:daily, :weekly, :monthly]
    end

    attribute :hour, :integer do
      public? true
      constraints min: 0, max: 23
    end
  end
end
