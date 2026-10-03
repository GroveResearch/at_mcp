defmodule AtMcp.ResponseTest do
  use ExUnit.Case, async: true

  test "either spelling of a key reads the same value" do
    for source <- [%{uri: "at://x"}, %{"uri" => "at://x"}] do
      assert AtMcp.Response.dig(source, ["uri"]) == "at://x"
      assert AtMcp.Response.dig(source, [:uri]) == "at://x"
    end

    assert AtMcp.Response.dig(%{"author" => %{did: "did:plc:x"}}, ["author", "did"]) ==
             "did:plc:x"
  end

  test "false is a value, not a missing field" do
    assert AtMcp.Response.fetch(%{"is_read" => false}, "is_read") == {:ok, false}
    assert AtMcp.Response.fetch(%{is_read: false}, "is_read") == {:ok, false}
    assert AtMcp.Response.dig(%{"viewer" => %{"muted" => false}}, ["viewer", "muted"]) == false
  end

  test "an absent key is distinguishable from a null one" do
    assert AtMcp.Response.fetch(%{"like" => nil}, "like") == {:ok, nil}
    assert AtMcp.Response.fetch(%{}, "like") == :error
  end

  test "an unknown key name cannot create an atom" do
    unseen = "at_mcp-response-#{System.unique_integer([:positive])}"
    assert AtMcp.Response.fetch(%{}, unseen) == :error
    assert_raise ArgumentError, fn -> String.to_existing_atom(unseen) end
  end

  test "walking through a non-map stops rather than raising" do
    assert AtMcp.Response.dig(%{"record" => "not a map"}, ["record", "text"]) == nil
    assert AtMcp.Response.dig(nil, ["anything"]) == nil
    assert AtMcp.Response.dig("scalar", ["anything"]) == nil
  end
end
