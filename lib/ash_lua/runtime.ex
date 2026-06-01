# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Runtime do
  @moduledoc """
  Builds a Lua VM with Ash action bindings derived from `Ash.Info.Manifest.generate/1` and
  dispatches calls through to Ash with consistent actor / tenant / context plumbing.

  ## Lua surface

      local user, err = accounts.user.create({ name = "Zach" })
      assert(accounts.todo.complete({ id = todo.id }))      -- raises on error

  Action callables always return `(result, nil)` on success and `(nil, err_table)` on failure;
  wrap a call in `assert()` for raise semantics.

  Actor, tenant, and context are host-supplied via the eval opts and are never reflected to or
  mutable from the script.
  """

  alias Ash.Info.Manifest
  alias AshLua.Encoder

  @private_key :ash_lua

  @doc """
  Builds a `%Lua{}` VM with Ash bindings installed.

  ## Options

    * `:otp_app` (required) — passed through to `Ash.Info.Manifest.generate/1`.
    * `:actor`, `:tenant`, `:context` — host-supplied; merged into every Ash call.
    * `:manifest` — pre-built `%Ash.Info.Manifest{}` (skips regeneration).
    * `:lua` — pre-built `%Lua{}` to install bindings on. Defaults to `Lua.new/0`.
  """
  @spec build(keyword()) :: Lua.t()
  def build(opts) do
    opts = Keyword.validate!(opts, [:otp_app, :actor, :tenant, :context, :manifest, :lua])

    manifest =
      case Keyword.fetch(opts, :manifest) do
        {:ok, %Manifest{} = m} ->
          AshLua.Surface.for_manifest(m)

        :error ->
          otp_app = Keyword.fetch!(opts, :otp_app)
          {:ok, m} = AshLua.Surface.for_otp_app(otp_app)
          m
      end

    lua = Keyword.get(opts, :lua) || Lua.new()

    private = %{
      actor: Keyword.get(opts, :actor),
      tenant: Keyword.get(opts, :tenant),
      context: Keyword.get(opts, :context, %{}),
      print_output: []
    }

    lua
    |> Lua.put_private(@private_key, private)
    |> install_print_capture()
    |> install_surface(manifest)
    |> install_utils(manifest)
  end

  @doc """
  Returns the lines captured from Lua `print(...)` calls since the VM was
  built, in call order.
  """
  @spec print_output(Lua.t()) :: [String.t()]
  def print_output(%Lua{} = lua) do
    case Lua.get_private(lua, @private_key) do
      {:ok, %{print_output: lines}} when is_list(lines) -> lines
      _ -> []
    end
  end

  defp install_print_capture(lua) do
    Lua.set!(lua, [:print], fn args, state ->
      line = Enum.map_join(args, "\t", &format_print_arg(state, &1))
      state = append_print(state, line)
      {[], state}
    end)
  end

  defp format_print_arg(_state, nil), do: "nil"
  defp format_print_arg(_state, true), do: "true"
  defp format_print_arg(_state, false), do: "false"
  defp format_print_arg(_state, value) when is_binary(value), do: value
  defp format_print_arg(_state, value) when is_number(value), do: to_string(value)

  defp format_print_arg(state, {:tref, _} = tref) do
    Lua.Table.as_string(Lua.decode!(state, tref))
  rescue
    _ -> "<table>"
  end

  defp format_print_arg(_state, {:funref, _, _}), do: "<function>"
  defp format_print_arg(_state, {:erl_func, _}), do: "<function>"
  defp format_print_arg(_state, {:erl_mfa, _, _, _}), do: "<function>"
  defp format_print_arg(_state, {:usdref, _}), do: "<userdata>"
  defp format_print_arg(_state, value), do: inspect(value)

  defp append_print(state, line) do
    case Lua.get_private(state, @private_key) do
      {:ok, private} ->
        buffer = (private[:print_output] || []) ++ [line]
        Lua.put_private(state, @private_key, %{private | print_output: buffer})

      _ ->
        Lua.put_private(state, @private_key, %{print_output: [line]})
    end
  end

  @doc """
  Evaluates a Lua script string against a VM built from `opts`.

  Returns `{results, lua}` like `Lua.eval!/2`.
  """
  @spec eval!(String.t(), keyword()) :: {list(), Lua.t()}
  def eval!(script, opts) when is_binary(script) do
    {script_opts, build_opts} = Keyword.split(opts, [:decode])
    lua = build(build_opts)
    Lua.eval!(lua, script, script_opts)
  end

  defp install_surface(lua, %Manifest{entrypoints: entrypoints} = manifest) do
    lua =
      entrypoints
      |> Enum.flat_map(&path_prefixes(parent_path(AshLua.Surface.path(&1))))
      |> Enum.uniq()
      |> Enum.sort_by(&length/1)
      |> Enum.reduce(lua, fn path, lua ->
        Lua.set!(lua, path, %{})
      end)

    Enum.reduce(entrypoints, lua, fn entrypoint, lua ->
      callback =
        build_action_callback(
          entrypoint.resource,
          entrypoint.action,
          manifest
        )

      Lua.set!(lua, AshLua.Surface.path(entrypoint), callback)
    end)
  end

  defp parent_path([_action]), do: []
  defp parent_path(path), do: Enum.drop(path, -1)

  defp path_prefixes([]), do: []

  defp path_prefixes(path) do
    1..length(path)
    |> Enum.map(&Enum.take(path, &1))
  end

  defp install_utils(lua, %Manifest{} = manifest) do
    lookup = resource_lookup_by_path(manifest)

    lua
    |> Lua.set!([:utils], %{})
    |> Lua.set!([:utils, :transaction], %{})
    |> Lua.set!([:utils, :transaction, :transact], transaction_callback(lookup))
    |> Lua.set!([:utils, :transaction, :rollback], rollback_callback())
  end

  defp resource_lookup_by_path(%Manifest{} = manifest) do
    manifest.resources
    |> Enum.flat_map(fn %Manifest.Resource{module: module} ->
      if AshLua.Resource.Info.expose?(module) do
        [{transaction_resource_path(module), module}]
      else
        []
      end
    end)
    |> Map.new()
  end

  defp transaction_resource_path(module) do
    domain = Ash.Resource.Info.domain(module)
    AshLua.Domain.Info.name(domain) <> "." <> AshLua.Resource.Info.name(module)
  end

  defp transaction_callback(lookup) do
    fn args, state ->
      handle_transaction(args, state, lookup)
    end
  end

  # Build a full error envelope (same shape as a real action failure) and
  # hand it back as a Lua-side error. `Lua.set!/3`'s wrapper sees the
  # `{:error, tref, lua}` return and calls `:luerl_lib.lua_error/2`, which
  # throws inside the Lua VM. The outer `Lua.call_function/3` in
  # `run_transaction/3` then catches that as `{:error, tref, state}`, and
  # our message-channel stash carries the tref out to the transaction
  # handler — which decodes it and surfaces the envelope as the
  # transaction's `err`.
  defp rollback_callback do
    fn args, state ->
      message =
        case args do
          [] -> "transaction rolled back"
          [value | _] -> decode_rollback_message(state, value)
        end

      envelope = %{
        "class" => "invalid",
        "errors" => [
          %{
            "message" => message,
            "short_message" => "rolled back",
            "code" => "rolled_back",
            "fields" => [],
            "vars" => %{}
          }
        ]
      }

      {tref, state} = Lua.encode!(state, envelope)
      {:error, tref, state}
    end
  end

  defp decode_rollback_message(_state, value) when is_binary(value), do: value
  defp decode_rollback_message(_state, value) when is_number(value), do: to_string(value)
  defp decode_rollback_message(_state, true), do: "true"
  defp decode_rollback_message(_state, false), do: "false"
  defp decode_rollback_message(_state, nil), do: "transaction rolled back"

  defp decode_rollback_message(state, value) do
    case state |> Lua.decode!(value) |> Encoder.decode_input() do
      %{"message" => m} when is_binary(m) -> m
      _ -> "transaction rolled back"
    end
  end

  defp handle_transaction([resources_arg, fn_ref | _], state, lookup) do
    resources_value = state |> Lua.decode!(resources_arg) |> Encoder.decode_input()

    with {:ok, names} <- normalize_resource_names(resources_value),
         {:ok, modules} <- resolve_resource_modules(names, lookup) do
      run_transaction(modules, fn_ref, state)
    else
      {:error, %AshLua.Errors.FieldsError{} = err} ->
        encode_error_response(state, err)
    end
  end

  defp handle_transaction(_args, state, _lookup) do
    encode_error_response(state, %AshLua.Errors.FieldsError{
      message: "utils.transaction(resources, function) — expected (list, function)",
      short_message: "invalid call",
      code: "invalid_transaction_call",
      fields: [],
      vars: %{}
    })
  end

  defp normalize_resource_names(value) when is_list(value) do
    if Enum.all?(value, &is_binary/1) do
      {:ok, value}
    else
      {:error,
       %AshLua.Errors.FieldsError{
         message: "utils.transaction expects a list of resource path strings",
         short_message: "invalid resources",
         code: "invalid_transaction_resources",
         fields: [],
         vars: %{}
       }}
    end
  end

  defp normalize_resource_names(_) do
    {:error,
     %AshLua.Errors.FieldsError{
       message: "utils.transaction expects a list of resource path strings",
       short_message: "invalid resources",
       code: "invalid_transaction_resources",
       fields: [],
       vars: %{}
     }}
  end

  defp resolve_resource_modules(names, lookup) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      with {:ok, module} <- Map.fetch(lookup, name),
           true <- transactional?(module) do
        {:cont, {:ok, [module | acc]}}
      else
        :error ->
          {:halt,
           {:error,
            %AshLua.Errors.FieldsError{
              message: "unknown resource `#{name}`",
              short_message: "unknown resource",
              code: "unknown_resource",
              fields: [],
              vars: %{"name" => name}
            }}}

        false ->
          {:halt,
           {:error,
            %AshLua.Errors.FieldsError{
              message: "record type `#{name}` does not support transactions",
              short_message: "not transactional",
              code: "not_transactional",
              fields: [],
              vars: %{"name" => name}
            }}}
      end
    end)
    |> case do
      {:ok, mods} -> {:ok, Enum.reverse(mods)}
      err -> err
    end
  end

  defp transactional?(module) do
    Ash.DataLayer.data_layer_can?(module, :transact)
  end

  defp run_transaction(modules, fn_ref, state) do
    parent = self()
    # Per-call ref so we never pick up someone else's `{:tx_state, _}` /
    # `{:tx_lua_error, _}` message — both sends below carry the same ref and
    # the receives below match only on it.
    ref = make_ref()

    try do
      result =
        Ash.transact(modules, fn ->
          case Lua.call_function(state, fn_ref, []) do
            {:ok, values, new_state} ->
              send(parent, {:tx_state, ref, new_state})
              # Wrap so Ash.transact doesn't treat the body's `{:error, _}`
              # convention-return as a rollback signal — only raises and
              # action-side errors should roll back.
              {:body_ok, values}

            {:error, reason, new_state} ->
              # Stash both the state AND the original Lua error tuple. The
              # data layer's rollback wrapper calls `Mnesia.abort/1` on our
              # `{:error, reason}` return; Mnesia's transaction catch then
              # `Exception.format_exit/1`s the tuple to a string before
              # wrapping it as `Ash.Error.Unknown`, so we can't recover the
              # original from the result. Forwarding it here lets us decode
              # the raised table back into a structured envelope.
              send(parent, {:tx_state, ref, new_state})
              send(parent, {:tx_lua_error, ref, reason})
              {:error, reason}
          end
        end)

      new_state =
        receive do
          {:tx_state, ^ref, s} -> s
        after
          0 -> state
        end

      captured_lua_error =
        receive do
          {:tx_lua_error, ^ref, e} -> e
        after
          0 -> nil
        end

      case {result, captured_lua_error} do
        {{:ok, {:body_ok, values}}, _} ->
          # Pass through every value the body returned plus a trailing nil
          # for the err slot, so the caller can pattern-match `local v, e =
          # utils.transaction(...)` consistently with the rest of the
          # surface.
          {values ++ [nil], new_state}

        {{:ok, {:body_ok, values}, _notifications}, _} ->
          {values ++ [nil], new_state}

        {{:error, _ash_error}, lua_error} when not is_nil(lua_error) ->
          # Rollback was triggered by a Lua-side error; we stashed the
          # original tuple before Mnesia's exit-formatting wrapped it.
          encode_lua_transaction_error(new_state, lua_error)

        {{:error, ash_error}, _} ->
          {encoded, st} = Lua.encode!(new_state, Encoder.encode_error(ash_error))
          {[nil, encoded], st}
      end
    after
      # Drain any tx-tagged messages we didn't pick up — e.g. if an
      # exception jumped past our receives. Without this they'd linger in
      # the parent's mailbox forever.
      drain_tx_messages(ref)
    end
  end

  defp drain_tx_messages(ref) do
    receive do
      {:tx_state, ^ref, _} -> drain_tx_messages(ref)
      {:tx_lua_error, ^ref, _} -> drain_tx_messages(ref)
    after
      0 -> :ok
    end
  end

  defp encode_lua_transaction_error(state, {:assert_error, value}) do
    encode_lua_transaction_error_body(state, value)
  end

  defp encode_lua_transaction_error(state, {:error_call, [value | _]}) do
    encode_lua_transaction_error_body(state, value)
  end

  # `:luerl_lib.lua_error/2` (used by our `utils.transaction.rollback`
  # callback) raises with the encoded value directly, so the captured error
  # reason is a bare `{:tref, _}` rather than one of the wrapped shapes
  # above.
  defp encode_lua_transaction_error(state, {:tref, _} = tref) do
    encode_lua_transaction_error_body(state, tref)
  end

  defp encode_lua_transaction_error(state, _other) do
    err = %{
      "class" => "invalid",
      "errors" => [
        %{
          "message" => "transaction rolled back due to a Lua error",
          "short_message" => "lua_error",
          "code" => "lua_error",
          "fields" => [],
          "vars" => %{}
        }
      ]
    }

    {encoded, st} = Lua.encode!(state, err)
    {[nil, encoded], st}
  end

  defp encode_lua_transaction_error_body(state, value) do
    decoded =
      try do
        Lua.decode!(state, value)
      rescue
        _ -> nil
      end

    envelope =
      case decoded do
        list when is_list(list) ->
          case Encoder.decode_input(list) do
            # Already a full envelope (e.g. an err table the script
            # propagated from a failed action call via `assert(...)`).
            %{"class" => _, "errors" => _} = env ->
              env

            # A user-raised table that looks like a single leaf error
            # (typical from `error({ code = ..., message = ... })`). Wrap
            # it as the single entry in a fresh envelope.
            %{} = leaf ->
              wrap_user_leaf(leaf)

            other ->
              wrap_user_value(other)
          end

        nil ->
          nil

        other ->
          wrap_user_value(other)
      end

    case envelope do
      nil ->
        encode_lua_transaction_error(state, :unknown)

      env ->
        {encoded, st} = Lua.encode!(state, env)
        {[nil, encoded], st}
    end
  end

  defp wrap_user_leaf(leaf) when is_map(leaf) do
    %{
      "class" => "invalid",
      "errors" => [
        %{
          "message" => Map.get(leaf, "message") || "lua error",
          "short_message" => Map.get(leaf, "short_message") || "lua error",
          "code" => Map.get(leaf, "code") || "lua_error",
          "fields" => Map.get(leaf, "fields") || [],
          "vars" => Map.drop(leaf, ["message", "short_message", "code", "fields"])
        }
      ]
    }
  end

  # A non-map raise — typically `error("some string")`. Surface the value as
  # the message of a single leaf entry.
  defp wrap_user_value(value) do
    %{
      "class" => "invalid",
      "errors" => [
        %{
          "message" => to_message_string(value),
          "short_message" => "lua error",
          "code" => "lua_error",
          "fields" => [],
          "vars" => %{}
        }
      ]
    }
  end

  defp to_message_string(value) when is_binary(value), do: value
  defp to_message_string(value) when is_number(value), do: to_string(value)
  defp to_message_string(true), do: "true"
  defp to_message_string(false), do: "false"
  defp to_message_string(nil), do: "lua error"
  defp to_message_string(_other), do: "lua error"

  defp build_action_callback(resource, action, manifest) do
    fn args, state ->
      input = decode_call_args(state, args)
      ash_opts = build_ash_opts(state)
      {fields_input, input} = Map.pop(input, "fields")
      {operation, input} = Map.pop(input, "operation")
      input = AshLua.FieldNames.to_internal_input(resource, action, input)
      operation = AshLua.FieldNames.to_internal_operation(resource, operation)

      cond do
        is_nil(operation) ->
          regular_call(resource, action, input, ash_opts, fields_input, manifest, state)

        action.type == :read ->
          operation_call(resource, action, input, ash_opts, operation, state)

        true ->
          t = Atom.to_string(action.type)

          encode_error_response(
            state,
            %AshLua.Errors.FieldsError{
              message: "`operation` is only supported on list operations (this is `#{t}`)",
              short_message: "operation only on list operations",
              code: "operation_only_on_list_operations",
              fields: [],
              vars: %{"action_type" => t}
            }
          )
      end
    end
  end

  defp regular_call(resource, action, input, ash_opts, fields_input, manifest, state) do
    case AshLua.Fields.for_action(manifest, resource, action, fields_input) do
      {:ok, {select, load, template}} ->
        case dispatch(resource, action, input, ash_opts, select, load) do
          {:ok, result} ->
            {encoded, state} = Lua.encode!(state, Encoder.encode_with_template(result, template))
            {[encoded, nil], state}

          :ok ->
            {[true, nil], state}

          {:error, error} ->
            encode_action_error_response(state, resource, action, error)
        end

      {:error, reason} ->
        encode_action_error_response(state, resource, action, reason)
    end
  end

  defp operation_call(resource, action, input, ash_opts, operation, state) do
    case run_read_operation(resource, action, input, ash_opts, operation) do
      {:ok, value} ->
        {encoded, state} = Lua.encode!(state, Encoder.encode_result(value))
        {[encoded, nil], state}

      {:operation_error, reason} ->
        encode_action_error_response(state, resource, action, reason)

      {:error, error} ->
        encode_action_error_response(state, resource, action, error)
    end
  end

  defp encode_error_response(state, error) do
    {encoded, state} = Lua.encode!(state, Encoder.encode_error(error))
    {[nil, encoded], state}
  end

  defp encode_action_error_response(state, resource, action, error) do
    encoded_error =
      error
      |> Encoder.encode_error()
      |> AshLua.FieldNames.to_lua_error(resource, action)

    {encoded, state} = Lua.encode!(state, encoded_error)
    {[nil, encoded], state}
  end

  defp run_read_operation(resource, action, input, opts, operation) do
    {_page_opt, input} = pop_page_opt(input)
    {filter, input} = Map.pop(input, "filter")
    {sort, input} = Map.pop(input, "sort")
    {limit, input} = Map.pop(input, "limit")
    {offset, input} = Map.pop(input, "offset")

    query =
      resource
      |> Ash.Query.for_read(action.name, input, opts)
      |> maybe_filter_input(filter)
      |> maybe_sort_input(sort)
      |> maybe_limit(limit)
      |> maybe_offset(offset)

    perform_operation(query, resource, operation, opts)
  end

  defp perform_operation(query, _resource, "count", opts) do
    query
    |> Ash.Query.unset([:limit, :offset])
    |> Ash.count(opts)
  end

  defp perform_operation(query, _resource, "exists", opts) do
    Ash.exists(query, opts)
  end

  defp perform_operation(query, resource, [op, field_name], opts)
       when op in ~w(count min max sum avg list first) and is_binary(field_name) do
    with {:ok, field_atom} <- safe_field_atom(field_name),
         {:ok, agg_kind} <- safe_op_atom(op),
         {:ok, agg} <- build_aggregate(resource, agg_kind, field_atom) do
      run_aggregate(query, agg, opts)
    end
  end

  defp perform_operation(_query, _resource, other, _opts) do
    s = describe_operation(other)

    {:operation_error,
     %AshLua.Errors.FieldsError{
       message: "unknown operation `#{s}`",
       short_message: "unknown operation",
       code: "unknown_operation",
       fields: [],
       vars: %{"name" => s}
     }}
  end

  defp describe_operation(value) when is_binary(value), do: value
  defp describe_operation(value) when is_atom(value), do: Atom.to_string(value)
  defp describe_operation(value) when is_list(value), do: "list"
  defp describe_operation(_), do: "value"

  defp safe_field_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError ->
      {:operation_error,
       %AshLua.Errors.FieldsError{
         message: "unknown field `#{name}` referenced by operation",
         short_message: "unknown field",
         code: "unknown_operation_field",
         fields: [name],
         vars: %{"name" => name}
       }}
  end

  defp safe_op_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError ->
      {:operation_error,
       %AshLua.Errors.FieldsError{
         message: "unknown operation kind `#{name}`",
         short_message: "unknown operation kind",
         code: "unknown_operation_kind",
         fields: [],
         vars: %{"name" => name}
       }}
  end

  defp build_aggregate(resource, kind, field) do
    {:ok, Ash.Query.Aggregate.new!(resource, :aggregate_result, kind, field: field)}
  rescue
    e ->
      msg = Exception.message(e)

      {:operation_error,
       %AshLua.Errors.FieldsError{
         message: "could not build aggregate: #{msg}",
         short_message: "aggregate build failed",
         code: "aggregate_build_failed",
         fields: [],
         vars: %{"message" => msg}
       }}
  end

  defp run_aggregate(query, aggregate, opts) do
    case Ash.aggregate(query, aggregate, opts) do
      {:ok, %{aggregate_result: value}} -> {:ok, value}
      {:ok, value} -> {:ok, value}
      {:error, _} = err -> err
    end
  end

  defp decode_call_args(_state, []), do: %{}

  defp decode_call_args(state, [value | _]) do
    decoded = Lua.decode!(state, value)

    case Encoder.decode_input(decoded) do
      map when is_map(map) -> map
      _other -> %{}
    end
  end

  defp dispatch(resource, %{type: :read} = action, input, opts, select, load) do
    {page_opt, input} = pop_page_opt(input)
    {filter, input} = Map.pop(input, "filter")
    {sort, input} = Map.pop(input, "sort")
    {limit, input} = Map.pop(input, "limit")
    {offset, input} = Map.pop(input, "offset")

    query =
      resource
      |> Ash.Query.for_read(action.name, input, opts)
      |> maybe_select(select)
      |> maybe_load(load)
      |> maybe_filter_input(filter)
      |> maybe_sort_input(sort)
      |> maybe_limit(limit)
      |> maybe_offset(offset)

    cond do
      action.get? ->
        Ash.read_one(query, opts)

      page_opt ->
        Ash.read(query, Keyword.put(opts, :page, page_opt))

      true ->
        Ash.read(query, opts)
    end
  end

  defp dispatch(resource, %{type: :create} = action, input, opts, select, load) do
    resource
    |> Ash.Changeset.for_create(action.name, input, opts)
    |> changeset_select(select)
    |> changeset_load(load)
    |> Ash.create(opts)
  end

  defp dispatch(resource, %{type: :update} = action, input, opts, select, load) do
    {filter, input} = split_primary_key_filter(resource, input)

    bulk_extras =
      []
      |> append_if(select != [], {:select, select})
      |> append_if(load_present?(load), {:load, load})

    resource
    |> pk_query(filter, opts)
    |> Ash.bulk_update(action.name, input, bulk_opts(resource, opts) ++ bulk_extras)
    |> unwrap_bulk_result(filter, resource)
  end

  defp dispatch(resource, %{type: :destroy} = action, input, opts, select, load) do
    {filter, input} = split_primary_key_filter(resource, input)

    bulk_extras =
      []
      |> append_if(select != [], {:select, select})
      |> append_if(load_present?(load), {:load, load})

    resource
    |> pk_query(filter, opts)
    |> Ash.bulk_destroy(action.name, input, bulk_opts(resource, opts) ++ bulk_extras)
    |> unwrap_bulk_result(filter, resource)
  end

  defp dispatch(resource, %{type: :action} = action, input, opts, _select, _load) do
    resource
    |> Ash.ActionInput.for_action(action.name, input, opts)
    |> Ash.run_action(opts)
  end

  defp maybe_select(query, []), do: query
  defp maybe_select(query, fields), do: Ash.Query.select(query, fields, replace?: true)

  defp maybe_load(query, []), do: query
  defp maybe_load(query, load), do: Ash.Query.load(query, load)

  defp changeset_select(changeset, []), do: changeset

  defp changeset_select(changeset, fields),
    do: Ash.Changeset.select(changeset, fields, replace?: true)

  defp changeset_load(changeset, []), do: changeset
  defp changeset_load(changeset, load), do: Ash.Changeset.load(changeset, load)

  defp load_present?([]), do: false
  defp load_present?(_), do: true

  defp append_if(list, false, _), do: list
  defp append_if(list, true, item), do: list ++ [item]

  defp maybe_filter_input(query, nil), do: query
  defp maybe_filter_input(query, filter), do: Ash.Query.filter_input(query, filter)

  defp maybe_sort_input(query, nil), do: query
  defp maybe_sort_input(query, sort), do: Ash.Query.sort_input(query, sort)

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: Ash.Query.limit(query, limit)

  defp maybe_offset(query, nil), do: query
  defp maybe_offset(query, offset), do: Ash.Query.offset(query, offset)

  defp pop_page_opt(input) do
    case Map.pop(input, "page") do
      {nil, rest} -> {nil, rest}
      {page, rest} when is_map(page) -> {Map.to_list(atomize_keys(page)), rest}
      {page, rest} when is_list(page) -> {page, rest}
      {_, rest} -> {nil, rest}
    end
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_existing_atom(k), v} end)
  end

  defp to_existing_atom(k) when is_atom(k), do: k

  defp to_existing_atom(k) when is_binary(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError ->
      reraise(ArgumentError, "Unknown key #{inspect(k)} in page options", __STACKTRACE__)
  end

  defp split_primary_key_filter(resource, input) do
    pk_fields = Ash.Resource.Info.primary_key(resource)
    string_keys = Enum.map(pk_fields, &Atom.to_string/1)

    filter =
      pk_fields
      |> Enum.zip(string_keys)
      |> Enum.reduce(%{}, fn {atom_key, string_key}, acc ->
        case fetch_either(input, atom_key, string_key) do
          {:ok, value} -> Map.put(acc, atom_key, value)
          :error -> acc
        end
      end)

    remaining = Map.drop(input, string_keys ++ pk_fields)

    {filter, remaining}
  end

  defp fetch_either(map, atom_key, string_key) do
    cond do
      Map.has_key?(map, string_key) -> {:ok, Map.fetch!(map, string_key)}
      Map.has_key?(map, atom_key) -> {:ok, Map.fetch!(map, atom_key)}
      true -> :error
    end
  end

  defp pk_query(resource, filter, opts) do
    resource
    |> Ash.Query.new()
    |> apply_query_opts(opts)
    |> Ash.Query.do_filter(Map.to_list(filter))
    |> Ash.Query.limit(1)
  end

  defp apply_query_opts(query, opts) do
    query
    |> maybe_set_tenant(opts[:tenant])
    |> maybe_set_context(opts[:context])
  end

  defp maybe_set_tenant(query, nil), do: query
  defp maybe_set_tenant(query, tenant), do: Ash.Query.set_tenant(query, tenant)

  defp maybe_set_context(query, ctx) when is_nil(ctx) or ctx == %{}, do: query
  defp maybe_set_context(query, ctx), do: Ash.Query.set_context(query, ctx)

  defp bulk_opts(resource, opts) do
    [
      domain: Ash.Resource.Info.domain(resource),
      return_records?: true,
      return_errors?: true,
      notify?: true,
      strategy: [:atomic, :stream, :atomic_batches],
      allow_stream_with: :full_read
    ]
    |> Keyword.merge(opts)
  end

  defp unwrap_bulk_result(
         %Ash.BulkResult{status: :success, records: [record]},
         _filter,
         _resource
       ),
       do: {:ok, record}

  defp unwrap_bulk_result(%Ash.BulkResult{status: :success, records: []}, filter, resource) do
    {:error, Ash.Error.Query.NotFound.exception(primary_key: filter, resource: resource)}
  end

  defp unwrap_bulk_result(%Ash.BulkResult{errors: errors}, _filter, _resource)
       when errors != [] do
    {:error, errors}
  end

  defp unwrap_bulk_result(%Ash.BulkResult{} = result, _filter, _resource) do
    {:error, result}
  end

  defp build_ash_opts(state) do
    %{actor: actor, tenant: tenant, context: context} = get_private(state)

    [actor: actor, tenant: tenant, context: context]
    |> Enum.reject(fn
      {:context, ctx} -> is_nil(ctx) or ctx == %{}
      {_k, v} -> is_nil(v)
    end)
  end

  defp get_private(%Lua{} = state) do
    case Lua.get_private(state, @private_key) do
      {:ok, value} -> value
      :error -> %{actor: nil, tenant: nil, context: %{}}
    end
  end
end
