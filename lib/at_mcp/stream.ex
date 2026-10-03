defmodule AtMcp.Stream do
  @moduledoc """
  The repository event stream AtMcp collects from.

  An adapter owns two things its service defines and AtMcp should not: what the
  subscription options are called, and what its messages look like. AtMcp asks
  for collections and a resume position; the adapter maps those onto its
  service and turns each message it receives into a `AtMcp.Stream.Event`.

  `decode/1` is given every message the collector does not recognize, so an
  adapter can use whatever message shape its client sends without the collector
  knowing the shape exists. Returning `:ignore` leaves the message alone.
  """

  @doc """
  Start collecting.

  Options are AtMcp's: `:handler` (the process to send events to),
  `:collections` (the record types to receive), `:cursor` (a position to
  resume from, or nil for the live tip) and `:name`.
  """
  @callback start_link(opts :: keyword()) :: {:ok, pid()} | {:error, term()}

  @doc "Turn a message from this adapter's client into an event."
  @callback decode(message :: term()) :: {:ok, AtMcp.Stream.Event.t()} | :ignore
end
