defmodule AtMcp.MCP.DSL do
  @moduledoc false

  # `ExMCP.Server.DSL` stores its options as written, unevaluated, and calls
  # `to_string/1` on the version when it expands, so the version must reach it
  # as a literal. This expands to that `use` with mix.exs's version in place,
  # read when `AtMcp.MCP.Server` compiles; mix.exs stays the one place it is
  # written.
  defmacro __using__(_opts) do
    version = Mix.Project.config()[:version]

    quote do
      use ExMCP.Server.DSL, name: "at_mcp", version: unquote(version)
      import ExMCP.Server.DSL, except: [tool: 3]
      import AtMcp.MCP.DSL, only: [tool: 3, write_description: 2, write_annotations: 2]
      Module.register_attribute(__MODULE__, :at_mcp_output_schemas, accumulate: true)
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

    schema =
      case schemas do
        [{:output_schema, _, [schema]}] -> schema
        _ -> raise ArgumentError, "every AtMcp tool must declare exactly one output_schema"
      end

    quote do
      @at_mcp_output_schemas {unquote(name), unquote(schema)}
      ExMCP.Server.DSL.tool unquote(name), unquote(description) do
        unquote({:__block__, [], body})
      end
    end
  end

  defmacro __before_compile__(env) do
    schemas = env.module |> Module.get_attribute(:at_mcp_output_schemas) |> Map.new()

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
      defoverridable handle_list_tools: 2, handle_call_tool: 3

      @impl true
      def handle_list_tools(cursor, state) do
        {:ok, tools, next, state} = super(cursor, state)
        schemas = unquote(Macro.escape(schemas))
        tools = Enum.map(tools, &Map.put(&1, :outputSchema, Map.fetch!(schemas, &1.name)))
        {:ok, tools, next, state}
      end

      @impl true
      def handle_call_tool(name, arguments, state) do
        inputs = unquote(Macro.escape(inputs))

        case Map.fetch(inputs, name) do
          :error ->
            # Preserve upstream's unknown-tool JSON-RPC error.
            super(name, arguments, state)

          {:ok, schema} ->
            case AtMcp.MCP.Input.validate(arguments, schema) do
              :ok ->
                result = super(name, arguments, state)
                AtMcp.MCP.Output.validate(result, name, unquote(Macro.escape(compiled)))

              {:error, response} ->
                {:ok, response, state}
            end
        end
      end
    end
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

  # The published wire annotation stays across the rename for existing hosts.
  # `kite/publicWrite` is what a host counting the account's writes reads:
  # `Dwell.Capabilities` spends a turn's write allowance only on a tool that
  # does not set it false.
  @doc false
  defmacro write_annotations(verb, {:%{}, meta, pairs}) when is_atom(verb),
    do: {:%{}, meta, pairs ++ [{:"kite/publicWrite", AtMcp.Effects.counts_against_quota?(verb)}]}
end
