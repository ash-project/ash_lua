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
      action :page_create, AshLua.Test.Surface.Page, :create
      action :page_list, AshLua.Test.Surface.Page, :list_for_storefront
      action :page_rename, AshLua.Test.Surface.Page, :rename
      action :page_summarize, AshLua.Test.Surface.Page, :summarize
    end
  end

  resources do
    resource AshLua.Test.Surface.Page
    resource AshLua.Test.Surface.MCPActions
  end
end
