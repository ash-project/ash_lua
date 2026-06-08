# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Type do
  @moduledoc """
  Extends an Ash type with Lua-facing metadata and encoding.

  Add `use AshLua.Type` to a custom type module (typically alongside
  `use Ash.Type` or `use Ash.Type.NewType`) and implement any of the optional
  callbacks.

  ## `type_name/0`

  Controls the name surfaced in generated documentation (`AshLua.Docs`) for
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

  ## `to_lua/2`

  Controls how a value of this type is encoded for the Lua side. Return any
  Lua-friendly value (maps/lists/strings/numbers/booleans/nil) — it is run
  through the standard normalization afterwards, so nested `Decimal`/`Date`/
  etc. are still handled for you.

      defmodule MyApp.Money do
        use Ash.Type.NewType, subtype_of: :integer
        use AshLua.Type

        @impl AshLua.Type
        def to_lua(cents, _constraints) do
          %{"cents" => cents}
        end
      end

  When a type does not implement `to_lua/2`, AshLua falls back to its built-in
  defaults: special handling for the Ash builtin types that need it (CiString,
  Decimal, dates/times, durations), and a plain JSON-style encoding for
  everything else.
  """

  @callback type_name() :: String.t()
  @callback to_lua(value :: term(), constraints :: Keyword.t()) :: term()
  @optional_callbacks type_name: 0, to_lua: 2

  defmacro __using__(_opts) do
    quote do
      @behaviour AshLua.Type
    end
  end

  @doc """
  Encodes a value using the type module's `to_lua/2` callback, if it defines one.

  Returns `{:ok, encoded}` when the module implements `to_lua/2`, or `:default`
  when it doesn't — letting the caller fall back to built-in encoding.
  """
  @spec to_lua(module() | nil, term(), Keyword.t()) :: {:ok, term()} | :default
  def to_lua(module, value, constraints) when is_atom(module) and not is_nil(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :to_lua, 2) do
      {:ok, module.to_lua(value, constraints)}
    else
      :default
    end
  end

  def to_lua(_module, _value, _constraints), do: :default

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
