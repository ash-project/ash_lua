# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defprotocol AshLua.Error do
  @moduledoc """
  Protocol for rendering Ash errors into the Lua-side error shape.

  Each `to_error/1` impl returns a map with these keys (all strings on the Lua side):

    * `:message` — the human-readable message to surface
    * `:short_message` — a terse variant suitable for tooltips/logs
    * `:code` — a stable, machine-readable identifier (e.g. `"invalid_argument"`, `"required"`, `"not_found"`)
    * `:fields` — list of atom field names this error relates to (may be empty)
    * `:vars` — additional template/context variables interpolatable into `message`

  Errors without an impl fall through to an opaque "unknown error" entry in the encoder.
  """
  @fallback_to_any false

  @spec to_error(term()) :: %{
          required(:message) => String.t(),
          required(:short_message) => String.t(),
          required(:code) => String.t(),
          required(:fields) => list(atom()),
          required(:vars) => map()
        }
  def to_error(exception)
end

defimpl AshLua.Error, for: Ash.Error.Changes.InvalidChanges do
  def to_error(error) do
    %{
      message: error.message,
      short_message: error.message,
      vars: Map.new(error.vars),
      code: "invalid_changes",
      fields: List.wrap(error.fields)
    }
  end
end

defimpl AshLua.Error, for: Ash.Error.Query.InvalidQuery do
  def to_error(error) do
    fields = List.wrap(error.field || Map.get(error, :fields) || [])

    %{
      message: error.message,
      short_message: error.message,
      vars: Map.new(error.vars),
      code: "invalid_query",
      fields: fields
    }
  end
end

defimpl AshLua.Error, for: Ash.Error.Query.InvalidLimit do
  def to_error(error) do
    %{
      message: "%{value} is not a valid limit",
      short_message: "invalid limit",
      code: "invalid_limit",
      vars: Map.merge(Map.new(error.vars), %{value: inspect(error.limit)}),
      fields: [:limit]
    }
  end
end

defimpl AshLua.Error, for: Ash.Error.Query.InvalidOffset do
  def to_error(error) do
    %{
      message: "%{value} is not a valid offset",
      short_message: "invalid offset",
      code: "invalid_offset",
      vars: Map.merge(Map.new(error.vars), %{value: inspect(error.offset)}),
      fields: [:offset]
    }
  end
end

defimpl AshLua.Error, for: Ash.Error.Query.InvalidPage do
  def to_error(error) do
    %{
      message: "%{value} is not a valid page option",
      short_message: "invalid page",
      code: "invalid_page",
      vars: Map.merge(Map.new(error.vars), %{value: inspect(error.page)}),
      fields: [:page]
    }
  end
end

# Query construction errors from `filter` / `sort` input. None of these reuse
# Ash's own `message/1`: on some data layers it interpolates the resource
# module or the full data-layer query (`InvalidFilterValue`'s `context`), which
# must not reach the script.

defimpl AshLua.Error, for: Ash.Error.Query.NoSuchField do
  def to_error(error) do
    AshLua.Error.Helpers.unknown_field(error, error.field)
  end
end

defimpl AshLua.Error, for: Ash.Error.Query.NoSuchAttribute do
  def to_error(error) do
    AshLua.Error.Helpers.unknown_field(error, error.attribute)
  end
end

defimpl AshLua.Error, for: Ash.Error.Query.NoSuchRelationship do
  def to_error(error) do
    AshLua.Error.Helpers.unknown_field(error, error.relationship)
  end
end

defimpl AshLua.Error, for: Ash.Error.Query.NoSuchFilterPredicate do
  def to_error(error) do
    predicate = to_string(error.key)

    %{
      message: "no such filter predicate `#{predicate}`",
      short_message: "no such filter predicate",
      code: "no_such_filter_predicate",
      vars: Map.merge(Map.new(error.vars), %{predicate: predicate}),
      fields: []
    }
  end
end

defimpl AshLua.Error, for: Ash.Error.Query.InvalidFilterValue do
  def to_error(error) do
    vars =
      error.vars
      |> Map.new()
      |> Map.put(:value, inspect(error.value))
      |> then(fn vars ->
        if is_binary(error.message), do: Map.put(vars, :detail, error.message), else: vars
      end)

    %{
      message: "invalid filter value",
      short_message: "invalid filter value",
      code: "invalid_filter_value",
      vars: vars,
      fields: AshLua.Error.Helpers.predicate_fields(error.value)
    }
  end
