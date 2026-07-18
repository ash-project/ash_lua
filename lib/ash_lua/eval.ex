# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Eval do
  @moduledoc """
  Public runtime helpers for evaluating scripts against a scoped AshLua surface.

  This module is the adapter-free layer underneath `AshLua.EvalActions`. Use it
  when a custom transport, MCP server, or in-process LLM loop wants the same
  scoped Lua runtime without going through a synthesized Ash action.

  Each `run/2` call builds a fresh Lua VM. Reuse should happen at the manifest
  level: resolve or preload a manifest once, then pass it as `manifest: manifest`
  for subsequent invocations.
  """

  alias Ash.Info.Manifest

  @type run_result :: %{
          required(:result) => term(),
          required(:error) => map() | nil,
          required(:print_output) => [String.t()]
        }

  @type manifest_opts :: [
          manifest: Manifest.t(),
          eval_resource: module(),
          otp_app: atom(),
          labels: [atom()],
          action_entrypoints: [{module(), atom()}],
          cache?: boolean()
        ]

  @type run_opts :: [
          {:actor, term()}
          | {:tenant, term()}
          | {:context, map()}
          | {:forbidden_fields, :hide | :display}
          | {:lua, Lua.t()}
          | {:lua_options, keyword()}
          | {:source, String.t()}
          | {:manifest, Manifest.t()}
          | {:eval_resource, module()}
          | {:otp_app, atom()}
          | {:labels, [atom()]}
          | {:action_entrypoints, [{module(), atom()}]}
          | {:cache?, boolean()}
        ]

  @doc """
  Resolves a scoped AshLua manifest.

  Accepted inputs:

    * `manifest: manifest` or a `%Ash.Info.Manifest{}` value — reuse an already
      resolved manifest.
    * `eval_resource: MyApp.AgentSurface` — use an `AshLua.EvalActions`
      resource's scope.
    * `otp_app: :my_app` plus optional `labels:` / `action_entrypoints:` —
      build a scoped surface directly from domain DSL metadata.
    * `cache?: true` with `eval_resource:` — cache and reuse the scoped manifest
      in `:persistent_term`.
  """
  @spec manifest(Manifest.t() | manifest_opts()) :: {:ok, Manifest.t()} | {:error, term()}
  def manifest(%Manifest{} = manifest), do: {:ok, AshLua.Surface.for_manifest(manifest)}

  def manifest(opts) when is_list(opts) do
    cond do
      Keyword.has_key?(opts, :manifest) ->
        case Keyword.fetch!(opts, :manifest) do
          %Manifest{} = manifest ->
            {:ok, AshLua.Surface.for_manifest(manifest)}

          other ->
            {:error,
             ArgumentError.exception(
               "expected :manifest to be an Ash.Info.Manifest, got: #{inspect(other)}"
             )}
        end

      resource = Keyword.get(opts, :eval_resource) ->
        AshLua.Surface.for_eval_resource(resource, Keyword.take(opts, [:cache?]))

      otp_app = Keyword.get(opts, :otp_app) ->
        AshLua.Surface.for_otp_app(otp_app,
          labels: Keyword.get(opts, :labels, []),
          action_entrypoints: Keyword.get(opts, :action_entrypoints)
        )

      true ->
        {:error,
         ArgumentError.exception(
           "expected one of :manifest, :eval_resource, or :otp_app when resolving an AshLua eval surface"
         )}
    end
  end

  @doc """
  Resolves a scoped AshLua manifest or raises.
  """
  @spec manifest!(Manifest.t() | manifest_opts()) :: Manifest.t()
  def manifest!(manifest_or_opts) do
    case manifest(manifest_or_opts) do
      {:ok, %Manifest{} = manifest} -> manifest
      {:error, reason} -> raise reason
    end
  end

  @doc """
  Evaluates `script` against a scoped AshLua runtime.

  Returns the same stable shape as the synthesized `:eval` action:
  `%{result: term, error: map | nil, print_output: [String.t()]}`.

  The surface is resolved with `manifest/1`. Runtime options include
  `:actor`, `:tenant`, `:context`, `:forbidden_fields`, `:source`, `:lua`, and
  `:lua_options`. `:lua_options` is forwarded to `Lua.new/1` when a prebuilt
  `:lua` VM is not supplied.
  """
  @spec run(String.t(), run_opts()) :: {:ok, run_result()} | {:error, term()}
  def run(script, opts) when is_binary(script) and is_list(opts) do
    forbidden_fields = Keyword.get(opts, :forbidden_fields, :hide)

    with {:ok, %Manifest{} = manifest} <- manifest(opts) do
      do_run(script, build_eval_opts(opts, manifest, forbidden_fields))
    end
  end

  @doc """
  Returns markdown documentation for a scoped AshLua surface.

  Pass neither `:name` nor `:search` for the compact index. Pass
  `name: "full"` for the full page, a callable/type/topic id for a focused
  page, or `search: term` for ranked search results.
  """
  @spec docs(Manifest.t() | manifest_opts(), keyword() | map()) ::
          {:ok, String.t()} | {:error, term()}
  def docs(manifest_or_opts, args \\ [])

  def docs(%Manifest{} = manifest, args) do
    dispatch_docs(AshLua.Surface.for_manifest(manifest), normalize_doc_args(args))
  end

  def docs(opts, []) when is_list(opts) do
    args = Keyword.take(opts, [:name, :search])

    with {:ok, %Manifest{} = manifest} <- manifest(opts) do
      dispatch_docs(manifest, normalize_doc_args(args))
    end
  end

  def docs(opts, args) when is_list(opts) do
    with {:ok, %Manifest{} = manifest} <- manifest(opts) do
      dispatch_docs(manifest, normalize_doc_args(args))
    end
  end

  defp build_eval_opts(opts, manifest, forbidden_fields) do
    [
      manifest: manifest,
      actor: Keyword.get(opts, :actor),
      tenant: Keyword.get(opts, :tenant),
      context: Keyword.get(opts, :context, %{}) || %{},
      forbidden_fields: forbidden_fields
    ]
    |> maybe_put(:lua, Keyword.get(opts, :lua))
    |> maybe_put(:lua_options, Keyword.get(opts, :lua_options))
    |> maybe_put(:source, Keyword.get(opts, :source))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp do_run(script, eval_opts) do
    {values, lua} = AshLua.eval!(script, eval_opts)
    {result, error} = split_lua_return(values)

    {:ok,
     %{
       result: AshLua.Encoder.encode_result(result),
       error: error,
       print_output: AshLua.Runtime.print_output(lua)
     }}
  rescue
    e in [Lua.CompilerException, Lua.RuntimeException] ->
      {:ok,
       %{
         result: nil,
         error:
           extract_structured_error(e) ||
             format_lua_error(e, script, Keyword.get(eval_opts, :source)),
         print_output: []
       }}
  end

  # The raised Lua value and the VM state at the point of failure both live on
  # the wrapped VM exception (`:original`); the outer `Lua.RuntimeException`
  # never carries state itself.
  defp extract_structured_error(%Lua.RuntimeException{original: original}) do
    case {raised_value(original), vm_state(original)} do
      {nil, _state} -> nil
      {_value, nil} -> nil
      {value, lua_state} -> value |> safe_decode(lua_state) |> normalize_error_table()
    end
  end

  defp extract_structured_error(_), do: nil

  defp raised_value(error) when is_struct(error), do: Map.get(error, :value)
  defp raised_value(_), do: nil

  defp vm_state(error) when is_struct(error), do: Map.get(error, :state)
  defp vm_state(_), do: nil

  defp safe_decode(value, state) do
    Lua.decode!(%Lua{state: state}, value)
  rescue
    _ -> nil
  end

  defp normalize_error_table(list) when is_list(list) do
    case AshLua.Encoder.decode_input(list) do
      %{"class" => _, "errors" => _} = err -> err
      _ -> nil
    end
  end

  defp normalize_error_table(_), do: nil

  defp split_lua_return([]), do: {nil, nil}
  defp split_lua_return([value]), do: {value, nil}
  defp split_lua_return([value, nil | _]), do: {value, nil}
  defp split_lua_return([nil, err | _]), do: {nil, normalize_error(err)}
  defp split_lua_return([value, err | _]), do: {value, normalize_error(err)}

  defp normalize_error(err) when is_list(err), do: Map.new(err)
  defp normalize_error(err) when is_map(err), do: err
  defp normalize_error(err), do: %{"message" => inspect(err)}

  defp format_lua_error(%Lua.CompilerException{} = e, script, source) do
    case Lua.Parser.parse_structured(script) do
      {:error, [parse_error | _]} ->
        parse_error
        |> Lua.Parser.Error.to_map(script)
        |> json_safe()
        |> maybe_put_lua_source(source)
        |> lua_error_envelope()

      _ ->
        lua_error_envelope(Exception.message(e), %{})
    end
  end

  defp format_lua_error(%Lua.RuntimeException{original: original} = e, script, source) do
    vars = structured_runtime_error(original, script, source)
    lua_error_envelope(Exception.message(e), vars)
  end

  defp structured_runtime_error(%{__struct__: module} = original, script, source) do
    if function_exported?(module, :to_map, 2) do
      original
      |> module.to_map(source_code: script)
      |> json_safe()
      |> maybe_put_lua_source(source)
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp structured_runtime_error(_original, _script, _source), do: %{}

  defp maybe_put_lua_source(vars, nil), do: vars
  defp maybe_put_lua_source(%{"source" => nil} = vars, source), do: %{vars | "source" => source}
  defp maybe_put_lua_source(%{"source" => ""} = vars, source), do: %{vars | "source" => source}
  defp maybe_put_lua_source(vars, _source), do: vars

  defp lua_error_envelope(%{"message" => message} = vars) when is_binary(message) do
    lua_error_envelope(message, vars)
  end

  defp lua_error_envelope(message, vars) do
    %{
      "message" => message,
      "errors" => [
        %{
          "message" => message,
          "short_message" => "lua_error",
          "code" => "lua_error",
          "fields" => [],
          "vars" => vars
        }
      ]
    }
  end

  defp json_safe(%{} = map) do
    Map.new(map, fn {key, value} -> {json_key(key), json_safe(value)} end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)

  defp json_safe(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp json_safe(value), do: value

  defp json_key(:highlight?), do: "highlight"
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: to_string(key)

  defp normalize_doc_args(args) when is_map(args) do
    %{
      name: Map.get(args, :name) || Map.get(args, "name"),
      search: Map.get(args, :search) || Map.get(args, "search")
    }
  end

  defp normalize_doc_args(args) when is_list(args) do
    %{
      name: keyword_or_string(args, :name),
      search: keyword_or_string(args, :search)
    }
  end

  defp keyword_or_string(args, key) do
    case Keyword.fetch(args, key) do
      {:ok, value} ->
        value

      :error ->
        case List.keyfind(args, Atom.to_string(key), 0) do
          {_key, value} -> value
          nil -> nil
        end
    end
  end

  defp dispatch_docs(manifest, %{name: name, search: search}) do
    if present?(name) and present?(search) do
      {:error,
       Ash.Error.Action.InvalidArgument.exception(
         field: :search,
         message: "`name` and `search` are mutually exclusive — pass at most one"
       )}
    else
      dispatch_docs(manifest, name, search)
    end
  end

  defp dispatch_docs(manifest, _name, search) when is_binary(search) and search != "" do
    {:ok, AshLua.Docs.search(manifest, search)}
  end

  defp dispatch_docs(manifest, name, _search) when name in [nil, ""] do
    {:ok, AshLua.Docs.index_doc(manifest)}
  end

  defp dispatch_docs(manifest, "full", _search) do
    {:ok, AshLua.Docs.full_doc(manifest)}
  end

  defp dispatch_docs(manifest, name, _search) when is_binary(name) do
    cond do
      name in AshLua.Docs.list_callables(manifest) ->
        AshLua.Docs.callable_doc(manifest, name)

      name in AshLua.Docs.list_types(manifest) ->
        AshLua.Docs.type_doc(manifest, name)

      name in AshLua.Docs.topics(manifest) ->
        AshLua.Docs.topic_doc(manifest, name)

      true ->
        {:error,
         Ash.Error.Action.InvalidArgument.exception(
           field: :name,
           message: "no callable, type, or topic named #{inspect(name)} in the exposed surface"
         )}
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(value) when is_binary(value), do: true
  defp present?(_), do: false
end
