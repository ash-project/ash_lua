# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Errors.FieldsError do
  @moduledoc """
  An error raised during field-selection parsing / validation, carrying the
  user-facing message, stable code, and any field names + interpolation
  context the throw site knew about.

  The `AshLua.Error` protocol impl unwraps this directly to the standard
  error shape — no central switch over internal tags.
  """

  @type t :: %__MODULE__{
          message: String.t(),
          short_message: String.t(),
          code: String.t(),
          fields: [String.t()],
          vars: map()
        }

  defexception [
    :message,
    :short_message,
    :code,
    fields: [],
    vars: %{}
  ]

  @impl true
  def message(%__MODULE__{message: m}), do: m
end

defimpl AshLua.Error, for: AshLua.Errors.FieldsError do
  def to_error(%AshLua.Errors.FieldsError{} = err) do
    %{
      message: err.message,
      short_message: err.short_message || err.message,
      code: err.code,
      fields: err.fields,
      vars: err.vars
    }
  end
end
