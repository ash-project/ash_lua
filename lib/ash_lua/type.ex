# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Type do
  @moduledoc """
  Extends an Ash type with Lua-facing metadata.

  Add `use AshLua.Type` to a custom type module (typically alongside
  `use Ash.Type` or `use Ash.Type.NewType`) and implement `type_name/0` to
  control the name surfaced in generated documentation (`AshLua.Docs`) for
  that type.

      defmodule MyApp.Slug do
        use Ash.Type.NewType, subtype_of: :string
        use AshLua.Type

        @impl AshLua.Type
        def type_name, do: "slug"
      end

  When a module does not implement `type_name/0`, the default name is derived
  from the module itself: the last module segment, with `Ash.Type.` prefixed
  modules underscored (`Ash.Type.UUID` → `"uuid"`, `Ash.Type.Boolean` →
  `"boolean"`).
  """

  @callback type_name() :: String.t()
  @optional_callbacks type_name: 0

  defmacro __using__(_opts) do
    quote do
      @behaviour AshLua.Type
    end
  end

  @doc """
  Returns the Lua-facing type name for the given module.

  Uses the module's `type_name/0` callback when defined, otherwise derives
  a name from the module itself.
  """
  @spec type_name(module()) :: String.t()
  def type_name(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :type_name, 0) do
      module.type_name()
    else
      default_type_name(module)
    end
  end

  defp default_type_name(module) do
    case Atom.to_string(module) do
      "Elixir.Ash.Type." <> rest -> Macro.underscore(rest)
      _ -> module |> Module.split() |> List.last()
    end
  end
end
