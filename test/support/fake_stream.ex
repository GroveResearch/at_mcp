defmodule AtMcp.Test.FakeStream do
  @moduledoc false
  @behaviour AtMcp.Stream

  use Agent

  @impl true
  def start_link(opts) do
    case :persistent_term.get(:at_mcp_falsify_js_parent, nil) do
      nil -> :ok
      parent -> send(parent, {:js_opts, opts})
    end

    case :persistent_term.get(:at_mcp_inbound_js_parent, nil) do
      nil -> :ok
      parent -> send(parent, {:inbound_js_started, opts})
    end

    Agent.start_link(fn -> opts end, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def decode({:jetstream, payload}), do: {:ok, AtMcp.Stream.Event.from(payload)}
  def decode(_message), do: :ignore
end
