defmodule AtMcp.Stream.Event do
  @moduledoc """
  One repository event, in AtMcp's own terms.

  A stream adapter converts what its service sends into this struct, so
  `AtMcp.Inbound` and `AtMcp.Inbound.Match` never see a client library's types or
  a service's field names. Changing service — a Jetstream version, or a
  different firehose entirely — changes the adapter and nothing above it.

  `cursor` is the position to resume from, whatever the service counts in.
  """

  defstruct [:kind, :did, :collection, :rkey, :operation, :cid, :rev, :cursor, :record]

  @type t :: %__MODULE__{
          kind: :commit | :identity | :account | :sync | atom() | nil,
          did: String.t() | nil,
          collection: String.t() | nil,
          rkey: String.t() | nil,
          operation: atom() | String.t() | nil,
          cid: String.t() | nil,
          rev: String.t() | nil,
          cursor: integer() | nil,
          record: map() | nil
        }

  @doc """
  Build an event from a service payload.

  Accepts a map with either key spelling, so a test can inject a
  service-shaped event without building an adapter's internal struct.
  """
  def from(%__MODULE__{} = event), do: event

  def from(source) when is_map(source) do
    %__MODULE__{
      kind: kind(source),
      did: read(source, ["did"]),
      collection: read(source, ["collection"]),
      rkey: read(source, ["rkey"]),
      operation: read(source, ["operation"]),
      cid: read(source, ["cid"]),
      rev: read(source, ["rev"]),
      cursor: read(source, ["time_us"]) || read(source, ["cursor"]) || read(source, ["seq"]),
      record: read(source, ["record"])
    }
  end

  def from(_other), do: %__MODULE__{}

  # Jetstream v1 calls it `kind` on the wire and ProtoRune calls it `type`.
  defp kind(source) do
    case read(source, ["kind"]) || read(source, ["type"]) do
      value when is_binary(value) -> String.to_existing_atom(value)
      value -> value
    end
  rescue
    ArgumentError -> nil
  end

  defp read(source, path), do: AtMcp.Response.dig(source, path)
end
