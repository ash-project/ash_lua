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

    * `topics/1` lists general topics of functionality, e.g. `"filtering"`,
      `"pagination"`, `"error-handling"`; `topic_doc/2` renders one.
    * `list_callables/1` and `list_types/1` enumerate the documentable surface.
    * `callable_doc/2` renders one operation (e.g. `"posts.post.create"`).
    * `type_doc/2` renders one type (record type identified by its Lua path
      `"posts.post"`, or named type by its readable name).
    * `full_doc/1` concatenates everything into a single page.
  """

  alias Ash.Info.Manifest

  @type manifest_or_opts :: Manifest.t() | keyword()

  @topic_bodies %{
    "filtering" => """
    <a id="topic-filtering"></a>
    # Filtering

    List operations (the ones described as `list`) accept a `filter` reserved
    input key that narrows the result set:

    ```lua
    posts.post.read({
      filter = { published = true, author_id = uid }
    })
    ```

    Pass a table of `<field> = <value>` pairs to match by equality, or a table
    of `<field> = { <operator> = <value> }` for comparisons:

    ```lua
    posts.post.read({
      filter = {
        published = true,
        rating = { greater_than_or_equal = 4 },
        title  = { ilike = "%hello%" }
      }
    })
    ```

    Operator keys you can use include `equals`, `not_equals`, `greater_than`,
    `greater_than_or_equal`, `less_than`, `less_than_or_equal`, `in`,
    `contains`, `ilike`, and `like`. Each operator is valid for the field
    types that support it; see the record type's page for field types.

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
      message = "<top-level human-readable summary>",
      errors  = {
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

    Stable `code` values include `required`, `invalid_attribute`,
    `invalid_argument`, `invalid_query`, `not_found`, `forbidden`,
    `forbidden_field`, `invalid_primary_key`, `invalid_fields`, and a fallback
    `unknown_error` (with a `vars.uuid` to look up in host logs).

    `fields` lists the field names this error pertains to and is useful for
    surfacing validation problems next to form inputs. `vars` is a free-form
    table of interpolation values referenced from `message`.

    A failed `assert` raises with the error table as the Lua error object; you
    can `pcall` it if you need to recover from a raise.
    """
  }

  @topic_ids @topic_bodies |> Map.keys() |> Enum.sort()

  @doc """
  Returns the dotted callable paths (e.g. `"posts.post.create"`) exposed to Lua,
  in stable sorted order.
  """
  @spec list_callables(manifest_or_opts()) :: [String.t()]
  def list_callables(manifest_or_opts) do
    manifest = ensure_manifest(manifest_or_opts)

    manifest.entrypoints
    |> Enum.flat_map(&entrypoint_path/1)
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
  Renders the markdown for one operation, addressed by its dotted path.

  Returns `{:ok, markdown}` or `{:error, :not_found}`.
  """
  @spec callable_doc(manifest_or_opts(), String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def callable_doc(manifest_or_opts, path) when is_binary(path) do
    manifest = ensure_manifest(manifest_or_opts)

    case find_callable(manifest, path) do
      {:ok, {entrypoint, domain_name, resource_name}} ->
        {:ok, render_callable(manifest, entrypoint, domain_name, resource_name)}

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

    cond do
      is_atom(identifier) and Map.has_key?(type_lookup, identifier) ->
        {:ok,
         render_named_type(Map.fetch!(type_lookup, identifier), resource_lookup, type_lookup)}

      is_atom(identifier) and Map.has_key?(resource_lookup, identifier) ->
        resource = Map.fetch!(resource_lookup, identifier)
        {:ok, render_record_type(resource, resource_lookup, type_lookup)}

      is_binary(identifier) and String.contains?(identifier, ".") ->
        case find_resource_by_path(manifest, identifier) do
          {:ok, resource} -> {:ok, render_record_type(resource, resource_lookup, type_lookup)}
          :error -> {:error, :not_found}
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
    """
  end

  defp ensure_manifest(%Manifest{} = m), do: m

  defp ensure_manifest(opts) when is_list(opts) do
    {:ok, manifest} = Manifest.generate(opts)
    manifest
  end

  defp entrypoint_path(%Manifest.Entrypoint{resource: resource, action: action}) do
    if AshLua.Resource.Info.expose?(resource) do
      [resource_path(resource) <> "." <> Atom.to_string(action.name)]
    else
      []
    end
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
    Enum.reduce_while(manifest.entrypoints, :error, fn entrypoint, _acc ->
      if AshLua.Resource.Info.expose?(entrypoint.resource) do
        domain = Ash.Resource.Info.domain(entrypoint.resource)
        domain_name = AshLua.Domain.Info.name(domain)
        resource_name = AshLua.Resource.Info.name(entrypoint.resource)

        candidate =
          domain_name <> "." <> resource_name <> "." <> Atom.to_string(entrypoint.action.name)

        if candidate == path do
          {:halt, {:ok, {entrypoint, domain_name, resource_name}}}
        else
          {:cont, :error}
        end
      else
        {:cont, :error}
      end
    end)
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

  defp render_callable(manifest, entrypoint, domain_name, resource_name) do
    resource_module = entrypoint.resource
    action = entrypoint.action
    resource = Manifest.get_resource!(Manifest.resource_lookup(manifest), resource_module)
    type_lookup = Manifest.type_lookup(manifest)
    resource_lookup = Manifest.resource_lookup(manifest)

    path = domain_name <> "." <> resource_name <> "." <> Atom.to_string(action.name)

    [
      "# `#{path}`",
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
    arg_rows =
      (action.arguments || [])
      |> Enum.map(&argument_row(&1, resource_lookup, type_lookup))

    accept_rows = accepted_rows(action, resource, resource_lookup, type_lookup)
    pk_rows = pk_rows(action, resource)
    reserved_rows = reserved_rows(action)

    rows = arg_rows ++ pk_rows ++ accept_rows ++ reserved_rows

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

  defp argument_row(%Manifest.Argument{} = arg, resource_lookup, type_lookup) do
    required = if not arg.allow_nil? and not arg.has_default?, do: "yes", else: "no"

    notes =
      [
        arg.description,
        if(arg.has_default?, do: "has default"),
        if(arg.sensitive?, do: "sensitive")
      ]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.join("; ")

    "| `#{arg.name}` | #{type_link(arg.type, resource_lookup, type_lookup)} | #{required} | #{notes} |"
  end

  defp accepted_rows(
         %Manifest.Action{type: type} = action,
         resource,
         resource_lookup,
         type_lookup
       )
       when type in [:create, :update] do
    accepted = action.accept || []
    required_attrs = MapSet.new(action.require_attributes || [])
    nilable = MapSet.new(action.allow_nil_input || [])

    Enum.map(accepted, fn attr_name ->
      case Map.get(resource.fields, attr_name) do
        %Manifest.Field{} = f ->
          required =
            cond do
              MapSet.member?(required_attrs, attr_name) -> "yes"
              MapSet.member?(nilable, attr_name) -> "no"
              f.allow_nil? -> "no"
              f.has_default? -> "no"
              true -> "yes"
            end

          notes =
            [
              f.description,
              if(f.has_default?, do: "has default"),
              if(f.sensitive?, do: "sensitive")
            ]
            |> Enum.reject(&(is_nil(&1) or &1 == ""))
            |> Enum.join("; ")

          "| `#{attr_name}` | #{type_link(f.type, resource_lookup, type_lookup)} | #{required} | #{notes} |"

        _ ->
          "| `#{attr_name}` | _unknown_ | – | – |"
      end
    end)
  end

  defp accepted_rows(_, _, _, _), do: []

  defp pk_rows(%Manifest.Action{type: type}, resource)
       when type in [:update, :delete, :destroy] do
    Enum.map(resource.primary_key, fn pk ->
      type_text =
        case Manifest.Resource.get_field(resource, pk) do
          %Manifest.Field{type: t} -> "`#{type_summary(t)}`"
          _ -> "_unknown_"
        end

      "| `#{pk}` | #{type_text} | yes | identifies the record |"
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

  defp render_record_type(%Manifest.Resource{} = resource, resource_lookup, type_lookup) do
    path = resource_path(resource.module)
    anchor = path_anchor(path)

    description =
      case resource.description do
        nil -> ""
        "" -> ""
        d -> "\n\n" <> d
      end

    primary_key_line = "**Primary key:** #{Enum.map_join(resource.primary_key, ", ", &"`#{&1}`")}"

    fields_section =
      case Manifest.Resource.all_fields(resource) do
        [] ->
          ""

        fields ->
          rows =
            Enum.map_join(fields, "\n", fn %Manifest.Field{} = f ->
              row_field(f, resource_lookup, type_lookup)
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
              "| `#{r.name}` | #{r.cardinality} | #{dest} |"
            end)

          "\n\n## Related records\n\n| Name | Cardinality | Type |\n|------|-------------|------|\n" <>
            rows
      end

    """
    <a id="#{anchor}"></a>
    # Record type `#{path}`#{description}

    #{primary_key_line}#{fields_section}#{rels_section}
    """
    |> String.trim()
  end

  defp render_named_type(%Manifest.Type{} = type, resource_lookup, type_lookup) do
    anchor = name_anchor(type.name)
    header = "<a id=\"#{anchor}\"></a>\n# Type `#{type.name}`"
    body = type_body(type, resource_lookup, type_lookup)
    header <> "\n\n" <> body
  end

  defp row_field(%Manifest.Field{} = f, resource_lookup, type_lookup) do
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

    "| `#{f.name}` | #{type_link(f.type, resource_lookup, type_lookup)} | #{notes} |"
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
        record_link(type.resource_module, resource_lookup)

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
end
