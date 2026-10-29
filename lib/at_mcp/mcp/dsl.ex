defmodule AtMcp.MCP.DSL do
  @moduledoc false

  # `ExMCP.Server.DSL` takes the server's version as a literal and builds it
  # into `handle_initialize/2` and `__server_info__/0` when the module
  # compiles. Mix does not recompile when only the release version changes
  # (`RELEASE_VERSION`), so a version read then could outlive its build.
  # `__before_compile__/1` below replaces both with `server_info/0`, which reads
  # the running application's version, the one every other endpoint reports.
  defmacro __using__(_opts) do
    quote do
      use ExMCP.Server.DSL, name: "at_mcp"
      import ExMCP.Server.DSL, except: [tool: 3]
      import AtMcp.MCP.DSL, only: [tool: 3, write_description: 2, write_annotations: 2]
      Module.register_attribute(__MODULE__, :at_mcp_output_schemas, accumulate: true)
      Module.register_attribute(__MODULE__, :at_mcp_reads, accumulate: true)
      @before_compile AtMcp.MCP.DSL
    end
  end

  # Keep output schemas beside their tools, but do not pass them to ExMCP's
  # post-handler validation. Upstream 1.5.0 converts a validation timeout into
  # isError after a write has already completed. AtMcp owns that policy instead:
  # validation diagnoses our response contract, never changes the action's
  # outcome. Remove this adapter when upstream supports that policy directly.
  defmacro tool(name, description, do: block) do
    statements =
      case block do
        {:__block__, _, statements} -> statements
        statement -> [statement]
      end

    {schemas, body} = Enum.split_with(statements, &match?({:output_schema, _, [_]}, &1))

    # A tool counts as a read when its `readOnlyHint` is true, which is also
    # the test `AtMcp.Grants` uses for the read scope. Each read gets a
    # `format` argument. The annotations are evaluated as ExMCP evaluates
    # them, so the hint read here is the one the tool publishes whatever
    # expression gives it; `__before_compile__/1` checks the two agree.
    read? =
      Enum.any?(body, fn
        {:annotations, _, [annotations]} -> read_only?(annotations, __CALLER__)
        _ -> false
      end)

    body =
      if read?,
        do: body ++ [quote(do: param(:format, :string, AtMcp.MCP.Schemas.read_format()))],
        else: body

    schema =
      case schemas do
        [{:output_schema, _, [schema]}] -> schema
        _ -> raise ArgumentError, "every AtMcp tool must declare exactly one output_schema"
      end

    quote do
      @at_mcp_output_schemas {unquote(name), unquote(schema)}
      @at_mcp_reads unquote(if read?, do: name)
      ExMCP.Server.DSL.tool unquote(name), unquote(description) do
        unquote({:__block__, [], body})
      end
    end
  end

  defmacro __before_compile__(env) do
    schemas = env.module |> Module.get_attribute(:at_mcp_output_schemas) |> Map.new()

    reads =
      env.module |> Module.get_attribute(:at_mcp_reads) |> Enum.reject(&is_nil/1) |> MapSet.new()

    published =
      for {definition, _handler, _params} <- Module.get_attribute(env.module, :ex_mcp_dsl_tools),
          read_only_hint?(definition),
          into: MapSet.new(),
          do: definition.name

    # The reads given `format`, and stripped of their output schema, are the
    # tools whose published `readOnlyHint` is true, or the build stops.
    unless MapSet.equal?(reads, published) do
      raise CompileError,
        description:
          "AtMcp.MCP.DSL found reads #{inspect(Enum.sort(reads))} but the tools publish " <>
            "readOnlyHint on #{inspect(Enum.sort(published))}"
    end

    # Read the schema already built by ExMCP from each tool's params. Keeping
    # it here avoids a second declaration or validation after effects ran.
    inputs =
      env.module
      |> Module.get_attribute(:ex_mcp_dsl_tools)
      |> Map.new(fn {definition, _handler, _params} ->
        {definition.name, definition.inputSchema}
      end)
      |> compile_schemas()

    compiled =
      Map.new(schemas, fn {name, schema} ->
        case ExMCP.Content.SchemaValidator.compile_schema(schema, resolve_timeout_ms: 5_000) do
          {:ok, resolved} ->
            {name, resolved}

          {:error, reason} ->
            raise ArgumentError, "invalid output schema for #{name}: #{inspect(reason)}"
        end
      end)

    quote do
      defoverridable handle_list_tools: 2,
                     handle_call_tool: 3,
                     handle_initialize: 2,
                     __server_info__: 0

      @impl true
      def handle_initialize(params, state) do
        {:ok, result, state} = super(params, state)
        {:ok, Map.put(result, "serverInfo", __server_info__()), state}
      end

      @doc false
      # Every tool's output schema, the reads' included, which `tools/list`
      # leaves out: what a read's json is checked against.
      def __output_schemas__, do: unquote(Macro.escape(schemas))

      @doc false
      def __server_info__,
        do: Map.new(server_info(), fn {key, value} -> {to_string(key), value} end)

      @impl true
      def handle_list_tools(cursor, state) do
        {:ok, tools, next, state} = super(cursor, state)

        # tools/list includes no output schemas. A tool that lists one has to
        # return structured content, and reads return text unless the caller
        # asks for json (`AtMcp.MCP.Output`). Write results are small and come
        # back both as structured content and as the same JSON in text. After
        # #210, the write schemas were 243 KB of a 338 KB list. `AtMcp.MCP.Output`
        # still validates every result against its schema (`__output_schemas__/0`).
        {:ok, AtMcp.MCP.DSL.offered(tools, state), next, state}
      end

      @impl true
      def handle_call_tool(name, arguments, state) do
        inputs = unquote(Macro.escape(inputs))

        case Map.fetch(inputs, name) do
          :error ->
            # Preserve upstream's unknown-tool JSON-RPC error.
            super(name, arguments, state)

          {:ok, schema} ->
            arguments = AtMcp.MCP.Input.drop_empty(name, arguments, schema)

            case AtMcp.MCP.Input.validate(arguments, schema) do
              :ok ->
                case AtMcp.MCP.WebLinks.resolve(name, arguments, state) do
                  {:ok, resolved_arguments, resolved} ->
                    result =
                      super(name, resolved_arguments, state)
                      |> AtMcp.MCP.Input.note_ignored(AtMcp.MCP.Input.ignored(arguments, schema))
                      |> AtMcp.MCP.WebLinks.note(resolved)

                    result
                    |> AtMcp.MCP.Output.validate(name, unquote(Macro.escape(compiled)))
                    |> AtMcp.MCP.Output.shape(
                      AtMcp.MCP.DSL.format(arguments, state),
                      MapSet.member?(unquote(Macro.escape(reads)), name)
                    )

                  {:error, reason} ->
                    AtMcp.MCP.Tools.respond({:error, reason}, state)
                end

              {:error, response} ->
                {:ok, response, state}
            end
        end
      end
    end
  end

  # tools/list offers a client the tools it may call, filtered three times:
  #   1. by its grant's scope, through the same `AtMcp.Grants.permits_scope?/2`
  #      that refuses an out-of-scope `tools/call`;
  #   2. by its tool set (`AtMcp.MCP.ToolSet`), which is the default set unless
  #      the grant or `AT_MCP_TOOLS` asks for the full one;
  #   3. by what its network serves (`AtMcp.MCP.Served`).
  # The stdio server has no scope, so only steps 2 and 3 apply to it.
  # `AtMcp.Grants` and the tool surface test pass a bare `:state` and get every
  # tool. A grant's scope and set are fixed when it is issued, so the list
  # stays the same for the whole session and the server never sends
  # `notifications/tools/list_changed`.
  @doc false
  def offered(tools, %{scope: scope} = state) when not is_nil(scope),
    do:
      tools
      |> Enum.filter(&AtMcp.Grants.permits_scope?(scope, &1.name))
      |> offered(Map.delete(state, :scope))

  def offered(tools, state) when is_map(state),
    do:
      tools
      |> AtMcp.MCP.ToolSet.offered(AtMcp.MCP.ToolSet.of(state))
      |> AtMcp.MCP.Served.offered()

  def offered(tools, _state), do: tools

  # The format a read was asked for, else the grant's default
  # (`AtMcp.Grants`), else text.
  @doc false
  def format(arguments, state) do
    Map.get(arguments, "format") || Map.get(arguments, :format) ||
      (is_map(state) && Map.get(state, :format)) || "text"
  end

  defp compile_schemas(schemas) do
    Map.new(schemas, fn {name, schema} ->
      case ExMCP.Content.SchemaValidator.compile_schema(schema, resolve_timeout_ms: 5_000) do
        {:ok, resolved} ->
          {name, resolved}

        {:error, reason} ->
          raise ArgumentError, "invalid input schema for #{name}: #{inspect(reason)}"
      end
    end)
  end

  @doc "The sentence a write tool's description ends with."
  def quota_sentence(true), do: "Counts against the account's write quota."
  def quota_sentence(false), do: "Does not count against the account's write quota."

  # A write tool's description and annotations say whether it counts against the
  # write quota, read from `AtMcp.Effects.counts_against_quota?/1` — the list
  # the reservation itself reads — so neither can disagree with what the call
  # does. `ExMCP.Server.DSL` accepts only literals there and expands a macro
  # before reading one, which is why these are macros.

  @doc false
  defmacro write_description(verb, description) when is_atom(verb) and is_binary(description),
    do: description <> " " <> quota_sentence(AtMcp.Effects.counts_against_quota?(verb))

  # `at_mcp/publicWrite` is what a host counting the account's writes reads: a
  # host can spend a turn's write allowance only on a tool that does not set it
  # false.
  @doc false
  defmacro write_annotations(verb, {:%{}, meta, pairs}) when is_atom(verb) do
    counts? = AtMcp.Effects.counts_against_quota?(verb)
    {:%{}, meta, pairs ++ [{:"at_mcp/publicWrite", counts?}]}
  end

  # Whether a tool's `annotations(...)` argument sets `readOnlyHint` to true,
  # evaluated in the caller as ExMCP's DSL evaluates it.
  defp read_only?(annotations, caller) do
    {value, _binding} = annotations |> Macro.expand(caller) |> Code.eval_quoted([], caller)
    read_only_hint?(%{annotations: value})
  end

  defp read_only_hint?(%{annotations: annotations}) when is_map(annotations),
    do: Map.get(annotations, :readOnlyHint, Map.get(annotations, "readOnlyHint")) == true

  defp read_only_hint?(%{annotations: annotations}) when is_list(annotations),
    do: read_only_hint?(%{annotations: Map.new(annotations)})

  defp read_only_hint?(_definition), do: false
end
