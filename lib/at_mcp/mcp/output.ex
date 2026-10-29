defmodule AtMcp.MCP.Output do
  @moduledoc """
  Shapes each tool result for its caller.

  MCP leaves it to the host to pick which half of a result to show its model.

    * Claude Code, Codex and VS Code show `structuredContent` whenever a
      result has it.
    * Gemini CLI, Goose and Imp (by default) show `content`.

  A read that returned both halves would put JSON in front of the first group
  of models, at several times the size of the text. A read therefore returns
  only `content` (`AtMcp.Reading`'s text, plus any images). A caller that
  passes `format: "json"`, or holds a grant with a json default, gets the
  summary in both halves, so it gets JSON from either kind of host.

  A write returns its summary in both halves.

  `tools/list` lists no output schema for any tool (`AtMcp.MCP.DSL`, #220),
  because MCP requires a tool with a listed schema to return structured
  content. `validate/3` checks the structured content of every result against
  its tool's schema and logs a mismatch.
  """
  require Logger
  alias ExMCP.Content.SchemaPolicy

  @formats ~w(text json)

  @doc "The formats a read can be asked for."
  def formats, do: @formats

  @doc """
  A read's result in `format`: text drops the structured content; json makes
  a result's text the JSON of it, keeping any images, and leaves a refusal
  as it is.
  """
  def shape({:ok, response, state}, format, read?) when read? and is_map(response) do
    structured = Map.get(response, :structuredContent)

    response =
      cond do
        format != "json" ->
          Map.delete(response, :structuredContent)

        # A refusal's text is already its message, and its code rides beside.
        is_map(structured) and Map.get(response, :isError) != true ->
          json = Jason.encode!(SchemaPolicy.json_compatible(structured))
          images = Enum.reject(Map.get(response, :content, []), &match?(%{type: "text"}, &1))
          %{response | content: [%{type: "text", text: json} | images]}

        true ->
          response
      end

    {:ok, response, state}
  end

  def shape(result, _format, _read?), do: result

  # The backend has already acted. A contract check must never turn that
  # result into a claim that it failed, even when the check times out or finds
  # a defect. Log only the category and tool, never account data or validation
  # messages (which can include response contents).
  def validate({:ok, response, _state} = result, name, schemas) do
    data = Map.get(response, :structuredContent) || Map.get(response, "structuredContent")

    if data do
      case SchemaPolicy.validate(SchemaPolicy.json_compatible(data), Map.fetch!(schemas, name)) do
        :ok ->
          :ok

        {:error, {:schema_validation_timeout, _}} ->
          Logger.warning("AtMcp MCP #{name}: returning unvalidated result (validation timeout)")

        {:error, _} ->
          Logger.error("AtMcp MCP #{name}: returning unvalidated result (output schema mismatch)")
      end
    end

    result
  end

  def validate(result, _name, _schemas), do: result
end