end

defimpl AshLua.Error, for: Ash.Error.Query.InvalidFilterReference do
  def to_error(error) do
    message =
      if error.simple_equality? do
        "cannot be referenced in filters, except by simple equality"
      else
        "cannot be referenced in filters"
      end

    %{
      message: message,
      short_message: "invalid filter reference",
      code: "invalid_filter_reference",
      vars: Map.new(error.vars),
      fields: List.wrap(error.field)
    }
  end
end

defimpl AshLua.Error, for: Ash.Error.Query.UnsortableField do
  def to_error(error) do
    %{
      message: "is not sortable",
      short_message: "unsortable field",
      code: "unsortable_field",
      vars: Map.new(error.vars),
      fields: List.wrap(error.field)
    }
  end
end

defimpl AshLua.Error, for: Ash.Error.Query.InvalidSortOrder do
  def to_error(error) do
    %{
      message: "no such sort order `%{order}`",
      short_message: "invalid sort order",
      code: "invalid_sort_order",
      vars: Map.merge(Map.new(error.vars), %{order: inspect(error.order)}),
      fields: []
    }
  end
end

defimpl AshLua.Error, for: Ash.Error.Query.NoSuchOperator do
  def to_error(error) do
    %{
      message: "no such operator `%{operator}`",
      short_message: "no such operator",
      code: "no_such_operator",
      vars: Map.merge(Map.new(error.vars), %{operator: to_string(error.operator)}),
      fields: []
    }
  end
end

defimpl AshLua.Error, for: Ash.Error.Query.NoSuchFunction do
  def to_error(error) do
    %{
      message: "no such function `%{function}`",
      short_message: "no such function",
      code: "no_such_function",
      vars:
        Map.merge(Map.new(error.vars), %{
          function: to_string(error.function),
          arity: error.arity
        }),
      fields: []
    }
  end
end

defimpl AshLua.Error, for: Ash.Error.Query.UnsupportedPredicate do
  def to_error(error) do
    %{
      message: "the data layer does not support this predicate for this field type",
      short_message: "unsupported predicate",
      code: "unsupported_predicate",
      vars: Map.merge(Map.new(error.vars), %{predicate: inspect(error.predicate)}),
      fields: []
    }
  end
end

defimpl AshLua.Error, for: Ash.Error.Invalid.NoSuchInput do
  def to_error(error) do
    input = to_string(error.input)

    %{
      message: "no such input `#{input}`",
      short_message: "no such input",
      code: "no_such_input",
      vars:
        Map.merge(Map.new(error.vars), %{
          name: input,
          did_you_mean: Enum.map(error.did_you_mean || [], &to_string/1)
        }),
      fields: [error.input]
    }
  end
end

defimpl AshLua.Error, for: Ash.Error.Page.InvalidKeyset do
  def to_error(error) do
    %{
      message: "Invalid value provided as a keyset for %{key}: %{value}",
      short_message: "invalid keyset",
      code: "invalid_keyset",
      vars: Map.merge(Map.new(error.vars), %{value: inspect(error.value), key: error.key}),
      fields: List.wrap(Map.get(error, :key))
    }
  end
end

defimpl AshLua.Error, for: Ash.Error.Changes.InvalidAttribute do
  def to_error(error) do
    %{
      message: error.message,
      short_message: error.message,
      code: "invalid_attribute",
      vars: Map.new(error.vars),
      fields: [error.field]
    }
  end
end

defimpl AshLua.Error, for: Ash.Error.Changes.InvalidArgument do
  def to_error(error) do
    %{
      message: error.message,
      short_message: error.message,
      code: "invalid_argument",
      vars: Map.new(error.vars),
      fields: [error.field]
    }
  end
end

defimpl AshLua.Error, for: Ash.Error.Query.InvalidArgument do
  def to_error(error) do
    %{
      message: error.message,
      short_message: error.message,
      code: "invalid_argument",
      vars: Map.new(error.vars),
      fields: [error.field]
    }
  end
end

defimpl AshLua.Error, for: Ash.Error.Action.InvalidArgument do
  def to_error(error) do
    %{
      message: error.message,
      short_message: error.message,
      code: "invalid_argument",
      vars: Map.new(error.vars),
      fields: [error.field]
    }
  end
end

