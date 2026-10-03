defmodule AtMcp.MCP.Output do
  @moduledoc false
  require Logger
  alias ExMCP.Content.SchemaPolicy

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
