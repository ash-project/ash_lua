# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Surface do
  @moduledoc """
  Annotates `%Ash.Info.Manifest{}` entrypoints with AshLua public surface data.

  The manifest remains the API specification. AshLua stores extension-specific
  callable path metadata under each entrypoint's `config[:ash_lua]`.
  """

  alias Ash.Info.Manifest
  alias AshLua.Domain.{Action, Namespace}

  @config_key :ash_lua
  @eval_manifest_cache_key {__MODULE__, :eval_manifest_cache}
  @cache_miss {:ash_lua, :eval_manifest_cache_miss}

  @type surface_config :: %{
          required(:domain) => module(),
          required(:labels) => [atom()],
          required(:lua_action) => String.t(),
          required(:path) => [String.t()],
          required(:path_string) => String.t(),
          required(:path_source) => :explicit | :derived
        }

  @doc "Generates a manifest for an OTP app with AshLua surface metadata attached."
  @spec for_otp_app(atom(), keyword()) :: {:ok, Manifest.t()}
  def for_otp_app(otp_app, opts \\ []) do
    {filter, opts} = Keyword.pop(opts, :action_entrypoints)
    {labels, opts} = Keyword.pop(opts, :labels, [])
    action_entrypoints = action_entrypoints_for_otp_app(otp_app, filter, labels)

    opts
    |> Keyword.put(:otp_app, otp_app)
    |> Keyword.put(:action_entrypoints, action_entrypoints)
    |> Manifest.generate()
  end

  @doc "Generates the scoped Lua manifest for an `AshLua.EvalActions` resource."
  @spec for_eval_resource(module(), keyword()) :: {:ok, Manifest.t()}
  def for_eval_resource(resource, opts \\ []) do
    if Keyword.get(opts, :cache?, false) do
      case cached_eval_manifest(resource) do
        {:ok, %Manifest{} = manifest} -> {:ok, manifest}
        :error -> cache_eval_manifest(resource)
      end
    else
      build_eval_resource_manifest(resource)
    end
  end

  @doc """
  Preloads and caches scoped Lua manifests for every `AshLua.EvalActions`
  resource in an OTP app.

  The cache stores only immutable manifest data. Each eval invocation still
  builds a fresh Lua VM with its caller-specific actor, tenant, and context.
  Generated `AshLua.EvalActions` use this cache by default; direct runtime
  calls can opt in with `cache?: true`.
  """
  @spec preload_eval_manifests!(atom()) :: [module()]
  def preload_eval_manifests!(otp_app) when is_atom(otp_app) do
    resources = eval_resources(otp_app)

    entries =
      Enum.map(resources, fn resource ->
        {resource, build_eval_resource_manifest!(resource)}
      end)

    cache =
      @eval_manifest_cache_key
      |> :persistent_term.get(%{})
      |> Map.merge(Map.new(entries))

    :persistent_term.put(@eval_manifest_cache_key, cache)

    resources
  end

  @doc "Clears the eval manifest cache populated by `preload_eval_manifests!/1`."
  @spec clear_eval_manifest_cache!() :: :ok
  def clear_eval_manifest_cache! do
    :persistent_term.erase(@eval_manifest_cache_key)
    :ok
  end

  defp build_eval_resource_manifest!(resource) do
    {:ok, %Manifest{} = manifest} = build_eval_resource_manifest(resource)
    manifest
  end

  defp build_eval_resource_manifest(resource) do
    otp_app = AshLua.EvalActions.Info.otp_app(resource)
    labels = AshLua.EvalActions.Info.labels(resource)
    exposed_action_entrypoints = AshLua.EvalActions.Info.exposed_action_entrypoints(resource)

    action_entrypoints =
      case {labels, exposed_action_entrypoints} do
        {labels, []} when labels != [] -> nil
        _ -> exposed_action_entrypoints
      end

    for_otp_app(otp_app,
      action_entrypoints: action_entrypoints,
      labels: labels
    )
  end

  defp eval_resources(otp_app) do
    otp_app
    |> Ash.Info.domains()
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.filter(&(AshLua.EvalActions in Ash.Resource.Info.extensions(&1)))
  end

  defp cached_eval_manifest(resource) do
    case :persistent_term.get(@eval_manifest_cache_key, @cache_miss) do
      @cache_miss ->
        :error

      cache when is_map(cache) ->
        case Map.fetch(cache, resource) do
          {:ok, %Manifest{} = manifest} -> {:ok, manifest}
          _ -> :error
        end
    end
  end

  defp cache_eval_manifest(resource) do
    with {:ok, %Manifest{} = manifest} <- build_eval_resource_manifest(resource) do
      cache =
        @eval_manifest_cache_key
        |> :persistent_term.get(%{})
        |> Map.put(resource, manifest)

      :persistent_term.put(@eval_manifest_cache_key, cache)

      {:ok, manifest}
    end
  end

  @doc """
  Attaches AshLua surface metadata to an existing manifest.

  Domains with explicit `lua do namespace ... end` actions expose only those
  configured actions. Domains without explicit surface actions retain the legacy
  derived shape: `<domain>.<resource>.<action>`.
  """
  @spec for_manifest(Manifest.t()) :: Manifest.t()
  def for_manifest(%Manifest{entrypoints: []} = manifest), do: manifest

  def for_manifest(%Manifest{entrypoints: entrypoints} = manifest) do
    if Enum.all?(entrypoints, &(not is_nil(config(&1)))) do
      manifest
    else
      annotate_manifest(manifest)
    end
  end

  defp annotate_manifest(%Manifest{} = manifest) do
    filter =
      Enum.map(manifest.entrypoints, fn %Manifest.Entrypoint{} = entrypoint ->
        {entrypoint.resource, entrypoint.action.name}
      end)

    entries_by_key =
      Enum.group_by(manifest.entrypoints, fn %Manifest.Entrypoint{} = entrypoint ->
        {entrypoint.resource, entrypoint.action.name}
      end)

    entrypoints =
      manifest
      |> otp_app_from_manifest()
      |> action_entrypoints_for_otp_app(filter, [])
      |> Enum.flat_map(fn %{resource: resource, action: action, config: config} ->
        case Map.get(entries_by_key, {resource, action}) do
          nil ->
            []

          [entrypoint | _] ->
            [%{entrypoint | config: merge_config(entrypoint.config, config)}]
        end
      end)

    %{manifest | entrypoints: entrypoints}
  end

  @doc "Deprecated compatibility alias for `for_manifest/1`."
  @spec from_manifest(Manifest.t()) :: Manifest.t()
  def from_manifest(%Manifest{} = manifest), do: for_manifest(manifest)

  @doc "Returns the annotated entrypoint matching a dotted Lua callable path."
  @spec find_entrypoint(Manifest.t(), String.t()) :: {:ok, Manifest.Entrypoint.t()} | :error
  def find_entrypoint(%Manifest{} = manifest, path) when is_binary(path) do
    case Enum.find(manifest.entrypoints, &(path_string(&1) == path)) do
      nil -> :error
      entrypoint -> {:ok, entrypoint}
    end
  end

  @doc "Compatibility alias for `find_entrypoint/2`."
  @spec find_action(Manifest.t(), String.t()) :: {:ok, Manifest.Entrypoint.t()} | :error
  def find_action(%Manifest{} = manifest, path), do: find_entrypoint(manifest, path)

  @doc "Returns the resource/action tuples represented by the annotated manifest."
  @spec action_entrypoints(Manifest.t()) :: [{module(), atom()}]
  def action_entrypoints(%Manifest{entrypoints: entrypoints}) do
    entrypoints
    |> Enum.map(&{&1.resource, &1.action.name})
    |> Enum.uniq()
  end

  @doc "Returns the Lua path segments for an annotated entrypoint."
  @spec path(Manifest.Entrypoint.t()) :: [String.t()]
  def path(%Manifest.Entrypoint{} = entrypoint), do: config!(entrypoint).path

  @doc "Returns the dotted Lua path for an annotated entrypoint."
  @spec path_string(Manifest.Entrypoint.t()) :: String.t()
  def path_string(%Manifest.Entrypoint{} = entrypoint), do: config!(entrypoint).path_string

  @doc "Returns the AshLua config for an annotated entrypoint."
  @spec config(Manifest.Entrypoint.t()) :: surface_config() | nil
  def config(%Manifest.Entrypoint{config: config}) do
    Map.get(config || %{}, @config_key)
  end

  defp config!(%Manifest.Entrypoint{} = entrypoint) do
    config(entrypoint) || raise ArgumentError, "manifest entrypoint is missing AshLua metadata"
  end

  defp action_entrypoints_for_otp_app(otp_app, filter, labels) do
    filter = filter_set(filter)
    label_filter = label_filter(labels)

    otp_app
    |> Ash.Info.domains()
    |> Enum.flat_map(&action_entrypoints_for_domain(&1, filter, label_filter))
    |> Enum.sort_by(fn %{config: %{@config_key => %{path_string: path}}} -> path end)
  end

  defp action_entrypoints_for_domain(domain, filter, label_filter) do
    case AshLua.Domain.Info.namespaces(domain) do
      [] -> derived_action_entrypoints(domain, filter, label_filter)
      namespaces -> explicit_action_entrypoints(domain, namespaces, filter, label_filter)
    end
  end

  defp explicit_action_entrypoints(domain, namespaces, filter, label_filter) do
    Enum.flat_map(namespaces, fn %Namespace{name: namespace_name, actions: actions} = namespace ->
      namespace_labels = namespace_labels(namespace)
      namespace_segments = namespace_segments(namespace_name)

      actions
      |> Enum.map(&{&1, effective_labels(namespace_labels, &1)})
      |> Enum.filter(fn {%Action{} = action, labels} ->
        included?(action.resource, action.action, filter, labels, label_filter)
      end)
      |> Enum.map(fn {%Action{} = action, labels} ->
        path = namespace_segments ++ [Atom.to_string(action.name)]

        action_entrypoint(action.resource, action.action, %{
          domain: domain,
          labels: labels,
          lua_action: Atom.to_string(action.name),
          path: path,
          path_string: Enum.join(path, "."),
          path_source: :explicit
        })
      end)
    end)
  end

  defp derived_action_entrypoints(_domain, _filter, %MapSet{}), do: []

  defp derived_action_entrypoints(domain, filter, nil) do
    domain
    |> Ash.Domain.Info.resources()
    |> Enum.flat_map(fn resource ->
      if AshLua.Resource.Info.expose?(resource) do
        resource
        |> Ash.Resource.Info.actions()
        |> Enum.filter(&action_included?(resource, &1.name, filter))
        |> Enum.map(fn action ->
          path = legacy_path(resource, action.name)

          action_entrypoint(resource, action.name, %{
            domain: domain,
            labels: [],
            lua_action: Atom.to_string(action.name),
            path: path,
            path_string: Enum.join(path, "."),
            path_source: :derived
          })
        end)
      else
        []
      end
    end)
  end

  defp action_entrypoint(resource, action, config) do
    %{
      resource: resource,
      action: action,
      config: %{@config_key => config}
    }
  end

  defp merge_config(old, new) do
    Map.merge(old || %{}, new || %{}, fn
      @config_key, old_config, new_config -> Map.merge(old_config || %{}, new_config || %{})
      _key, _old_value, new_value -> new_value
    end)
  end

  defp filter_set(nil), do: nil

  defp filter_set(entries) when is_list(entries) do
    entries
    |> Enum.map(fn
      {resource, action} -> {resource, action}
      %{resource: resource, action: action} -> {resource, action}
    end)
    |> MapSet.new()
  end

  defp label_filter(nil), do: nil
  defp label_filter([]), do: nil
  defp label_filter(labels) when is_list(labels), do: MapSet.new(labels)

  defp included?(resource, action, filter, labels, label_filter) do
    action_included?(resource, action, filter) and labels_included?(labels, label_filter)
  end

  defp action_included?(_resource, _action, nil), do: true

  defp action_included?(resource, action, %MapSet{} = filter) do
    MapSet.member?(filter, {resource, action})
  end

  defp labels_included?(_labels, nil), do: true

  defp labels_included?(labels, %MapSet{} = label_filter) do
    label_filter
    |> MapSet.subset?(MapSet.new(labels))
  end

  defp namespace_labels(%Namespace{labels: labels}) when is_list(labels), do: labels
  defp namespace_labels(%Namespace{}), do: []

  defp action_labels(%Action{labels: labels}) when is_list(labels), do: labels
  defp action_labels(%Action{}), do: []

  defp effective_labels(namespace_labels, %Action{} = action) do
    (namespace_labels ++ action_labels(action))
    |> Enum.uniq()
  end

  defp otp_app_from_manifest(%Manifest{
         entrypoints: [%Manifest.Entrypoint{resource: resource} | _]
       }) do
    resource
    |> Ash.Resource.Info.domain()
    |> Spark.otp_app()
  end

  defp otp_app_from_manifest(%Manifest{}) do
    raise ArgumentError, "cannot infer otp_app from an empty manifest"
  end

  defp legacy_path(resource, action_name) do
    domain = Ash.Resource.Info.domain(resource)

    [
      AshLua.Domain.Info.name(domain),
      AshLua.Resource.Info.name(resource),
      Atom.to_string(action_name)
    ]
  end

  defp namespace_segments(name) when is_binary(name) do
    name
    |> String.split(".", trim: true)
    |> Enum.reject(&(&1 == ""))
  end

  defp namespace_segments(names) when is_list(names), do: Enum.map(names, &to_string/1)
end
