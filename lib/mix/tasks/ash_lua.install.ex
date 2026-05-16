# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshLua.Install do
    @moduledoc "Installs AshLua. Should be run with `mix igniter.install ash_lua`"
    @shortdoc @moduledoc
    require Igniter.Code.Common
    use Igniter.Mix.Task

    @impl true
    def info(_argv, _source) do
      %Igniter.Mix.Task.Info{
        schema: [
          yes: :boolean
        ]
      }
    end

    @impl true
    def igniter(igniter) do
      igniter
      |> Igniter.Project.Formatter.import_dep(:ash_lua)
    end
  end
else
  defmodule Mix.Tasks.AshLua.Install do
    @moduledoc "Installs AshLua. Should be run with `mix igniter.install ash_lua`"
    @shortdoc @moduledoc

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_lua.install' requires igniter to be run.

      Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter
      """)

      exit({:shutdown, 1})
    end
  end
end
