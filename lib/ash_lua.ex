# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua do
  @moduledoc """
  AshLua exposes Ash actions to Lua scripts evaluated through the [`lua`](https://hex.pm/packages/lua)
  Elixir package, ensuring a consistent actor / tenant / context are propagated into every Ash call.

  The Lua surface is resolved from `Ash.Info.Manifest.generate/1` plus AshLua DSL. Domains with no
  explicit `lua do namespace ... end` config keep the legacy
  `<domain>.<resource>.<action>` callable shape; domains with explicit namespaces expose only their
  configured public action paths.

  ## Example

      defmodule MyApp.Accounts do
        use Ash.Domain, otp_app: :my_app, extensions: [AshLua.Domain]

        resources do
          resource MyApp.Accounts.User
        end
      end

      defmodule MyApp.Accounts.User do
        use Ash.Resource,
          domain: MyApp.Accounts,
          extensions: [AshLua.Resource]

        # ... attributes / actions ...
      end

      AshLua.eval!(\"""
        local user, err = accounts.user.create({ input = { name = "Zach" } })
        assert(err == nil)
        return user.id
      \""", otp_app: :my_app, actor: current_user)

  Action callables always return `(result, nil)` on success and `(nil, err_table)` on failure.
  Wrap a call in Lua's built-in `assert()` for raise semantics:

      local user = assert(accounts.user.create({ input = { name = "Zach" } }))

  ## Actor / tenant / context

  All three are host-supplied via the eval opts and are never reflected to or mutable from the
  script — there is no way for a Lua script to read or change the actor, tenant, or context.
  """

  @doc """
  Evaluates a Lua script in a freshly-built VM and returns `{results, %Lua{}}`.

  ## Options

    * `:otp_app` (required unless `:manifest` is given) — passed to `Ash.Info.Manifest.generate/1`.
    * `:actor`, `:tenant`, `:context` — host-supplied; merged into every Ash call.
    * `:manifest` — a pre-built `%Ash.Info.Manifest{}` to skip regeneration.
    * `:lua` — a pre-built `%Lua{}` to install bindings on (e.g. with extra `Lua.set!/3` callbacks).
    * `:lua_options` — options passed to `Lua.new/1` when `:lua` is not supplied.
    * `:forbidden_fields` — `:hide` (default) strips fields hidden by authorization from results;
      `:display` renders them as the opaque marker `%{"opaque" => "forbidden"}` so the consumer can
      tell a forbidden field apart from an absent one.
    * `:decode` — forwarded to `Lua.eval!/3`; defaults to `true`.
    * `:source` — forwarded to `Lua.eval!/3`; labels runtime errors with a script name.
  """
  @spec eval!(String.t(), keyword()) :: {list(), Lua.t()}
  def eval!(script, opts) when is_binary(script) and is_list(opts) do
    AshLua.Runtime.eval!(script, opts)
  end

  @doc """
  Builds a `%Lua{}` VM with Ash bindings installed, ready for repeated `Lua.eval!/2` calls.

  Accepts the same `:otp_app` / `:actor` / `:tenant` / `:context` / `:manifest` / `:lua` /
  `:lua_options` / `:forbidden_fields` options as `eval!/2`.
  """
  @spec new(keyword()) :: Lua.t()
  def new(opts \\ []) do
    AshLua.Runtime.build(opts)
  end

  @doc """
  Preloads cached eval manifests for every `AshLua.EvalActions` resource in an OTP app.

  This is an optional production boot-time optimization for applications that
  want to avoid rebuilding the scoped manifest on the first eval/docs call.
  Each invocation still gets a fresh Lua VM with its own actor, tenant, and
  context.
  """
  @spec preload_eval_manifests!(atom()) :: [module()]
  def preload_eval_manifests!(otp_app) when is_atom(otp_app) do
    AshLua.Surface.preload_eval_manifests!(otp_app)
  end
end