defimpl AshLua.Error, for: Ash.Error.Changes.Required do
  def to_error(error) do
    %{
      message: "is required",
      short_message: "is required",
      code: "required",
      vars: error.vars,
      fields: [error.field]
    }
  end
end

defimpl AshLua.Error, for: Ash.Error.Query.NotFound do
  def to_error(error) do
    %{
      message: "could not be found",
      short_message: "could not be found",
      code: "not_found",
      fields: Map.keys(error.primary_key || %{}),
      vars: error.vars
    }
  end
end

defimpl AshLua.Error, for: Ash.Error.Query.Required do
  def to_error(error) do
    %{
      message: "is required",
      short_message: "is required",
      code: "required",
      vars: error.vars,
      fields: [error.field]
    }
  end
end

defimpl AshLua.Error, for: Ash.Error.Forbidden.Policy do
  def to_error(error) do
    message =
      if Application.get_env(:ash_lua, :policies)[:show_policy_breakdowns?] || false do
        Ash.Error.Forbidden.Policy.report(error, help_text?: false)
      else
        "forbidden"
      end

    %{
      message: message,
      short_message: "forbidden",
      vars: Map.new(error.vars),
      code: "forbidden",
      fields: []
    }
  end
end

defimpl AshLua.Error, for: Ash.Error.Forbidden.ForbiddenField do
  def to_error(_error) do
    %{
      message: "forbidden field",
      short_message: "forbidden field",
      vars: %{},
      code: "forbidden_field",
      fields: []
    }
  end
end

defimpl AshLua.Error, for: Ash.Error.Query.ReadActionRequiresActor do
  def to_error(_error) do
    %{
      message: "forbidden",
      short_message: "forbidden",
      vars: %{},
      code: "forbidden",
      fields: []
    }
  end
end

defimpl AshLua.Error, for: Ash.Error.Invalid.InvalidPrimaryKey do
  def to_error(error) do
    %{
      message: "invalid primary key provided",
      short_message: "invalid primary key provided",
      fields: [],
      code: "invalid_primary_key",
      vars: Map.new(error.vars)
    }
  end
end

if Code.ensure_loaded?(AshAuthentication.Errors.AuthenticationFailed) do
  defimpl AshLua.Error, for: AshAuthentication.Errors.AuthenticationFailed do
    def to_error(_error) do
      %{
        message: "Authentication failed",
        short_message: "Authentication failed",
        fields: [],
        code: "authentication_failed",
        vars: %{}
      }
    end
  end
end

if Code.ensure_loaded?(AshAuthentication.Errors.InvalidToken) do
  defimpl AshLua.Error, for: AshAuthentication.Errors.InvalidToken do
    def to_error(_error) do
      %{
        message: "An invalid token was presented",
        short_message: "Invalid token",
        fields: [],
        code: "invalid_token",
        vars: %{}
      }
    end
  end
end

defmodule AshLua.Error.Helpers do
  @moduledoc false

  # A reference to a field that does not exist, whether it came from `fields`,
  # `filter`, or `sort`. Shares the `unknown_field` code with the field
  # selection layer so scripts see one code for "you named a field that isn't
  # there"; `vars.path` says which reserved key it was in.
  @spec unknown_field(struct(), atom() | String.t()) :: map()
  def unknown_field(error, name) do
    name_string = to_string(name)

    vars =
      error.vars
      |> Map.new()
      |> Map.put(:name, name_string)
      |> then(fn vars ->
        case error.path do
          [] -> vars
          path -> Map.put(vars, :path, Enum.map(path, &to_string/1))
        end
      end)

    %{
      message: "unknown field `#{name_string}`",
      short_message: "unknown field",
      code: "unknown_field",
      vars: vars,
      fields: [name]
    }
  end

  # `InvalidFilterValue.value` is usually the offending predicate; pull the
  # referenced field out of it when it has one so the error can be shown
  # next to that field.
  @spec predicate_fields(term()) :: [atom()]
  def predicate_fields(%{left: %Ash.Query.Ref{} = ref}), do: ref_fields(ref)
  def predicate_fields(%{arguments: [%Ash.Query.Ref{} = ref | _]}), do: ref_fields(ref)
  def predicate_fields(_), do: []

  defp ref_fields(%Ash.Query.Ref{attribute: %{name: name}}) when is_atom(name), do: [name]
  defp ref_fields(%Ash.Query.Ref{attribute: name}) when is_atom(name), do: [name]
  defp ref_fields(_), do: []
end
