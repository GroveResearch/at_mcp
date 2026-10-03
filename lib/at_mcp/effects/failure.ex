defmodule AtMcp.Effects.Failure do
  @moduledoc """
  What an application backend says went wrong, in AtMcp's own vocabulary.

  AtMcp makes four distinctions about a failed call. Three of them only the
  backend can make, because only the backend knows what its client library and
  service mean:

  - `:refused` — the action did not happen. The service rejected the request,
    or the client rejected it before sending. Reporting an error is safe.
  - `:auth_refused` — the service refused the credential. AtMcp may recover the
    session and try the call once more.
  - `:indeterminate` — anything else, including a lost response or a transport
    failure. A write may or may not have been applied, so AtMcp reports an
    unknown outcome and does not retry it.

  The fourth is AtMcp's own:

  - `:unreadable` — the call completed and the service answered, but AtMcp could
    not read the answer. Nothing was applied and nothing was learned, and
    retrying cannot change that: the limit is AtMcp's parser, not the service.
    An agent told this should report it, not try again.

  Everything above this boundary — write policy, session recovery, the MCP
  results an agent reads — is written against these kinds. A backend that
  returns something else is treated as `:indeterminate`, because a failure
  AtMcp cannot classify may or may not have been applied. `:unreadable` is never
  a classification of a service's error: the backend returns it only when its
  own parsing cannot read an answer, as `AtMcp.Effects.ProtoRune` does.

  `status` and `message` carry what the service said, for an agent to act on.
  `detail` is retained for logs and is never published in a tool result.
  """

  @enforce_keys [:kind]
  defstruct [:kind, :status, :message, :detail]

  @type kind :: :refused | :auth_refused | :indeterminate | :unreadable
  @type t :: %__MODULE__{
          kind: kind(),
          status: pos_integer() | nil,
          message: String.t() | nil,
          detail: term()
        }

  @doc "Build a failure of one kind."
  def new(kind, opts \\ [])
      when kind in [:refused, :auth_refused, :indeterminate, :unreadable] do
    %__MODULE__{
      kind: kind,
      status: Keyword.get(opts, :status),
      message: Keyword.get(opts, :message),
      detail: Keyword.get(opts, :detail)
    }
  end

  @doc "The kind of a backend reason, treating anything undeclared as indeterminate."
  def kind(%__MODULE__{kind: kind}), do: kind
  def kind(_reason), do: :indeterminate
end
