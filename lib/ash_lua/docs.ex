# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshLua.Docs do
  @moduledoc """
  Generates Lua-side API documentation suitable for an MCP `search_docs` / `get_docs`
  surface (notably for `ash_ai`).

  The rendered output is intended for external consumers — humans reading hexdocs or
  LLM clients picking which callable to invoke — so it deliberately avoids internal
  vocabulary. Operations are described as `get` / `list` / `create` / `update` /
  `delete` / `call`; stored, computed, and summary fields are all just "fields";
  related records are described by cardinality and a link to the related record
  type's page.

    * `topics/1` lists general topics of functionality, e.g. `"filters"`,
      `"pagination"`, `"error-handling"`; `topic_doc/2` renders one.
    * `list_callables/1` and `list_types/1` enumerate the documentable surface.
    * `callable_doc/2` renders one operation (e.g. `"posts.post.create"`).
    * `type_doc/2` renders one type (record type identified by its Lua path
      `"posts.post"`, or named type by its readable name).
    * `index_doc/1` renders a compact index — one bullet per operation, type,
      and topic — as the zero-argument landing page.
    * `full_doc/1` concatenates everything into a single page.
  """

  alias Ash.Info.Manifest

  @type manifest_or_opts :: Manifest.t() | keyword()

  @topic_bodies %{
    "filters" => """
    <a id="topic-filters"></a>
    # Filters

    List operations (the ones described as `list`) accept a `filter` reserved
    input key that narrows the result set.

    The simplest shape is a table of `<field> = <value>` pairs, all combined
    with implicit AND:

    ```lua
    posts.post.read({
      filter = { published = true, author_id = uid }
    })
    ```

    For comparisons, use a sub-table keyed by operator or predicate-function
    name:

    ```lua
    posts.post.read({
      filter = {
        rating = { greater_than_or_equal = 4 },
        title  = { contains = "hello" }
      }
    })
    ```

    Operator and predicate-function names come from the record type's
    **Filterable fields** section — each filterable field lists the operators
    that apply to it and the value type each operator expects. All names are
    plain Lua identifiers (`equals`, `not_equals`, `less_than`,
    `less_than_or_equal`, `greater_than`, `greater_than_or_equal`, `in`,
    `is_nil`, `contains`, `string_starts_with`, `string_ends_with`,
    `is_distinct_from`, `is_not_distinct_from`, …).

    ## Boolean combinators

    Three reserved keys combine sub-filters:

      * `and` — every sub-filter must match (also the implicit behaviour at the
        top level when listing multiple fields).
      * `or` — any sub-filter must match.
      * `not` — the sub-filter must not match.

    These are Lua reserved words, so write them as bracketed string keys:

    ```lua
    posts.post.read({
      filter = {
        ["and"] = {
          { published = true },
          { rating    = { greater_than_or_equal = 4 } }
        }
      }
    })

    posts.post.read({
      filter = {
        ["or"] = {
          { author_id = me },
          { author_id = friend_id }
        }
      }
    })

    posts.post.read({
      filter = {
        ["not"] = { published = true }
      }
    })
    ```

    `and` and `or` take an array of sub-filter tables; `not` takes a single
    sub-filter table. Combinators nest freely.

    `filter` is only honored on list operations. Reads of a single record by
    primary key (i.e. `get` operations and `update`/`delete` inputs) do not
    accept `filter`.
    """,
    "pagination" => """
    <a id="topic-pagination"></a>
    # Pagination

    List operations support two pagination styles. **Index-based** uses
    `limit` and `offset` and is good for "jump to page N":

    ```lua
    posts.post.read({ limit = 20, offset = 40, sort = "-created_at" })
    ```

    **Cursor-based** uses `page` and is good for stable scrolling through a
    moving feed:

    ```lua
    posts.post.read({
      page = { limit = 20, after = "<cursor-from-previous-page>" }
    })
    ```

    When you pass `page`, the result changes from a flat list of records into
    a table:

    ```lua
    {
      results = { <record>, <record>, ... },
      count   = <integer>,        -- total matching records
      limit   = <integer>,
      offset  = <integer>,        -- index-based responses
      before  = "<cursor>",       -- cursor-based responses
      after   = "<cursor>",       -- cursor-based responses
      more?   = true|false
    }
    ```

    A read without `page` still returns the bare list of records.

    `count` is only present when the operation supports it; treat its absence
    as "unknown". `more?` is the cheap, always-available signal for whether
    paging forward would yield more.
    """,
    "transactions" => """
    <a id="topic-transactions"></a>
    # Transactions

    Wrap a block of operations in a transaction with
    `utils.transaction.transact`:

    ```lua
    utils.transaction.transact({ "posts.post", "posts.comment" }, function()
      local post = assert(posts.post.create({ title = "Hello" }))
      assert(posts.comment.create({ post_id = post.id, body = "First" }))
      return post.id
    end)
    ```

    The first argument is the list of record-type paths that the transaction
    should cover — the same paths listed under `## Record types`. The second
    argument is a Lua function with no arguments.

    The call returns `(result, err)`:

      * On commit, `result` is whatever the inner function returned and
        `err` is `nil`.
      * On rollback, `result` is `nil` and `err` is the standard error
        envelope.

    Rollback happens when:

      * The body raises (typically via `assert(...)` on a failed operation,
        which raises with the operation's err table).
      * Any operation called inside the body fails — even if the script
        doesn't `assert`, an operation failure aborts the transaction.
      * The body calls `utils.transaction.rollback(message)` to abort
        explicitly.

    Example with `assert`-driven rollback:

    ```lua
    local _, err = utils.transaction.transact({ "posts.post" }, function()
      assert(posts.post.create({ title = "Will Roll Back" }))
      assert(posts.post.create({ })) -- missing required `title`, raises
    end)

    if err then
      -- Neither post exists; the whole transaction was rolled back.
    end
    ```

    Example with explicit rollback:

    ```lua
    local _, err = utils.transaction.transact({ "posts.post" }, function()
      local p = assert(posts.post.create({ title = "Tentative" }))
      if not some_business_check(p) then
        utils.transaction.rollback("post failed business check")
      end
      return p.id
    end)

    -- err.errors[1].code == "rolled_back"
    -- err.errors[1].message == "post failed business check"
    ```

    `utils.transaction.rollback(message)` aborts the surrounding transaction
    immediately. The `message` argument is optional and may be a string or
    a table with a `message` key. Calling it outside a transaction body has
    the same effect as raising a Lua error.

    Notes:

      * Pass only record types from the scoped surface (the ones listed under
        `## Record types`).
      * Not every record type can participate in a transaction; pass the
        ones that operations actually touch and the host figures out the
        right grouping.
      * The actor, tenant, and context configured for the script remain in
        effect inside the transaction body — they're host-supplied and not
        affected by the transaction call.
    """,
    "print-output" => """
    <a id="topic-print-output"></a>
    # Print output

    Anything you `print(...)` from your script comes back in the response
    as a `print_output` list, one entry per call, in call order.

    ```lua
    print("looking up post")
    print("got post", post.id)
    ```

    → `print_output = { "looking up post", "got post\\t<id>" }`
    """,
    "error-handling" => """
    <a id="topic-error-handling"></a>
    # Error handling

    Every operation returns two values: a result and an error. On success the
    error is `nil`; on failure the result is `nil` and the error is a table.

    ```lua
    local user, err = accounts.user.create({ name = "" })
    if err then
      -- handle the failure
    else
      -- use user
    end
    ```

    To raise on errors instead of branching, wrap the call in Lua's built-in
    `assert/1`:

    ```lua
    local user = assert(accounts.user.create({ name = "Zach" }))
    ```

    `assert` returns the first value when the second is `nil`, and raises
    with the second value otherwise — so it's the equivalent of an Elixir
    `!` variant for free.

    ## Error shape

    An error table has the form:

    ```lua
    {
      class  = "<invalid | forbidden | framework | unknown>",
      errors = {
        {
          message       = "<per-error message>",
          short_message = "<terse variant>",
          code          = "<stable identifier>",
          fields        = { "<field>", ... },
          vars          = { <interpolation context> }
        },
        ...
      }
    }
    ```

    The envelope's `class` is the kind of failure as a whole — `"invalid"`,
    `"forbidden"`, `"framework"`, or `"unknown"`. The per-error detail lives
    only in `errors`; there is no top-level message because picking one of the
    leaf messages would silently misrepresent multi-error responses (typical
    of validation failures with several field errors at once).

    Stable per-error `code` values include `required`, `invalid_attribute`,
    `invalid_argument`, `invalid_query`, `not_found`, `forbidden`,
    `forbidden_field`, `invalid_primary_key`, `unknown_field`, and a fallback
    `unknown_error` (with a `vars.uuid` to look up in host logs).

    `fields` lists the field names this error pertains to and is useful for
    surfacing validation problems next to form inputs. `vars` is a free-form
    table of interpolation values referenced from `message`.

    A failed `assert` raises with the error table as the Lua error object; you
    can `pcall` it if you need to recover from a raise.
    """
  }

  @topic_ids @topic_bodies |> Map.keys() |> Enum.sort()

  @topic_titles %{
    "filters" => "Filters",
    "pagination" => "Pagination",
    "transactions" => "Transactions",
    "print-output" => "Print output",
    "error-handling" => "Error handling"
  }

  @doc """
  Returns the dotted callable paths (e.g. `"posts.post.create"`) exposed to Lua,
  in stable sorted order.
  """
  @spec list_callables(manifest_or_opts()) :: [String.t()]
  def list_callables(manifest_or_opts) do
    manifest = ensure_manifest(manifest_or_opts)

    manifest.entrypoints
    |> Enum.map(&AshLua.Surface.path_string/1)
    |> Enum.sort()
  end

  @doc """
  Returns the documentable type identifiers — record types as their Lua path
  (e.g. `"posts.post"`) and named types by their readable name (e.g. `"PostStatus"`).
  Sorted.
  """
  @spec list_types(manifest_or_opts()) :: [String.t()]
  def list_types(manifest_or_opts) do
    manifest = ensure_manifest(manifest_or_opts)

    record_types = manifest.resources |> Enum.flat_map(&record_type_identifier/1)
    named_types = manifest.types |> Enum.map(& &1.name)

    (record_types ++ named_types) |> Enum.uniq() |> Enum.sort()
  end

  @doc """
  Returns the available general-topic identifiers in stable sorted order.

  Topics are short reference pages — explanations of how reserved input keys
  work, the error-handling convention, etc. — rather than per-callable or
  per-type pages.
  """
  @spec topics(manifest_or_opts()) :: [String.t()]
  def topics(_manifest_or_opts \\ []), do: @topic_ids

  @doc """
  Renders the markdown for one general topic by name.

  Returns `{:ok, markdown}` or `{:error, :not_found}`.
  """
  @spec topic_doc(manifest_or_opts(), String.t()) ::
          {:ok, String.t()} | {:error, :not_found}
  def topic_doc(_manifest_or_opts \\ [], id)

  def topic_doc(_opts, id) when is_binary(id) do
    case Map.fetch(@topic_bodies, id) do
      {:ok, body} -> {:ok, body}
      :error -> {:error, :not_found}
    end
  end

  def topic_doc(_opts, _id), do: {:error, :not_found}

  @doc """
  Searches the documentable surface for entries matching `term`.

  Returns markdown — a header plus a bulleted list of matching callables,
  record types, named types, and topics, ranked by relevance. The list is
  intended as a discovery aid: the LLM (or human) picks one name and follows
  up with `callable_doc/2` / `type_doc/2` / `topic_doc/2` for the full page.

  An empty / blank term returns an empty result page. The match limit is 20.
  """
  @spec search(manifest_or_opts(), String.t()) :: String.t()
  def search(manifest_or_opts, term) when is_binary(term) do
    manifest = ensure_manifest(manifest_or_opts)
    needle = term |> String.trim() |> String.downcase()

    if needle == "" do
      "# Search results\n\n_Please provide a search term._"
    else
      manifest
      |> collect_search_candidates()
      |> filter_and_rank(needle)
      |> render_search_results(term)
    end
  end

  @doc """
  Renders the markdown for one operation, addressed by its dotted path.

  Returns `{:ok, markdown}` or `{:error, :not_found}`.
  """
  @spec callable_doc(manifest_or_opts(), String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def callable_doc(manifest_or_opts, path) when is_binary(path) do
    manifest = ensure_manifest(manifest_or_opts)

    case find_callable(manifest, path) do
      {:ok, surface_action} ->
        {:ok, render_callable(manifest, surface_action)}

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Renders the markdown for one type. Accepts either:

    * A Lua path string like `"posts.post"` (record type).
    * A named-type readable name (the `:name` field on `Ash.Info.Manifest.Type`).
    * A module — looked up first as a named type, then as a record type.

  Returns `{:ok, markdown}` or `{:error, :not_found}`.
  """
  @spec type_doc(manifest_or_opts(), String.t() | module()) ::
          {:ok, String.t()} | {:error, :not_found}
  def type_doc(manifest_or_opts, identifier) do
    manifest = ensure_manifest(manifest_or_opts)
    resource_lookup = Manifest.resource_lookup(manifest)
    type_lookup = Manifest.type_lookup(manifest)

    op_display_map = build_op_display_map(manifest)

    cond do
      is_atom(identifier) and Map.has_key?(type_lookup, identifier) ->
        {:ok,
         render_named_type(Map.fetch!(type_lookup, identifier), resource_lookup, type_lookup)}

      is_atom(identifier) and Map.has_key?(resource_lookup, identifier) ->
        resource = Map.fetch!(resource_lookup, identifier)
        {:ok, render_record_type(resource, resource_lookup, type_lookup, op_display_map)}

      is_binary(identifier) and String.contains?(identifier, ".") ->
        case find_resource_by_path(manifest, identifier) do
          {:ok, resource} ->
            {:ok, render_record_type(resource, resource_lookup, type_lookup, op_display_map)}

          :error ->
            {:error, :not_found}
        end

      is_binary(identifier) ->
        case Enum.find(manifest.types, &(&1.name == identifier)) do
          %Manifest.Type{} = t -> {:ok, render_named_type(t, resource_lookup, type_lookup)}
          _ -> {:error, :not_found}
        end

      true ->
        {:error, :not_found}
    end
  end

  @doc """
  Renders a compact index of the scoped surface: a short preamble, the
  reserved input keys, and a bulleted list of every operation, record type,
  named type, and topic — each with a one-line summary, but no field tables or
  bodies.

  This is the zero-argument landing page. It is intentionally small: pick an id
  from the list and follow up with `name` set to that id for the full page, or
  use `search/2` to filter. Empty sections are omitted.
  """
  @spec index_doc(manifest_or_opts()) :: String.t()
  def index_doc(manifest_or_opts) do
    manifest = ensure_manifest(manifest_or_opts)
    candidates = collect_search_candidates(manifest)

    operations = Enum.filter(candidates, &(&1.kind == "operation"))
    record_types = Enum.filter(candidates, &(&1.kind == "record type"))
    topics = Enum.filter(candidates, &(&1.kind == "topic"))
    named_types = Enum.reject(candidates, &(&1.kind in ["operation", "record type", "topic"]))

    [
      index_preamble(full_doc_size_hint(manifest)),
      index_group("Topics", topics),
      index_group("Operations", operations),
      index_group("Record types", record_types),
      index_group("Named types", named_types)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  # A rough sense of how big `name = "full"` would be, so a caller can decide
  # whether to pull the whole page or drill in. We render it to measure rather
  # than estimate, then summarize — the cost is one render, not one round-trip.
  defp full_doc_size_hint(manifest) do
    chars = manifest |> full_doc() |> byte_size()
    approx_tokens = div(chars, 4)

    "~#{delimit(chars)} characters (≈#{delimit(approx_tokens)} tokens)"
  end

  defp delimit(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp index_preamble(full_size_hint) do
    """
    # API reference

    Every operation below is callable from a Lua script and returns
    `(result, err)` — success yields the result with `err == nil`, failure
    yields `(nil, err)`. Wrap a call in `assert(...)` for raise semantics.

    This is an index of the scoped surface. To read the full page for any
    entry, call this tool again with `name` set to one of the ids listed below
    (an operation, record type, named type, or topic). To filter the index by
    keyword, call with `search` set to a term.

    To pull every page at once, call with `name = "full"` — but note the full
    document is large: #{full_size_hint}. Prefer `search` or a specific `name`
    unless you really need everything.

    #{reserved_input_keys()}
    """
    |> String.trim_trailing()
  end

  defp index_group(_title, []), do: nil

  defp index_group(title, candidates) do
    bullets =
      candidates
      |> Enum.sort_by(& &1.id)
      |> Enum.map_join("\n", fn %{id: id, summary: summary} ->
        "- `#{id}` — #{summary}"
      end)

    "## #{title}\n\n#{bullets}"
  end

  @doc """
  Renders a single page containing every operation and every type.

  The "Named types" section is omitted when there are none.
  """
  @spec full_doc(manifest_or_opts()) :: String.t()
  def full_doc(manifest_or_opts) do
    manifest = ensure_manifest(manifest_or_opts)

    callable_section =
      manifest
      |> list_callables()
      |> Enum.map_join("\n\n", fn path ->
        {:ok, md} = callable_doc(manifest, path)
        md
      end)

    record_type_paths =
      manifest.resources
      |> Enum.flat_map(&record_type_identifier/1)
      |> Enum.sort()

    record_section =
      record_type_paths
      |> Enum.map_join("\n\n", fn path ->
        {:ok, md} = type_doc(manifest, path)
        md
      end)

    named_section =
      case manifest.types do
        [] ->
          nil

        types ->
          rendered =
            types
            |> Enum.sort_by(& &1.name)
            |> Enum.map_join("\n\n", fn t ->
              {:ok, md} = type_doc(manifest, t.name)
              md
            end)

          "## Named types\n\n" <> rendered
      end

    topics_section =
      @topic_ids
      |> Enum.map_join("\n\n", fn id ->
        {:ok, md} = topic_doc([], id)
        md
      end)

    sections =
      [
        preamble(),
        "## Topics\n\n" <> topics_section,
        "## Operations\n\n" <> callable_section,
        "## Record types\n\n" <> record_section,
        named_section
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  defp preamble do
    """
    # API reference

    Every operation below is callable from a Lua script. Operations return
    `(result, err)` — a successful call returns the result with `err == nil`; a
    failed call returns `(nil, err)`. Wrap a call in `assert(...)` for raise
    semantics.

    #{reserved_input_keys()}
    """
  end

  defp reserved_input_keys do
    """
    ## Reserved input keys

      * `fields` — which fields to return; selection tree (list of names and
        nested tables). Default: primary key only.
      * `filter` — narrow the result set by field values (list operations
        only). Shape is per-record-type; see each record type's page for the
        fields you can filter on.
      * `sort` — sort order: a field name (prefix `-` for descending) or a list
        of names (list operations only).
      * `limit` / `offset` — paging by index (list operations only).
      * `page` — pagination cursor: `{ limit = n, offset = n, after = "...",
        before = "..." }` (list operations only).
      * `operation` — summarize the result set instead of returning records:
        `"count"`, `"exists"`, or `{ "sum" | "avg" | "min" | "max" | "count" |
        "list" | "first", "<field>" }` (list operations only).

    Record type identifiers are documentation identifiers, not necessarily
    callable Lua namespaces. A flattened callable such as `surface.page_list`
    can still return a record documented as `surface.page`.
    """
    |> String.trim_trailing()
  end

  defp ensure_manifest(%Manifest{} = m), do: AshLua.Surface.for_manifest(m)

  defp ensure_manifest(opts) when is_list(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    {:ok, manifest} = AshLua.Surface.for_otp_app(otp_app, Keyword.delete(opts, :otp_app))
    manifest
  end

  defp record_type_identifier(%Manifest.Resource{module: module}) do
    if AshLua.Resource.Info.expose?(module) do
      [resource_path(module)]
    else
      []
    end
  end

  defp resource_path(resource) do
    domain = Ash.Resource.Info.domain(resource)
    AshLua.Domain.Info.name(domain) <> "." <> AshLua.Resource.Info.name(resource)
  end

  defp find_callable(manifest, path) do
    AshLua.Surface.find_entrypoint(manifest, path)
  end

  defp find_resource_by_path(manifest, path) do
    Enum.reduce_while(manifest.resources, :error, fn %Manifest.Resource{module: module} = r,
                                                     _acc ->
      if AshLua.Resource.Info.expose?(module) and resource_path(module) == path do
        {:halt, {:ok, r}}
      else
        {:cont, :error}
      end
    end)
  end

  defp render_callable(manifest, entrypoint) do
    resource_module = entrypoint.resource
    action = entrypoint.action
    resource = Manifest.get_resource!(Manifest.resource_lookup(manifest), resource_module)
    type_lookup = Manifest.type_lookup(manifest)
    resource_lookup = Manifest.resource_lookup(manifest)

    [
      "# `#{AshLua.Surface.path_string(entrypoint)}`",
      "**Operation:** `#{operation_kind(action)}`",
      action_description(action),
      input_section(action, resource, resource_lookup, type_lookup),
      returns_section(action, resource_module, resource_lookup, type_lookup)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp operation_kind(%Manifest.Action{type: :read, get?: true}), do: "get"
  defp operation_kind(%Manifest.Action{type: :read}), do: "list"
  defp operation_kind(%Manifest.Action{type: :create}), do: "create"
  defp operation_kind(%Manifest.Action{type: :update}), do: "update"
  defp operation_kind(%Manifest.Action{type: :destroy}), do: "delete"
  defp operation_kind(%Manifest.Action{type: :action}), do: "call"

  defp action_description(%Manifest.Action{description: nil}), do: nil
  defp action_description(%Manifest.Action{description: ""}), do: nil
  defp action_description(%Manifest.Action{description: desc}), do: desc

  defp input_section(action, resource, resource_lookup, type_lookup) do
    input_rows =
      Enum.map(action.inputs, &input_row(&1, action, resource, resource_lookup, type_lookup))

    pk_rows = pk_rows(action, resource)
    reserved_rows = reserved_rows(action)

    rows = input_rows ++ pk_rows ++ reserved_rows

    if rows == [] do
      "## Input\n\n_None._"
    else
      """
      ## Input

      | Name | Type | Required | Notes |
      |------|------|----------|-------|
      """ <> Enum.join(rows, "\n")
    end
  end

  defp input_row(%Manifest.Argument{} = input, action, resource, resource_lookup, type_lookup) do
    required = if not input.allow_nil? and not input.has_default?, do: "yes", else: "no"
    name = input_name(input, action, resource)

    notes =
      [
        input.description,
        if(input.has_default?, do: "has default"),
        if(input.sensitive?, do: "sensitive")
      ]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.join("; ")

    "| `#{name}` | #{type_link(input.type, resource_lookup, type_lookup)} | #{required} | #{notes} |"
  end

  defp input_name(
         %Manifest.Argument{name: name},
         %Manifest.Action{name: action_name, type: type},
         resource
       )
       when type in [:read, :create, :update, :destroy, :action] do
    AshLua.FieldNames.to_lua_input_name(resource.module, action_name, type, name)
  end

  defp input_name(%Manifest.Argument{name: name}, _action, _resource), do: name

  defp pk_rows(%Manifest.Action{type: type}, resource)
       when type in [:update, :delete, :destroy] do
    Enum.map(resource.primary_key, fn pk ->
      type_text =
        case Manifest.Resource.get_field(resource, pk) do
          %Manifest.Field{type: t} -> "`#{type_summary(t)}`"
          _ -> "_unknown_"
        end

      lua_name = AshLua.FieldNames.to_lua_field_name(resource.module, pk)

      "| `#{lua_name}` | #{type_text} | yes | identifies the record |"
    end)
  end

  defp pk_rows(_, _), do: []

  defp reserved_rows(action) do
    fields_row =
      if accepts_fields?(action) do
        [
          "| `fields` | _selection tree_ | no | which fields to return; default = primary key only |"
        ]
      else
        []
      end

    read_rows =
      if action.type == :read do
        [
          "| `filter` | table | no | narrow the result set by field values |",
          "| `sort` | string or list | no | sort order (`-` prefix for descending) |",
          "| `limit` | integer | no | maximum records to return |",
          "| `offset` | integer | no | records to skip |",
          "| `page` | table | no | pagination: `{ limit = n, offset = n, after = \"...\", before = \"...\" }` |",
          "| `operation` | string or `{ kind, field }` | no | summarize the result set instead of returning records: `\"count\"`, `\"exists\"`, or `{ \"sum\"\\|\"avg\"\\|\"min\"\\|\"max\"\\|\"count\"\\|\"list\"\\|\"first\", \"<field>\" }` |"
        ]
      else
        []
      end

    fields_row ++ read_rows
  end

  defp accepts_fields?(%Manifest.Action{type: :action, returns: nil}), do: false

  defp accepts_fields?(%Manifest.Action{type: :action, returns: %Manifest.Type{kind: kind}})
       when kind in [
              :string,
              :integer,
              :boolean,
              :float,
              :decimal,
              :uuid,
              :atom,
              :ci_string,
              :binary
            ],
       do: false

  defp accepts_fields?(_), do: true

  defp returns_section(action, resource_module, resource_lookup, type_lookup) do
    """
    ## Returns

    #{return_type_text(action, resource_module, resource_lookup, type_lookup)}
    """
  end

  defp return_type_text(
         %Manifest.Action{type: type},
         resource_module,
         resource_lookup,
         _type_lookup
       )
       when type in [:create, :update, :destroy] do
    "A " <> record_link(resource_module, resource_lookup) <> " record."
  end

  defp return_type_text(
         %Manifest.Action{type: :read, get?: true},
         resource_module,
         resource_lookup,
         _
       ) do
    "A single " <>
      record_link(resource_module, resource_lookup) <> " record (or `nil` if not found)."
  end

  defp return_type_text(%Manifest.Action{type: :read}, resource_module, resource_lookup, _) do
    """
    A list of #{record_link(resource_module, resource_lookup)} records.

    When called with a `page` input, returns a `{ results, count, limit, offset|before+after, more? }` table instead.
    """
  end

  defp return_type_text(%Manifest.Action{type: :action, returns: nil}, _, _, _) do
    "_unspecified_"
  end

  defp return_type_text(
         %Manifest.Action{type: :action, returns: %Manifest.Type{} = t},
         _,
         resource_lookup,
         type_lookup
       ) do
    type_link(t, resource_lookup, type_lookup)
  end

  defp render_record_type(
         %Manifest.Resource{} = resource,
         resource_lookup,
         type_lookup,
         op_display_map
       ) do
    path = resource_path(resource.module)
    anchor = path_anchor(path)

    description =
      case resource.description do
        nil -> ""
        "" -> ""
        d -> "\n\n" <> d
      end

    primary_key_line =
      "**Primary key:** " <>
        Enum.map_join(resource.primary_key, ", ", fn field ->
          "`#{AshLua.FieldNames.to_lua_field_name(resource.module, field)}`"
        end)

    fields_section =
      case Manifest.Resource.all_fields(resource) do
        [] ->
          ""

        fields ->
          rows =
            Enum.map_join(fields, "\n", fn %Manifest.Field{} = f ->
              row_field(resource, f, resource_lookup, type_lookup)
            end)

          "\n\n## Fields\n\n| Name | Type | Notes |\n|------|------|-------|\n" <> rows
      end

    rels_section =
      case Manifest.Resource.all_relationships(resource) do
        [] ->
          ""

        rels ->
          rows =
            Enum.map_join(rels, "\n", fn r ->
              dest = record_link(r.destination, resource_lookup)
              name = AshLua.FieldNames.to_lua_field_name(resource.module, r.name)
              "| `#{name}` | #{r.cardinality} | #{dest} |"
            end)

          "\n\n## Related records\n\n| Name | Cardinality | Type |\n|------|-------------|------|\n" <>
            rows
      end

    filterable_section =
      filterable_fields_section(resource, resource_lookup, type_lookup, op_display_map)

    sortable_section = sortable_fields_section(resource)

    """
    <a id="#{anchor}"></a>
    # Record type `#{path}`#{description}

    #{primary_key_line}#{fields_section}#{rels_section}#{filterable_section}#{sortable_section}
    """
    |> String.trim()
  end

  defp filterable_fields_section(resource, resource_lookup, type_lookup, op_display_map) do
    filterable =
      resource
      |> Manifest.Resource.all_fields()
      |> Enum.filter(& &1.filterable?)

    case filterable do
      [] ->
        ""

      fields ->
        body =
          Enum.map_join(fields, "\n\n", fn field ->
            field_filter_block(resource, field, resource_lookup, type_lookup, op_display_map)
          end)

        "\n\n## Filterable fields\n\nThe `filter` reserved input on list operations accepts these per-field forms. See the **Filters** topic for the overall expression shape, including boolean combinators.\n\n" <>
          body
    end
  end

  defp field_filter_block(
         %Manifest.Resource{} = resource,
         %Manifest.Field{} = field,
         resource_lookup,
         type_lookup,
         op_display_map
       ) do
    operators = field.filter_operators || []
    functions = field.filter_functions || []
    custom_exprs = field.filter_custom_expressions || []

    header =
      "### `#{AshLua.FieldNames.to_lua_field_name(resource.module, field.name)}` (#{type_link(field.type, resource_lookup, type_lookup)})"

    lines =
      Enum.map(
        operators,
        &applicable_line(&1, field.type, resource_lookup, type_lookup, op_display_map)
      ) ++
        Enum.map(
          functions,
          &applicable_line(&1, field.type, resource_lookup, type_lookup, op_display_map)
        ) ++
        Enum.map(
          custom_exprs,
          &applicable_line(&1, field.type, resource_lookup, type_lookup, op_display_map)
        )

    case lines do
      [] -> header <> "\n\n  - _no operators applicable_"
      _ -> header <> "\n\n" <> Enum.map_join(lines, "\n", &("  - " <> &1))
    end
  end

  defp applicable_line(
         %{name: name, rhs: rhs},
         field_type,
         resource_lookup,
         type_lookup,
         op_display_map
       ) do
    "`#{display_op_name(name, op_display_map)}` — value: " <>
      render_rhs(rhs, field_type, resource_lookup, type_lookup)
  end

  defp render_rhs(:same, field_type, resource_lookup, type_lookup) do
    type_link(field_type, resource_lookup, type_lookup)
  end

  defp render_rhs(:any, _field_type, _rl, _tl), do: "any"

  defp render_rhs({:array, inner}, field_type, rl, tl) do
    "list of " <> render_rhs(inner, field_type, rl, tl)
  end

  defp render_rhs({:concrete, atom}, _field_type, resource_lookup, type_lookup)
       when is_atom(atom) do
    cond do
      Map.has_key?(type_lookup, atom) ->
        type = Map.fetch!(type_lookup, atom)
        "[`#{type.name}`](##{name_anchor(type.name)})"

      Map.has_key?(resource_lookup, atom) ->
        record_link(atom, resource_lookup)

      module_atom?(atom) ->
        "`" <> AshLua.Type.type_name(atom) <> "`"

      true ->
        "`#{atom}`"
    end
  end

  defp render_rhs(other, _field_type, _rl, _tl), do: "`#{inspect(other)}`"

  defp module_atom?(atom) when is_atom(atom) do
    atom |> Atom.to_string() |> String.starts_with?("Elixir.")
  end

  defp build_op_display_map(%Manifest{filter_capabilities: nil}), do: %{}

  defp build_op_display_map(%Manifest{filter_capabilities: %Manifest.FilterCapabilities{} = caps}) do
    Map.new(caps.operators, fn op ->
      candidates = Enum.filter([op.name | op.aliases || []], &valid_lua_identifier?/1)

      chosen =
        case candidates do
          [] -> op.name
          list -> Enum.min_by(list, &(&1 |> Atom.to_string() |> byte_size()))
        end

      {op.name, chosen}
    end)
  end

  defp valid_lua_identifier?(name) when is_atom(name) do
    name |> Atom.to_string() |> String.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/)
  end

  defp display_op_name(name, op_display_map) when is_atom(name) do
    Map.get(op_display_map, name, name)
  end

  defp sortable_fields_section(resource) do
    sortable =
      resource
      |> Manifest.Resource.all_fields()
      |> Enum.filter(& &1.sortable?)
      |> Enum.map(&AshLua.FieldNames.to_lua_field_name(resource.module, &1.name))

    case sortable do
      [] ->
        ""

      names ->
        "\n\n## Sortable fields\n\nThe `sort` reserved input on list operations accepts these field names (prefix with `-` for descending).\n\n" <>
          Enum.map_join(names, "\n", &"  - `#{&1}`")
    end
  end

  defp render_named_type(
         %Manifest.Type{kind: :embedded_resource, resource: %Manifest.Resource{} = resource},
         resource_lookup,
         type_lookup
       ) do
    anchor = name_anchor(resource.name)
    header = "<a id=\"#{anchor}\"></a>\n# Embedded type `#{resource.name}`"

    description =
      case resource.description do
        nil -> ""
        "" -> ""
        d -> "\n\n" <> d
      end

    fields_section =
      case Manifest.Resource.all_fields(resource) do
        [] ->
          ""

        fields ->
          rows =
            Enum.map_join(fields, "\n", fn %Manifest.Field{} = f ->
              row_field(resource, f, resource_lookup, type_lookup)
            end)

          "\n\n## Fields\n\n| Name | Type | Notes |\n|------|------|-------|\n" <> rows
      end

    String.trim(header <> description <> fields_section)
  end

  defp render_named_type(%Manifest.Type{} = type, resource_lookup, type_lookup) do
    anchor = name_anchor(type.name)
    header = "<a id=\"#{anchor}\"></a>\n# Type `#{type.name}`"
    body = type_body(type, resource_lookup, type_lookup)
    header <> "\n\n" <> body
  end

  defp row_field(
         %Manifest.Resource{} = resource,
         %Manifest.Field{} = f,
         resource_lookup,
         type_lookup
       ) do
    notes =
      [
        f.description,
        kind_note(f),
        if(f.primary_key?, do: "primary key"),
        if(f.sensitive?, do: "sensitive"),
        if(f.kind == :calculation and f.arguments not in [nil, []],
          do: "input: " <> args_summary(f.arguments)
        )
      ]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.join("; ")

    name = AshLua.FieldNames.to_lua_field_name(resource.module, f.name)
    "| `#{name}` | #{type_link(f.type, resource_lookup, type_lookup)} | #{notes} |"
  end

  defp kind_note(%Manifest.Field{kind: :calculation}), do: "computed"

  defp kind_note(%Manifest.Field{kind: :aggregate, aggregate_kind: kind}),
    do: aggregate_phrase(kind)

  defp kind_note(_), do: nil

  defp aggregate_phrase(:count), do: "summary (count of related records)"
  defp aggregate_phrase(:exists), do: "summary (whether any related records exist)"
  defp aggregate_phrase(:sum), do: "summary (sum)"
  defp aggregate_phrase(:avg), do: "summary (average)"
  defp aggregate_phrase(:min), do: "summary (minimum)"
  defp aggregate_phrase(:max), do: "summary (maximum)"
  defp aggregate_phrase(:first), do: "summary (first)"
  defp aggregate_phrase(:list), do: "summary (list of related values)"
  defp aggregate_phrase(other) when is_atom(other), do: "summary (#{other})"
  defp aggregate_phrase(_), do: "summary"

  defp args_summary(arguments) do
    Enum.map_join(arguments, ", ", fn arg ->
      "`#{arg.name}: #{type_summary(arg.type)}`"
    end)
  end

  defp type_body(%Manifest.Type{kind: :enum, values: values}, _rl, _tl) do
    list = values |> Enum.map_join("\n", &"  - `#{&1}`")
    "**Kind:** enum\n\n**Allowed values:**\n\n" <> list
  end

  defp type_body(%Manifest.Type{kind: kind, fields: fields}, rl, tl)
       when kind in [:map, :struct, :keyword] and is_list(fields) do
    rows =
      Enum.map_join(fields, "\n", fn %{name: name, type: type, allow_nil?: nilable} ->
        "| `#{name}` | #{type_link(type, rl, tl)} | #{if(nilable, do: "no", else: "yes")} |"
      end)

    "**Kind:** structured value\n\n**Fields:**\n\n| Name | Type | Required |\n|------|------|----------|\n" <>
      rows
  end

  defp type_body(%Manifest.Type{kind: :union, members: members}, rl, tl) do
    rows =
      Enum.map_join(members, "\n", fn member ->
        "| `#{member.name}` | #{type_link(member.type, rl, tl)} |"
      end)

    "**Kind:** one-of\n\n**Members:**\n\n| Name | Type |\n|------|------|\n" <> rows
  end

  defp type_body(%Manifest.Type{kind: :tuple, element_types: ets}, rl, tl) when is_list(ets) do
    rows =
      ets
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {%{name: name, type: type, allow_nil?: nilable}, idx} ->
        "| #{idx} | `#{name}` | #{type_link(type, rl, tl)} | #{if(nilable, do: "no", else: "yes")} |"
      end)

    "**Kind:** tuple\n\n**Elements:**\n\n| Index | Name | Type | Required |\n|-------|------|------|----------|\n" <>
      rows
  end

  defp type_body(%Manifest.Type{} = t, _rl, _tl) do
    "**Kind:** `#{t.kind}`"
  end

  defp type_link(%Manifest.Type{} = type, resource_lookup, type_lookup) do
    case type.kind do
      :resource ->
        record_link(type.resource_module, resource_lookup)

      :embedded_resource ->
        case Map.get(type_lookup, type.resource_module) do
          %Manifest.Type{name: name} -> "[`#{name}`](##{name_anchor(name)})"
          _ -> "`embedded record`"
        end

      :type_ref ->
        case Map.get(type_lookup, type.module) do
          nil -> "`#{type.name}`"
          resolved -> "[`#{resolved.name}`](##{name_anchor(resolved.name)})"
        end

      :array ->
        "list of " <> type_link(type.item_type, resource_lookup, type_lookup)

      _ ->
        "`" <> type_summary(type) <> "`"
    end
  end

  defp type_summary(%Manifest.Type{kind: :array, item_type: inner}),
    do: "[#{type_summary(inner)}]"

  defp type_summary(%Manifest.Type{kind: :enum, name: name}), do: "enum:#{name}"
  defp type_summary(%Manifest.Type{kind: :union}), do: "one-of"

  defp type_summary(%Manifest.Type{kind: :map, fields: fields}) when is_list(fields),
    do: "structured value"

  defp type_summary(%Manifest.Type{kind: :map}), do: "map"
  defp type_summary(%Manifest.Type{kind: :tuple}), do: "tuple"
  defp type_summary(%Manifest.Type{kind: :keyword}), do: "structured value"

  defp type_summary(%Manifest.Type{kind: :resource}), do: "record"
  defp type_summary(%Manifest.Type{kind: :embedded_resource}), do: "embedded record"
  defp type_summary(%Manifest.Type{kind: :type_ref, name: name}), do: name
  defp type_summary(%Manifest.Type{kind: kind}), do: Atom.to_string(kind)

  defp record_link(module, resource_lookup) do
    case Map.get(resource_lookup, module) do
      %Manifest.Resource{module: m} ->
        path = resource_path(m)
        "[`#{path}`](##{path_anchor(path)})"

      _ ->
        "`record`"
    end
  end

  defp path_anchor(path), do: String.replace(path, ~r/[^a-z0-9]+/i, "-")

  defp name_anchor(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
  end

  # ── search helpers ──────────────────────────────────────────────────────────

  defp collect_search_candidates(manifest) do
    callables =
      manifest.entrypoints
      |> Enum.map(&callable_candidate/1)

    record_types =
      manifest.resources
      |> Enum.flat_map(fn %Manifest.Resource{module: module} = resource ->
        if AshLua.Resource.Info.expose?(module) do
          [record_type_candidate(resource)]
        else
          []
        end
      end)

    named_types = Enum.map(manifest.types, &named_type_candidate/1)
    topics = Enum.map(@topic_ids, &topic_candidate/1)

    record_types ++ callables ++ named_types ++ topics
  end

  defp callable_candidate(%Manifest.Entrypoint{} = entrypoint) do
    %{
      id: AshLua.Surface.path_string(entrypoint),
      kind: "operation",
      summary: callable_summary(entrypoint)
    }
  end

  defp callable_summary(%Manifest.Entrypoint{action: action} = entrypoint) do
    case action.description do
      nil -> "#{operation_kind(action)} operation `#{AshLua.Surface.path_string(entrypoint)}`"
      "" -> "#{operation_kind(action)} operation `#{AshLua.Surface.path_string(entrypoint)}`"
      desc -> desc
    end
  end

  defp record_type_candidate(%Manifest.Resource{} = resource) do
    %{
      id: resource_path(resource.module),
      kind: "record type",
      summary: record_type_candidate_summary(resource)
    }
  end

  defp record_type_candidate_summary(%Manifest.Resource{description: d})
       when is_binary(d) and d != "",
       do: d

  defp record_type_candidate_summary(_), do: "record type"

  defp named_type_candidate(%Manifest.Type{kind: :embedded_resource} = type) do
    summary =
      case type.resource do
        %Manifest.Resource{description: d} when is_binary(d) and d != "" -> d
        _ -> "embedded record type"
      end

    %{id: type.name, kind: "embedded record type", summary: summary}
  end

  defp named_type_candidate(%Manifest.Type{name: name, kind: kind}) do
    %{id: name, kind: "type (#{kind})", summary: "named #{kind} type"}
  end

  defp topic_candidate(id) do
    %{id: id, kind: "topic", summary: Map.get(@topic_titles, id, id)}
  end

  defp filter_and_rank(candidates, needle) do
    candidates
    |> Enum.map(fn cand -> {cand, score_candidate(cand, needle)} end)
    |> Enum.filter(fn {_cand, score} -> score > 0 end)
    |> Enum.sort_by(fn {_cand, score} -> -score end)
    |> Enum.take(20)
    |> Enum.map(fn {cand, _score} -> cand end)
  end

  defp score_candidate(%{id: id, summary: summary}, needle) do
    id_l = String.downcase(id)
    sum_l = summary |> to_string() |> String.downcase()
    segments = String.split(id_l, ".")

    cond do
      id_l == needle -> 1000
      String.starts_with?(id_l, needle <> ".") -> 800
      needle in segments -> 700
      String.starts_with?(id_l, needle) -> 600
      String.contains?(id_l, needle) -> 500
      String.contains?(sum_l, needle) -> 100
      true -> 0
    end
  end

  defp render_search_results([], term) do
    "# Search results for `#{term}`\n\n_No matches._\n\n" <>
      "Use `name` instead of `search` to fetch a known doc by exact id."
  end

  defp render_search_results(matches, term) do
    bullets =
      Enum.map_join(matches, "\n", fn %{id: id, kind: kind, summary: summary} ->
        "- `#{id}` (#{kind}) — #{summary}"
      end)

    "# Search results for `#{term}`\n\n#{bullets}\n\n_#{length(matches)} result#{if length(matches) == 1, do: "", else: "s"}._"
  end
end
