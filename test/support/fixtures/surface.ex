# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Test.Surface do
  @moduledoc false
  use Ash.Domain,
    otp_app: :ash_lua,
    extensions: [AshLua.Domain]

  lua do
    namespace "surface" do
      action :page_create, AshLua.Test.Surface.Page, :create, labels: [:public, :writes]

      action :page_list, AshLua.Test.Surface.Page, :list_for_storefront,
        labels: [:public, :read_model]

      action :page_rename, AshLua.Test.Surface.Page, :rename, labels: [:public, :writes]
      action :page_summarize, AshLua.Test.Surface.Page, :summarize, labels: [:public]
    end

    namespace "surface.admin" do
      action :page_rename, AshLua.Test.Surface.Page, :rename, labels: [:admin, :writes]
    end
  end

  resources do
    resource AshLua.Test.Surface.Page
    resource AshLua.Test.Surface.MCPActions
    resource AshLua.Test.Surface.MultiLabelMCPActions
  end
end
