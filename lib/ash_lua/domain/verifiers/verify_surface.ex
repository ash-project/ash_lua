# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Domain.Verifiers.VerifySurface do
  @moduledoc false

  use Spark.Dsl.Verifier

  alias AshLua.Domain.{Action, Namespace}
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    domain = Verifier.get_persisted(dsl, :module)

    namespaces =
      dsl
      |> Verifier.get_entities([:lua])
      |> List.wrap()
      |> Enum.filter(&match?(%Namespace{}, &1))

    errors =
      []
      |> validate_actions(domain, namespaces)
      |> validate_duplicate_paths(namespaces)

    case Enum.reverse(errors) do
      [] -> :ok
      errors -> {:error, dsl_error(errors)}
    end
  end

  defp validate_actions(errors, domain, namespaces) do
    Enum.reduce(namespaces, errors, fn %Namespace{} = namespace, acc ->
      Enum.reduce(namespace.actions, acc, fn %Action{} = action, acc ->
        acc
        |> validate_resource_domain(domain, namespace, action)
        |> validate_action_exists(namespace, action)
      end)
    end)
  end

  defp validate_resource_domain(errors, domain, namespace, %Action{} = action) do
    case safe_resource_domain(action.resource) do
      {:ok, ^domain} ->
        errors

      {:ok, other_domain} ->
        [
          "namespace #{inspect(namespace.name)} action #{inspect(action.name)} references #{inspect(action.resource)}, which belongs to #{inspect(other_domain)} instead of #{inspect(domain)}"
          | errors
        ]

      {:error, reason} ->
        [
          "namespace #{inspect(namespace.name)} action #{inspect(action.name)} references #{inspect(action.resource)}, but its domain could not be read: #{inspect(reason)}"
          | errors
        ]
    end
  end

  defp validate_action_exists(errors, namespace, %Action{} = action) do
    case safe_action(action.resource, action.action) do
      {:ok, %{public?: true}} ->
        errors

      {:ok, %{public?: false}} ->
        [
          "namespace #{inspect(namespace.name)} action #{inspect(action.name)} references private action #{inspect(action.action)} on #{inspect(action.resource)}"
          | errors
        ]

      :error ->
        [
          "namespace #{inspect(namespace.name)} action #{inspect(action.name)} references missing action #{inspect(action.action)} on #{inspect(action.resource)}"
          | errors
        ]
    end
  end

  defp validate_duplicate_paths(errors, namespaces) do
    namespaces
    |> Enum.flat_map(fn %Namespace{} = namespace ->
      namespace_segments = namespace_segments(namespace.name)

      Enum.map(namespace.actions, fn %Action{} = action ->
        path = namespace_segments ++ [Atom.to_string(action.name)]
        {Enum.join(path, "."), action}
      end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.reduce(errors, fn
      {_path, [_one]}, acc ->
        acc

      {path, actions}, acc ->
        details =
          actions
          |> Enum.map_join(", ", &"#{inspect(&1.resource)}.#{&1.action}")

        ["duplicate Lua surface path #{inspect(path)} configured for #{details}" | acc]
    end)
  end

  defp safe_resource_domain(resource) do
    case Code.ensure_compiled(resource) do
      {:module, _} -> {:ok, Ash.Resource.Info.domain(resource)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_action(resource, action_name) do
    case Code.ensure_compiled(resource) do
      {:module, _} ->
        case Ash.Resource.Info.action(resource, action_name) do
          nil -> :error
          action -> {:ok, action}
        end

      {:error, _reason} ->
        :error
    end
  end

  defp namespace_segments(name) when is_binary(name) do
    name
    |> String.split(".", trim: true)
    |> Enum.reject(&(&1 == ""))
  end

  defp namespace_segments(names) when is_list(names), do: Enum.map(names, &to_string/1)

  defp dsl_error(errors) do
    Spark.Error.DslError.exception(
      message: """
      Invalid AshLua domain surface configuration:

      #{Enum.map_join(errors, "\n", &("- " <> &1))}
      """
    )
  end
end
