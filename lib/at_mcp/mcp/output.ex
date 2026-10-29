defmodule AtMcp.MCP.Output do
  @moduledoc """
  What a tool's result carries for the caller that asked.

  A read is text first. MCP does not say which half of a result a host gives
  its model: Claude Code, Codex and VS Code give it `structuredContent` only,
  Gemini CLI, Goose and Imp's default `content` only. A read that returned
  both would reach half of them as JSON, several times the size of the text
  written for a model. So a read declares no output schema (a tool that
  declares one must return structured content) and, by default, returns only
  `content`: `AtMcp.Reading`'s text, and any images. A caller that wants the
  summary passes `format: "json"`, or holds a grant whose default is json,
  and gets it as `structuredContent` and as the same JSON in `content`, so it
  is JSON whichever half its host reads.

  A write keeps its small structured result, whose text is the same JSON, and
  its output schema.
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
