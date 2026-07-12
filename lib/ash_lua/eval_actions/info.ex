# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.EvalActions.Info do
  @moduledoc "Introspection helpers for the `AshLua.EvalActions` extension."

  alias AshLua.EvalActions.Expose
  alias Spark.Dsl.Extension

  @doc "Returns the configured `%Expose{}` entries (one per `resource ...` entry)."
  @spec exposes(Ash.Resource.t() | Spark.Dsl.t()) :: [Expose.t()]
  def exposes(resource), do: Extension.get_entities(resource, [:eval_actions]) || []

  @doc "Mapped action labels exposed to the synthesized eval/docs actions."
  @spec labels(Ash.Resource.t() | Spark.Dsl.t()) :: [atom()]
  def labels(resource),
    do: Extension.get_opt(resource, [:eval_actions], :labels, [])

  @doc "Name of the synthesized eval action. Defaults to `:eval`."
  @spec eval_action_name(Ash.Resource.t() | Spark.Dsl.t()) :: atom()
  def eval_action_name(resource),
    do: Extension.get_opt(resource, [:eval_actions], :eval_action_name, :eval)

  @doc "Name of the synthesized docs action. Defaults to `:docs`."
  @spec docs_action_name(Ash.Resource.t() | Spark.Dsl.t()) :: atom()
  def docs_action_name(resource),
    do: Extension.get_opt(resource, [:eval_actions], :docs_action_name, :docs)

  @doc """
  How forbidden fields are rendered in `:eval` results — `:hide` (default) or `:display`.
  """
  @spec forbidden_fields(Ash.Resource.t() | Spark.Dsl.t()) :: :hide | :display
  def forbidden_fields(resource),
    do: Extension.get_opt(resource, [:eval_actions], :forbidden_fields, :hide)

  @doc """
  OTP app to scan when building the manifest for `:eval` / `:docs`.

  Falls back to the resource's domain's `:otp_app` when not explicitly configured.
  """
  @spec otp_app(Ash.Resource.t() | Spark.Dsl.t()) :: atom() | nil
  def otp_app(resource) do
    Extension.get_opt(resource, [:eval_actions], :otp_app, nil) ||
      derive_otp_app(resource)
  end

  defp derive_otp_app(resource) when is_atom(resource) do
    with domain when not is_nil(domain) <- Ash.Resource.Info.domain(resource) do
      Spark.otp_app(domain)
    end
  end

  defp derive_otp_app(_), do: nil

  @doc """
  Returns the `{resource, action}` tuples to filter the manifest by — one per
  declared `(resource, action)` pair. `:all` expands to every public action on
  the resource at the time of expansion.
  """
  @spec action_entrypoints(Ash.Resource.t() | Spark.Dsl.t()) :: [{module(), atom()}]
  def action_entrypoints(resource) do
    {:ok, manifest} = AshLua.Surface.for_eval_resource(resource)

    AshLua.Surface.action_entrypoints(manifest)
  end

  @doc false
  @spec exposed_action_entrypoints(Ash.Resource.t() | Spark.Dsl.t()) :: [{module(), atom()}]
  def exposed_action_entrypoints(resource) do
    resource
    |> exposes()
    |> Enum.flat_map(&expand_expose/1)
  end

  defp expand_expose(%Expose{resource: mod, actions: :all}) do
    mod
    |> Ash.Resource.Info.actions()
    |> Enum.map(&{mod, &1.name})
  end

  defp expand_expose(%Expose{resource: mod, actions: actions}) when is_list(actions) do
    Enum.map(actions, &{mod, &1})
  end
end
