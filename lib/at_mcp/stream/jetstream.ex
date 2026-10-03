defmodule AtMcp.Stream.Jetstream do
  @moduledoc """
  Jetstream v1 collection, through ProtoRune's client.

  AtMcp's collection filter is a slice of record types with **no DID filter**:
  an incoming mention or reaction is a commit in somebody else's repository, so
  a DID filter cannot be the inbox. That translation lives here, along with the
  client's option names and message shape.

  This client speaks v1 and resumes from a `time_us` cursor. Jetstream v2 adds
  an event-kind filter, sequence cursors and historical replay; reaching those
  means another module implementing `AtMcp.Stream`, not new options on this one.
  """

  @behaviour AtMcp.Stream

  alias AtMcp.Stream.Event

  @impl true
  def start_link(opts) do
    client_opts = [
      handler: Keyword.fetch!(opts, :handler),
      # Deliberately empty: see the moduledoc.
      wanted_dids: [],
      wanted_collections: Keyword.fetch!(opts, :collections),
      name: Keyword.get(opts, :name, __MODULE__)
    ]

    client_opts =
      case Keyword.get(opts, :cursor) do
        cursor when is_integer(cursor) and cursor > 0 -> Keyword.put(client_opts, :cursor, cursor)
        _ -> client_opts
      end

    client().start_link(client_opts)
  end

  # The client is swappable so the translation below can be checked without a
  # network, the way ProtoRune's own HTTP client is.
  defp client, do: Application.get_env(:at_mcp, :jetstream_client, ProtoRune.Jetstream)

  @impl true
  def decode({:jetstream, payload}), do: {:ok, Event.from(payload)}
  def decode(_message), do: :ignore
end
