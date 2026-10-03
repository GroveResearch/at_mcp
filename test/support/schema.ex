defmodule AtMcp.Test.Schema do
  @moduledoc """
  Whether data satisfies a tool's declared output schema.

  `ExMCP.Content.SchemaPolicy.validate/3` answers within a wall-clock deadline
  (100ms by default) and reports a miss as an error, so on a loaded machine a
  correct page reads as invalid and a wrong one as rejected. The deadline
  protects a server from untrusted schemas. These are AtMcp's own, and the
  question is what they accept, which does not depend on how fast the machine is.
  """

  def valid?(data, schema) do
    schema
    |> ExMCP.Content.SchemaPolicy.json_compatible()
    |> ExJsonSchema.Schema.resolve()
    |> ExJsonSchema.Validator.valid?(data)
  end
end
