defmodule AtMcpTest do
  use ExUnit.Case, async: true

  test "mcp_port default" do
    assert is_integer(AtMcp.mcp_port())
  end
end
