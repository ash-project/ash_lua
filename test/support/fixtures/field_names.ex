# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Test.FieldNames do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshLua.Test.FieldNames.Note
  end
end
