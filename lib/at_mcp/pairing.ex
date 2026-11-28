defmodule AtMcp.Pairing do
  @moduledoc """
  Pairs an agent this installation runs with a principal on the web, so the
  principal's own client creates the agent's account (`setup`) or gives a
  stopped agent a new key (`repair`).

  The agent's login key is made here and never leaves this machine. What
  goes to the web is a pairing link carrying the key's public half and a
  `loginKeyProof` the key signed: bound to the principal (`iss`), the name
  (`sub`: the handle for `createAgent`, the agent's DID for `enrollKey`),
  the PDS (`aud`) and the method (`lxm`), at most 5 minutes old and good
  once. So a link that leaks creates nothing for anyone but that principal,
  and only for a few minutes. While it waits, a new link is printed every
  4 minutes.

  How at_mcp learns the new account: it signs in with the key alone at the
  PDS (no `login_hint`). The PDS finds the account from the key's
  thumbprint, and the token's `sub` is its DID. Until the principal has
  acted, the key is unknown and each try is refused (`key_refused`).

  Everything outside (the helper, HTTP, time, output) comes in through
  `deps`, so the flow is tested without a network.
  """

  alias AtMcp.Effects.Failure

  @create "town.delve.agent.createAgent"
  @enroll "town.delve.agent.enrollKey"
  # The PDS takes a proof at most 5 minutes old; a new link comes a minute
  # before that, so the one on screen always has time left.
  @link_ms 4 * 60_000
  # The PDS allows 30 signed-authorize attempts per 5 minutes and 300 a day
  # from one address, for unknown keys as for known ones (the
  # `agent-authorization` rate-limit policy). Every 20 s is 15 per 5 minutes,
  # leaving room for the address's other sign-ins, and at most 90 over the
  # default 30-minute wait.
  @poll_ms 20_000
  @limited_ms 60_000
  @limit_window_ms 5 * 60_000
  @default_wait_ms 30 * 60_000
  # Errors that waiting will not fix.
  @fatal ~w(preview_mismatch signed_authorize_unsupported tos_changed file_corrupt file_insecure)

  @type deps :: %{
          required(:helper) => (String.t(), map() -> {:ok, map()} | {:error, term()}),
          required(:get_json) => (String.t() -> {:ok, map()} | {:error, term()}),
          optional(:say) => (String.t() -> any()),
          optional(:sleep) => (non_neg_integer() -> any()),
          optional(:now_ms) => (-> integer())
        }

  @doc """
  Makes a key, prints links to `<web>/agents/new` until the principal has
  created the account, and answers the account it signed in to.

  `opts`: `:principal` (handle or DID), `:name` (a bare name, completed with
  the PDS's first handle domain) or `:handle` (a full handle), `:service`
  (the PDS URL), `:key_file` (where the new key goes; it must not exist),
  `:scope`, `:web_origin`, and `:wait_ms`.
  """
  def setup(opts, deps) do
    deps = defaults(deps)

    with {:ok, server} <- describe(opts.service, deps),
         {:ok, handle} <- agent_handle(opts, server),
         {:ok, principal} <- resolve(opts.principal, opts.service, deps),
         {:ok, key} <- deps.helper.("key.generate", %{keyFile: opts.key_file}) do
      proof = %{iss: principal, sub: handle, aud: server["did"], lxm: @create}

      link = fn proof_jwt ->
        opts.web_origin <>
          "/agents/new#" <>
          URI.encode_query(
            v: 1,
            key: key["didKey"],
            proof: proof_jwt,
            handle: handle,
            principal: principal
          )
      end

      deps.say.("Open this link signed in as #{opts.principal}, and create the agent @#{handle}:")

      with {:ok, did} <- await(opts, proof, link, opts.service, deps) do
        {:ok,
         %{
           did: did,
           handle: handle,
           principal: principal,
           login_key: key["didKey"],
           confirmed: confirmed?(did, principal, deps)
         }}
      end
    end
  end

  @doc """
  Makes a new key for a stopped agent, prints links to
  `<web>/agents/<did>/start` until its principal has enrolled it, and
  answers once the agent signs in with it. The old key is not touched; the
  caller replaces it after this succeeds.

  `opts`: `:did`, `:service`, `:key_file` (the new key's path; it must not
  exist), `:principal` (optional: by default the one ident.link confirms),
  `:scope`, `:web_origin`, `:wait_ms`.
  """
  def repair(opts, deps) do
    deps = defaults(deps)

    with {:ok, server} <- describe(opts.service, deps),
         {:ok, principal} <- repair_principal(opts, deps),
         {:ok, key} <- deps.helper.("key.generate", %{keyFile: opts.key_file}) do
      proof = %{iss: principal, sub: opts.did, aud: server["did"], lxm: @enroll}

      link = fn proof_jwt ->
        opts.web_origin <>
          "/agents/" <>
          opts.did <>
          "/start#" <> URI.encode_query(v: 1, key: key["didKey"], proof: proof_jwt)
      end

      deps.say.(
        "Open this link signed in as the agent's principal (#{principal}) to start it again:"
      )

      with {:ok, did} <- await(opts, proof, link, opts.did, deps) do
        {:ok, %{did: did, principal: principal, login_key: key["didKey"]}}
      end
    end
  end

  # Prints a link, then tries a key sign-in every 20 s; a fresh link every
  # 4 minutes; gives up after `wait_ms`.
  defp await(opts, proof, link, account, deps) do
    start = deps.now_ms.()
    deadline = start + Map.get(opts, :wait_ms, @default_wait_ms)
    loop(opts, proof, link, account, deps, deadline, nil, @poll_ms)
  end

  # `wait` is the pause after a refused try: 20 s, or after a 429 from the
  # PDS, 60 s doubling up to its 5-minute window, back to 20 s once a try
  # is answered.
  defp loop(opts, proof, link, account, deps, deadline, minted_at, wait) do
    now = deps.now_ms.()

    cond do
      now >= deadline ->
        {:error, :pairing_timeout}

      minted_at == nil or now - minted_at >= @link_ms ->
        case deps.helper.("key.prove", Map.put(proof, :keyFile, opts.key_file)) do
          {:ok, %{"proof" => jwt}} ->
            deps.say.(link.(jwt))
            if minted_at, do: deps.say.("(The link above replaces the earlier one.)")
            loop(opts, proof, link, account, deps, deadline, now, wait)

          {:error, _} = error ->
            error
        end

      true ->
        case deps.helper.("oauth.login", %{
               account: account,
               keyFile: opts.key_file,
               scope: opts.scope
             }) do
          {:ok, %{"did" => did}} ->
            _ = deps.helper.("oauth.logout", %{did: did})
            {:ok, did}

          {:error, %Failure{detail: code}} = error when code in @fatal ->
            error

          {:error, %Failure{detail: "rate_limited"}} ->
            backoff =
              if wait < @limited_ms, do: @limited_ms, else: min(wait * 2, @limit_window_ms)

            deps.say.(
              "Delvetown is limiting sign-ins from this address; trying again in #{div(backoff, 1000)} s."
            )

            deps.sleep.(backoff)
            loop(opts, proof, link, account, deps, deadline, minted_at, backoff)

          {:error, _} ->
            deps.sleep.(@poll_ms)
            loop(opts, proof, link, account, deps, deadline, minted_at, @poll_ms)
        end
    end
  end

  defp describe(service, deps) do
    base = service |> String.trim_trailing("/")

    case deps.get_json.(base <> "/xrpc/com.atproto.server.describeServer") do
      {:ok, %{"did" => "did:" <> _} = server} -> {:ok, server}
      _ -> {:error, :unreadable_server}
    end
  end

  defp agent_handle(%{handle: handle}, _server) when is_binary(handle),
    do: {:ok, String.downcase(handle)}

  defp agent_handle(%{name: name}, server) when is_binary(name) do
    case server["availableUserDomains"] do
      [domain | _] when is_binary(domain) ->
        {:ok, String.downcase(name <> "." <> String.trim_leading(domain, "."))}

      _ ->
        {:error, :no_handle_domain}
    end
  end

  defp agent_handle(_, _), do: {:error, :usage}

  defp resolve("did:" <> _ = did, _service, _deps), do: {:ok, did}

  # The PDS first, then the network's AppView: a PDS may not resolve a
  # handle hosted elsewhere that the AppView knows.
  defp resolve(handle, service, deps) do
    handle = String.trim_leading(handle, "@")

    [String.trim_trailing(service, "/"), appview_base()]
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value({:error, :principal_not_found}, fn base ->
      url =
        base <> "/xrpc/com.atproto.identity.resolveHandle?" <> URI.encode_query(handle: handle)

      case deps.get_json.(url) do
        {:ok, %{"did" => "did:" <> _ = did}} -> {:ok, did}
        _ -> nil
      end
    end)
  end

  defp appview_base do
    case AtMcp.Network.appview_url() do
      url when is_binary(url) -> url |> String.trim_trailing("/") |> String.trim_trailing("/xrpc")
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp repair_principal(%{principal: p} = opts, deps) when is_binary(p),
    do: resolve(p, opts.service, deps)

  defp repair_principal(opts, deps) do
    case principals(opts.did, deps) do
      [principal | _] -> {:ok, principal}
      [] -> {:error, :no_confirmed_principal}
    end
  end

  @doc """
  The principals ident.link confirms for `did`: each `agent-of` its DID
  document names whose endorsement of it exists.
  """
  def principals(did, deps) do
    deps = defaults(deps)

    with {:ok, doc} <- did_doc(did, deps) do
      for "https://ident.link/agent-of/" <> p <- doc["alsoKnownAs"] || [],
          endorsed?(p, did, deps),
          do: p
    else
      _ -> []
    end
  end

  # The PDS writes the endorsement for a principal it hosts; another
  # principal's client writes it just after createAgent. So a few looks.
  defp confirmed?(did, principal, deps, tries \\ 3) do
    cond do
      principal in principals(did, deps) ->
        true

      tries > 1 ->
        deps.sleep.(2_000)
        confirmed?(did, principal, deps, tries - 1)

      true ->
        false
    end
  end

  defp endorsed?(principal, agent, deps) do
    with {:ok, doc} <- did_doc(principal, deps),
         pds when is_binary(pds) <- pds_endpoint(doc),
         {:ok, %{"value" => %{"agent" => ^agent}}} <-
           deps.get_json.(
             String.trim_trailing(pds, "/") <>
               "/xrpc/com.atproto.repo.getRecord?" <>
               URI.encode_query(
                 repo: principal,
                 collection: "link.ident.endorsement",
                 rkey: agent
               )
           ) do
      true
    else
      _ -> false
    end
  end

  defp did_doc("did:plc:" <> _ = did, deps) do
    plc = Application.get_env(:at_mcp, :plc_url) || "https://plc.directory"
    deps.get_json.(String.trim_trailing(plc, "/") <> "/" <> did)
  end

  defp did_doc("did:web:" <> host, deps) do
    host = URI.decode(host)
    scheme = if String.starts_with?(host, "localhost"), do: "http", else: "https"
    deps.get_json.("#{scheme}://#{host}/.well-known/did.json")
  end

  defp did_doc(_, _), do: {:error, :unsupported_did}

  defp pds_endpoint(doc) do
    Enum.find_value(doc["service"] || [], fn
      %{"id" => id, "serviceEndpoint" => url} when id in ["#atproto_pds", "atproto_pds"] -> url
      _ -> nil
    end)
  end

  defp defaults(deps) do
    deps
    |> Map.put_new(:say, &IO.puts(:stderr, &1))
    |> Map.put_new(:sleep, &Process.sleep/1)
    |> Map.put_new(:now_ms, fn -> System.monotonic_time(:millisecond) end)
  end

  @doc "A plain JSON GET, for `deps.get_json`."
  def get_json(url) do
    case Req.get(url, retry: false, decode_body: false, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} -> Jason.decode(body)
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
