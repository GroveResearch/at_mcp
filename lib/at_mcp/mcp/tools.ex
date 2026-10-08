defmodule AtMcp.MCP.Tools do
  @moduledoc false

  def respond({:ok, summary}, state), do: {:ok, encode(summary), state}

  def respond(
        {:error, %AtMcp.Effects.Failure{kind: :refused, detail: :membership_not_supported}},
        state
      ),
      do:
        error(
          state,
          "membership_not_supported",
          "Membership status is available through the Delvetown backend. This connection does not support it; no request was sent."
        )

  def respond(
        {:error,
         %AtMcp.Effects.Failure{kind: :refused, detail: {:wrong_record_kind, _, _}} = failure},
        state
      ),
      do: error(state, "wrong_record_kind", failure.message)

  def respond({:error, :not_connected}, state),
    do:
      error(
        state,
        "not_connected",
        "error: this account is not connected: it has no credentials. Configure it in at_mcp's accounts file."
      )

  def respond({:error, {:write_outcome_unknown, _reason}}, state) do
    error(
      state,
      "write_outcome_unknown",
      "error: write outcome unknown; the action may have completed. Inspect the account's current records before deciding whether to retry. AtMcp did not retry this uncertain write.",
      %{outcome: "unknown"}
    )
  end

  # AtMcp stopped the call at its deadline before anything was sent that could
  # change the account; a write that had been sent is `write_outcome_unknown`.
  def respond({:error, :call_deadline_exceeded}, state) do
    seconds = div(AtMcp.Effects.call_deadline() + 999, 1000)

    error(
      state,
      "call_deadline_exceeded",
      "error: AtMcp stopped waiting after #{seconds} seconds: the account's service, or an earlier request on this account, did not answer in time. Nothing was changed. Retrying later may succeed."
    )
  end

  @account_errors %{
    account_disconnected:
      "This account is disconnected. Reconnect it through at_mcp's account controls; opening another client does not reconnect it.",
    account_identity_changed:
      "The login identity does not match this connection's expected account. Stop using this connection and repair its account configuration.",
    account_runtime_unavailable:
      "The account runtime is unavailable. Inspect the account status with at_mcp-accounts. If a write was in progress, inspect the account records before retrying it.",
    account_authentication_failed:
      "The account's credential was refused and could not be renewed, so this account is logged out. Nothing was applied. Check the app password and reconnect; retrying the same request will not help.",
    invalid_image:
      "An image could not be read. Each entry needs base64 `data`, a `mime_type` and `alt` text; nothing was sent.",
    invalid_post_text:
      "Post/reply text must be valid UTF-8. Nothing was attempted and nothing was counted against the write quota.",
    empty_batch: "Supply at least one URI or actor. Nothing was attempted."
  }

  def respond({:error, :batch_too_large}, state),
    do:
      error(
        state,
        "batch_too_large",
        "error: Ask for at most #{AtMcp.Effects.max_batch()} URIs or actors in one call. Nothing was attempted; split the list and call again."
      )

  def respond({:error, reason}, state) when is_map_key(@account_errors, reason),
    do: error(state, Atom.to_string(reason), "error: " <> Map.fetch!(@account_errors, reason))

  # The numbers in this one are the configured network's, not Bluesky's. An
  # agent told "at most 300 graphemes" on a network that takes 100,000 has been
  # given a reason it cannot act on.
  def respond({:error, :post_text_too_long}, state) do
    %{graphemes: graphemes, bytes: bytes} = AtMcp.Network.post_limits()

    error(
      state,
      "post_text_too_long",
      "error: Post/reply text must be at most #{graphemes} Unicode graphemes and #{bytes} UTF-8 bytes. Nothing was attempted and nothing was counted against the write quota."
    )
  end

  # A cursor comes back from the caller, so it can come back as anything. This
  # is AtMcp refusing the argument, not the service refusing the read.
  def respond({:error, :invalid_before}, state),
    do:
      error(
        state,
        "invalid_before",
        "error: before must be the AT URI a previous call returned in chain_before. Nothing was read."
      )

  def respond({:error, :write_quota_unavailable}, state),
    do:
      error(
        state,
        "write_quota_unavailable",
        "error: account write quota unavailable; writes remain paused until AtMcp recovers"
      )

  # A reply or a quote names a record AtMcp has to read to build the write. That
  # read runs before the write quota is charged, so this refusal costs nothing —
  # and saying so is the difference between a caller that tries a different
  # post and one that believes it has spent a write it has not.
  def respond({:error, {:referenced_record_unreadable, uri}}, state) do
    error(
      state,
      "referenced_record_unreadable",
      "error: the record at #{uri} could not be read, so the reference could not be built. " <>
        "It may be deleted, not indexed yet, or not a post. Nothing was written and nothing was counted against the write quota.",
      %{uri: uri}
    )
  end

  # A follow, block or mute names its subject by handle, and the handle is
  # resolved before the write quota is charged. One the service could not
  # resolve is a refusal: the write was never sent.
  def respond({:error, {:handle_not_resolved, handle}}, state) do
    error(
      state,
      "handle_not_resolved",
      "error: Nothing was sent: the account's service could not resolve the handle #{handle}. " <>
        "Nothing was counted against the write quota.",
      %{handle: handle}
    )
  end

  def respond({:error, {:write_quota_exhausted, resets_at}}, state) do
    reset = iso8601(resets_at)

    error(
      state,
      "write_quota_exhausted",
      "error: account write quota exhausted; resets at #{reset}",
      %{resets_at: reset}
    )
  end

  # An application service refusing or failing a request is an ordinary outcome
  # an agent must be able to act on. Report what it said and whether retrying
  # could help, without publishing the internals of the client library.
  # AtMcp could not read what the service sent. Saying "the request did not
  # complete" would be false twice over — it completed, and the service answered
  # — and it would send an agent into a retry loop against a condition that is
  # deterministic in AtMcp's own parser.
  def respond({:error, %AtMcp.Effects.Failure{kind: :unreadable} = upstream}, state) do
    error(
      state,
      "response_unreadable",
      "error: #{upstream.message} Nothing was applied and nothing was read. " <>
        "Retrying will return the same result; report this rather than repeating it.",
      Map.reject(%{http_status: upstream.status}, fn {_, v} -> is_nil(v) end)
    )
  end

  def respond({:error, %AtMcp.Effects.Failure{kind: kind} = upstream}, state)
      when kind in [:refused, :auth_refused, :indeterminate] do
    status = upstream.status
    detail = upstream_detail(upstream)

    {code, guidance} =
      cond do
        status == 501 ->
          {"upstream_not_implemented",
           "The account's service reports that this operation is not implemented. " <>
             "Repeating the same request is not expected to help; check which operations the service supports."}

        status == 429 ->
          {"upstream_rate_limited",
           "The account's service is rate limiting this client. Wait before retrying."}

        is_integer(status) and status >= 500 ->
          {"upstream_unavailable",
           "The account's service is unavailable. The request was not applied; retrying later may succeed."}

        is_integer(status) and status in 400..499 ->
          {"upstream_rejected",
           "The account's service rejected this request. Check the request before retrying it unchanged."}

        true ->
          {"upstream_failed", "The request to the account's service did not complete."}
      end

    error(
      state,
      code,
      "error: #{detail} #{guidance}",
      Map.reject(%{http_status: status, upstream_message: upstream.message}, fn {_, v} ->
        is_nil(v)
      end)
    )
  end

  def respond({:error, reason}, state),
    do: {:ok, ExMCP.Server.DSL.Result.error("error: #{format_reason(reason)}"), state}

  def respond(other, state), do: {:ok, encode(other), state}

  defp upstream_detail(%{message: message, status: status})
       when is_binary(message) and message != "" and is_integer(status),
       do: "the account's service answered #{status}: #{message}."

  defp upstream_detail(%{message: message}) when is_binary(message) and message != "",
    do: "the account's service answered: #{message}."

  defp upstream_detail(%{status: status}) when is_integer(status),
    do: "the account's service answered #{status}."

  defp upstream_detail(_), do: "the account's service did not answer."

  @doc """
  A handle or DID as a tool argument names it. Models write handles the way
  people do, `@alice.example`, and neither a handle nor a DID starts with `@`,
  so one leading `@` is dropped; anything else is passed on as given.
  """
  def actor("@" <> actor), do: actor
  def actor(actor), do: actor

  @doc "Several handles or DIDs, each read as `actor/1` reads one."
  def actors(actors), do: actors |> List.wrap() |> Enum.map(&actor/1)

  def get_profile(effects, actor) do
    actor =
      case actor do
        nil -> AtMcp.Effects.session_did(effects) || AtMcp.Effects.session_handle(effects)
        "" -> AtMcp.Effects.session_did(effects) || AtMcp.Effects.session_handle(effects)
        other -> other
      end

    cond do
      not is_binary(actor) or actor == "" ->
        {:error, "no actor and this identity is not connected"}

      true ->
        AtMcp.Effects.get_profile(effects, actor)
    end
  end

  def update_profile(effects, args) when is_map(args) do
    updates =
      []
      |> maybe_kw(:display_name, Map.get(args, :display_name) || Map.get(args, "display_name"))
      |> maybe_kw(:description, Map.get(args, :description) || Map.get(args, "description"))

    if updates == [] do
      {:error, "provide display_name and/or description"}
    else
      AtMcp.Effects.update_profile(effects, updates)
    end
  end

  def identity_status(effects) do
    status = %{
      logged_in: AtMcp.Effects.logged_in?(effects),
      did: AtMcp.Effects.session_did(effects),
      login_count: AtMcp.Effects.login_count(effects),
      handle: AtMcp.Effects.session_handle(effects),
      # Which network this account acts on, and what its post record allows.
      # Read here rather than written into a tool description, because a
      # description is frozen when the module compiles and this is not.
      network: %{
        name: Atom.to_string(AtMcp.Network.name()),
        label: AtMcp.Network.label(),
        namespace: AtMcp.Network.namespace(),
        post_limits: AtMcp.Network.post_limits()
      }
    }

    case AtMcp.Effects.quota_status(effects) do
      {:error, _} = error ->
        error

      quota ->
        {:ok,
         status
         |> Map.put(:write_quota, quota_view(quota))}
    end
  end

  # The tool surface reports one time format. `AtMcp.WriteQuota` keeps unix
  # seconds for embedding hosts and its own ledger.
  # The ledger keeps unix seconds; an agent reads a time.
  defp quota_view(quota) do
    {unix, quota} = Map.pop!(quota, :resets_at_unix)
    Map.put(quota, :resets_at, iso8601(unix))
  end

  defp iso8601(nil), do: nil

  defp iso8601(seconds) when is_integer(seconds),
    do: seconds |> DateTime.from_unix!() |> DateTime.to_iso8601()

  defp error(state, code, message, details \\ %{}) do
    result = ExMCP.Server.DSL.Result.error(message)
    {:ok, Map.put(result, :structuredContent, Map.merge(%{code: code}, details)), state}
  end

  defp maybe_kw(kw, _key, nil), do: kw
  defp maybe_kw(kw, _key, ""), do: kw
  defp maybe_kw(kw, key, value), do: Keyword.put(kw, key, value)

  # Backends own page limits and summaries. Keep their complete values here:
  # slicing serialized JSON loses records, continuation cursors, and valid syntax.
  defp encode(value) when is_binary(value), do: value

  defp encode(value) when is_map(value) or is_list(value) do
    case Jason.encode(value) do
      {:ok, json} -> structured(json)
      _ -> inspect(value, pretty: false, limit: 30)
    end
  end

  defp encode(value), do: inspect(value, limit: 30)

  # A summary is returned twice: as the JSON text every MCP client can read,
  # and as structured content for clients that validate against the tool's
  # declared output schema. Both carry the same JSON values, so a client
  # reading either sees one result. Only objects can be structured content.
  defp structured(json) do
    case Jason.decode(json) do
      {:ok, data} when is_map(data) ->
        %{content: [%{type: "text", text: json}], structuredContent: data}

      _ ->
        json
    end
  end

  @doc """
  Read the optional halves of a post out of tool arguments.

  Image bytes arrive base64-encoded because JSON has no other way to carry
  them; this is where they stop being text. A string that is not base64 is
  refused here, before the write quota is charged and before anything is sent.
  """
  def post_options(args) when is_map(args) do
    with {:ok, images} <- decode_images(Map.get(args, :images)) do
      {:ok,
       Enum.reject(
         [langs: Map.get(args, :langs), quote: Map.get(args, :quote), images: images],
         fn {_key, value} -> absent?(value) end
       )}
    end
  end

  # An optional field a caller filled in with nothing is a field it did not fill
  # in. Models routinely send `""` and `[]` for options they are not using, and
  # an empty string is not an AT URI: treating only `nil` as absent lets
  # `quote: ""` reach the record builder, and the service refuses the whole post.
  defp absent?(nil), do: true
  defp absent?(""), do: true
  defp absent?([]), do: true
  defp absent?(value) when is_binary(value), do: String.trim(value) == ""
  defp absent?(_), do: false

  defp decode_images(nil), do: {:ok, nil}
  defp decode_images([]), do: {:ok, nil}

  defp decode_images(images) when is_list(images) do
    Enum.reduce_while(images, {:ok, []}, fn image, {:ok, acc} ->
      with {:ok, encoded} <- string_field(image, "data"),
           {:ok, mime_type} <- string_field(image, "mime_type"),
           {:ok, alt} <- string_field(image, "alt"),
           {:ok, data} <- Base.decode64(encoded) do
        {:cont, {:ok, acc ++ [%{data: data, mime_type: mime_type, alt: alt}]}}
      else
        _ -> {:halt, {:error, :invalid_image}}
      end
    end)
  end

  defp decode_images(_other), do: {:error, :invalid_image}

  defp string_field(map, key) when is_map(map) do
    case AtMcp.Response.fetch(map, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp string_field(_map, _key), do: :error

  def format_reason(reason) when is_binary(reason), do: reason
  def format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  def format_reason([%{__struct__: Peri.Error} | _] = errors),
    do: Enum.map_join(errors, "; ", &format_reason/1)

  def format_reason(%{__struct__: Peri.Error, path: path, message: message}) when is_list(path),
    do: "invalid #{Enum.map_join(path, ".", &to_string/1)}: #{message}"

  def format_reason(%{__struct__: Peri.Error, message: message}), do: message
  def format_reason(reason), do: inspect(reason, limit: 20)
end
