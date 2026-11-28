defmodule AtMcp.AccountSetup do
  @moduledoc "Named account setup for a release, without starting a second account runtime."

  alias AtMcp.AccountConfig

  @switches [
    file: :string,
    handle: :string,
    service: :string,
    scope: :string,
    format: :string,
    tools: :string,
    expires_in: :integer,
    password_stdin: :boolean,
    did: :string,
    key_file: :string,
    did_key: :string,
    principal: :string,
    cancel: :boolean,
    name: :string,
    wait_minutes: :integer,
    transport: :string,
    url: :string,
    token_file: :string,
    disable: :boolean,
    limit: :integer,
    window_seconds: :integer,
    default: :boolean
  ]

  def main(args) do
    # Backend diagnostics can contain credentials or response bodies. This
    # command reports bounded errors and never starts AtMcp's service tree.
    Logger.configure(level: :none)
    {:ok, _} = Application.ensure_all_started(:proto_rune)

    case execute(args) do
      {:ok, result} ->
        IO.puts(Jason.encode!(result, pretty: true))

      {:error, reason} ->
        IO.puts(:stderr, "AtMcp account setup: #{message(reason)}")
        System.halt(1)
    end
  end

  @doc false
  def execute(args, dependencies \\ []) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, command, []} -> dispatch(command, opts, dependencies)
      _ -> {:error, :usage}
    end
  rescue
    _ -> {:error, :setup_failed}
  catch
    :exit, _ -> {:error, :setup_failed}
  end

  defp dispatch(["list"], opts, _) do
    with {:ok, accounts} <- AccountConfig.load(path(opts)) do
      {:ok, %{accounts: Enum.map(accounts, &listed/1)}}
    end
  end

  # A grant's token exists only at the moment it is issued, so generating a
  # connection issues a new credential every time it is run. `revoke` removes
  # the ones nobody holds.
  defp dispatch(["connection", id], opts, dependencies) do
    with {:ok, scope} <- scope(opts),
         {:ok, format} <- format(opts),
         {:ok, tools} <- tool_set(opts),
         {:ok, accounts} <- AccountConfig.load(path(opts)),
         {:ok, account} <- find(accounts, id),
         {:ok, descriptor} <-
           descriptor(
             account,
             opts[:transport] || "http",
             [
               scope: scope,
               format: format,
               tools: tools,
               path: grants_path(opts),
               expires_in_days: lifetime(opts)
             ] ++
               dependencies
           ) do
      {:ok,
       %{
         account: public(account),
         mcp: descriptor,
         grant:
           Map.reject(
             %{scope: scope, format: format, tools: tools, expires_in_days: lifetime(opts)},
             fn {_, v} -> is_nil(v) end
           ),
         service_configuration: %{AT_MCP_ACCOUNTS_FILE: path(opts)}
       }}
    end
  end

  defp dispatch(["grants"], opts, _) do
    with {:ok, grants} <- AtMcp.Grants.list(path: grants_path(opts)) do
      {:ok, %{grants: grants, file: grants_path(opts)}}
    end
  end

  defp dispatch(["revoke", grant_id], opts, _) do
    with :ok <- AtMcp.Grants.revoke_id(grant_id, path: grants_path(opts)) do
      {:ok,
       %{
         grant: grant_id,
         revoked: true,
         next: "Takes effect on the next request; the service is not restarted."
       }}
    end
  end

  defp dispatch(["delivery", id], opts, _) do
    delivery =
      case {opts[:disable], opts[:url], opts[:token_file]} do
        {true, nil, nil} ->
          {:ok, nil}

        {disabled, url, token_file}
        when disabled in [nil, false] and is_binary(url) and is_binary(token_file) ->
          {:ok, %{"url" => url, "token_file" => token_file}}

        _ ->
          {:error, :usage}
      end

    with {:ok, destination} <- delivery,
         {:ok, account} <- AccountConfig.set_delivery(path(opts), id, destination) do
      {:ok, %{account: public(account), next: reload_message()}}
    end
  end

  # Saving replaces the account's whole write limit: a field not given is the
  # service's again, so the file says everything the command was told.
  defp dispatch(["write-quota", id], opts, _) do
    quota =
      case {opts[:default], opts[:limit], opts[:window_seconds]} do
        {true, nil, nil} ->
          {:ok, nil}

        {default, limit, seconds}
        when default in [nil, false] and (is_integer(limit) or is_integer(seconds)) ->
          {:ok,
           %{"limit" => limit, "window_seconds" => seconds}
           |> Map.reject(fn {_, value} -> is_nil(value) end)}

        _ ->
          {:error, :usage}
      end

    with {:ok, quota} <- quota,
         {:ok, account} <- AccountConfig.set_write_quota(path(opts), id, quota) do
      {:ok,
       %{
         account: public(account),
         write_quota: Map.get(account, "write_quota"),
         next:
           reload_message() <>
             " Where write_quota is null or leaves a field out, the service's AT_MCP_WRITE_LIMIT and AT_MCP_WRITE_WINDOW_SECONDS apply."
       }}
    end
  end

  defp dispatch(["add", id], opts, dependencies) do
    with handle when is_binary(handle) and handle != "" <- opts[:handle],
         {:ok, accounts} <- AccountConfig.load(path(opts)),
         false <- Enum.any?(accounts, &(&1["id"] == id)),
         {:ok, password} <- password(opts, dependencies) do
      service = opts[:service] || AtMcp.Network.default_service()

      case save_verified(path(opts), id, handle, password, service, dependencies) do
        {:ok, saved} ->
          {:ok,
           %{
             account: public(saved),
             file: path(opts),
             next:
               "Start or restart the shared service with AT_MCP_ACCOUNTS_FILE set to this file, then use the connection command."
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      true -> {:error, :duplicate_id}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :usage}
    end
  end

  # An account with a login key and no app password: an agent this
  # installation created (`create_agent` keeps its key in the key folder,
  # under its DID), or one whose key file the operator gives.
  defp dispatch(["add-agent", id], opts, dependencies) do
    with "did:" <> _ = did <- opts[:did] || :usage,
         key_file = Path.expand(opts[:key_file] || AtMcp.Spaces.key_path(did)),
         {:ok, accounts} <- AccountConfig.load(path(opts)),
         false <- Enum.any?(accounts, &(&1["id"] == id)),
         :ok <-
           unless(Enum.any?(accounts, &(&1["did"] == did)),
             do: :ok,
             else: {:error, :duplicate_did}
           ),
         :ok <- key_file_present(key_file),
         {:ok, verified} <- key_login(did, key_file, dependencies),
         account = %{
           "id" => id,
           "handle" => opts[:handle] || verified.handle || did,
           "did" => did,
           "service" => opts[:service] || verified.service,
           "key_file" => key_file
         },
         :ok <- AccountConfig.validate(account),
         {:ok, saved} <- AccountConfig.add(path(opts), account) do
      {:ok,
       %{account: public(saved), file: path(opts), key_file: key_file, next: reload_message()}}
    else
      true -> {:error, :duplicate_id}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :usage}
    end
  end

  # An agent paired with its principal on the web: a new login key here, a
  # link for the principal to create the account with, and the account saved
  # once the key signs in to it (`AtMcp.Pairing`). The handle is NAME under
  # the PDS's first handle domain, or --handle.
  # `setup --name NAME` is the same as `setup NAME`.
  defp dispatch(["setup"], opts, dependencies) do
    case opts[:name] do
      name when is_binary(name) -> dispatch(["setup", name], opts, dependencies)
      _ -> {:error, :usage}
    end
  end

  defp dispatch(["setup", id], opts, dependencies) do
    with :ok <- if(opts[:cancel], do: :cancel, else: :ok),
         principal when is_binary(principal) <- opts[:principal] || :usage,
         :ok <- wait_valid(opts),
         {:ok, accounts} <- AccountConfig.load(path(opts)),
         false <- Enum.any?(accounts, &(&1["id"] == id)),
         :ok <- name_valid(id, opts[:handle]),
         service = opts[:service] || AtMcp.Network.default_service(),
         wanted = %{
           "kind" => "setup",
           "principal" => principal,
           "handle" => opts[:handle],
           "service" => service
         },
         {:ok, pending, resume} <- pending_pairing(id, wanted),
         {:ok, paired} <-
           pairing(dependencies, fn deps ->
             AtMcp.Pairing.setup(
               %{
                 principal: principal,
                 name: id,
                 handle: opts[:handle],
                 service: service,
                 key_file: pending["key_file"],
                 resume: resume,
                 scope: AtMcp.Spaces.scope_for(nil, service),
                 web_origin: AtMcp.Network.web_origin(),
                 wait_ms: wait_ms(opts)
               },
               deps
             )
           end)
           |> unsettled(id),
         key_file = AtMcp.Spaces.key_path(paired.did),
         :ok <- move_key(pending["key_file"], key_file),
         :ok <- AtMcp.Pairing.Pending.finish(id),
         account = %{
           "id" => id,
           "handle" => paired.handle,
           "did" => paired.did,
           "service" => service,
           "key_file" => key_file
         },
         :ok <- AccountConfig.validate(account),
         {:ok, saved} <- AccountConfig.add(path(opts), account) do
      {:ok,
       %{
         account: public(saved),
         principal: paired.principal,
         principal_confirmed: paired.confirmed,
         fingerprint: paired.fingerprint,
         file: path(opts),
         key_file: key_file,
         next:
           reload_message() <>
             " Then connect your MCP client: at_mcp-accounts connection #{id}." <>
             if(paired.confirmed,
               do: "",
               else:
                 " ident.link does not confirm the principal yet: its endorsement of the agent is missing. The principal can write it (endorse_agent), or the agents page will offer to."
             )
       }}
    else
      :cancel -> cancel_pairing(id)
      true -> {:error, :duplicate_id}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :usage}
    end
  end

  # A stopped agent's way back: a new login key here, a link for its
  # principal to enroll it with, and the account's key file replaced once
  # the new key signs in. On a machine with no entry for NAME, --did names
  # the agent: its PDS and handle come from its DID document, and the
  # account is saved once the new key signs in.
  defp dispatch(["repair", id], opts, dependencies) do
    with :ok <- if(opts[:cancel], do: :cancel, else: :ok),
         :ok <- wait_valid(opts),
         {:ok, accounts} <- AccountConfig.load(path(opts)),
         {:ok, current, new?} <- repair_target(accounts, id, opts, dependencies),
         service = current["service"],
         wanted = %{"kind" => "repair", "did" => current["did"], "service" => service},
         {:ok, pending, resume} <- pending_pairing(id, wanted),
         {:ok, paired} <-
           pairing(dependencies, fn deps ->
             AtMcp.Pairing.repair(
               %{
                 did: current["did"],
                 principal: opts[:principal],
                 service: service,
                 key_file: pending["key_file"],
                 resume: resume,
                 scope: AtMcp.Spaces.scope_for(current["did"], service),
                 web_origin: AtMcp.Network.web_origin(),
                 wait_ms: wait_ms(opts)
               },
               deps
             )
           end)
           |> unsettled(id),
         key_file = current["key_file"] || AtMcp.Spaces.key_path(current["did"]),
         :ok <- move_key(pending["key_file"], key_file),
         :ok <- AtMcp.Pairing.Pending.finish(id),
         {:ok, saved} <- save_repaired(path(opts), Map.put(current, "key_file", key_file), new?) do
      {:ok,
       %{
         account: public(saved),
         key_file: key_file,
         fingerprint: paired.fingerprint,
         next: reload_message() <> " The agent signs in with its new key from then on."
       }}
    else
      :cancel -> cancel_pairing(id)
      {:error, reason} -> {:error, reason}
      _ -> {:error, :usage}
    end
  end

  # Gives an existing account a login key, beside its app password.
  defp dispatch(["key", id], opts, dependencies) do
    with key when is_binary(key) <- opts[:key_file] || :usage,
         key_file = Path.expand(key),
         {:ok, accounts} <- AccountConfig.load(path(opts)),
         {:ok, current} <- find(accounts, id),
         :ok <- key_file_present(key_file),
         {:ok, _verified} <- key_login(current["did"], key_file, dependencies),
         {:ok, saved} <-
           AccountConfig.update(path(opts), id, Map.put(current, "key_file", key_file)) do
      {:ok,
       %{account: public(saved), file: path(opts), key_file: key_file, next: reload_message()}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :usage}
    end
  end

  defp dispatch(["update", id], opts, dependencies) do
    with {:ok, accounts} <- AccountConfig.load(path(opts)),
         {:ok, current} <- find(accounts, id),
         {:ok, password} <- password(opts, dependencies) do
      candidate = %{
        current
        | "handle" => opts[:handle] || current["handle"],
          "service" => opts[:service] || current["service"],
          "password" => password
      }

      with :ok <- AccountConfig.validate(candidate),
           {:ok, session} <-
             login(candidate["handle"], password, candidate["service"], dependencies),
           :ok <- same_identity(session, current["did"]),
           {:ok, saved} <-
             AccountConfig.update(path(opts), id, %{
               candidate
               | "handle" => Map.get(session, :handle) || candidate["handle"]
             }) do
        {:ok, %{account: public(saved), file: path(opts), next: reload_message()}}
      end
    end
  end

  defp dispatch(["remove", id], opts, _) do
    with {:ok, removed} <- AccountConfig.remove(path(opts), id) do
      # A grant names an account. Leaving one behind for an account that no
      # longer exists leaves a credential that would start working again the
      # moment the name is reused.
      revoked =
        case AtMcp.Grants.revoke_account(id, path: grants_path(opts)) do
          {:ok, count} -> count
          _ -> 0
        end

      {:ok,
       %{
         account: public(removed),
         file: path(opts),
         removed: true,
         grants_revoked: revoked,
         next:
           reload_message() <>
             " This removes saved credentials; it does not revoke the app password at the PDS."
       }}
    end
  end

  # Makes an account a principal: its public PLC rotation key. The private
  # half is never given here.
  defp dispatch(["rotation-key", id], opts, _dependencies) do
    with key when is_binary(key) <- opts[:did_key] || :usage,
         {:ok, accounts} <- AccountConfig.load(path(opts)),
         {:ok, current} <- find(accounts, id),
         candidate = Map.put(current, "rotation_key", key),
         :ok <- AccountConfig.validate(candidate) |> rotation_key_valid(),
         {:ok, saved} <- AccountConfig.update(path(opts), id, candidate) do
      {:ok,
       %{
         account: public(saved),
         rotation_key: key,
         next:
           reload_message() <>
             " Keep the private half of this key offline: it is what takes an agent's identity back. at_mcp never holds it."
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :usage}
    end
  end

  defp dispatch(_, _, _), do: {:error, :usage}

  defp rotation_key_valid(:ok), do: :ok
  defp rotation_key_valid(_), do: {:error, :invalid_rotation_key}

  @doc """
  Write an accounts file for an installation that has only account variables set.

  AtMcp reads its accounts from the accounts file. When there is no file,
  this writes one from `AT_MCP_HANDLE` / `AT_MCP_APP_PASSWORD` (or the
  deprecated `BLUESKY_HANDLE` / `BLUESKY_APP_PASSWORD`) and the `_2` pair, as
  the accounts `default` and `second`. With a file already present, even an
  empty one, it reads none of them, so it cannot silently change which
  accounts exist. `AT_MCP_PORT` sets the installation's one endpoint, so it
  gives no account a port of its own.

  Each account's DID comes from logging in with its own credentials, as
  `add` does; a login that fails leaves no file to half-migrate from.
  """
  def bootstrap_from_env(path, dependencies \\ []) when is_binary(path) do
    if File.lstat(path) == {:error, :enoent} do
      Enum.reduce_while(env_accounts(), :ok, fn account, :ok ->
        case save_verified(
               path,
               account.id,
               account.handle,
               account.password,
               account.service,
               dependencies
             ) do
          {:ok, _saved} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      :ok
    end
  end

  @doc false
  def bootstrap_from_env!(path, dependencies \\ []) do
    case bootstrap_from_env(path, dependencies) do
      :ok ->
        :ok

      {:error, reason} ->
        raise ArgumentError,
              "AtMcp account configuration: AT_MCP_HANDLE / AT_MCP_APP_PASSWORD could not be migrated into " <>
                path <> ": #{message(reason)}"
    end
  end

  defp env_accounts do
    for {id, account} <- Application.get_env(:at_mcp, :env_accounts, []),
        is_binary(account[:handle]) and is_binary(account[:password]) do
      %{
        id: to_string(id),
        handle: String.trim(account[:handle]),
        password: String.trim(account[:password]),
        service: account[:service] || AtMcp.Network.default_service()
      }
    end
  end

  # An account's DID is what a host is never made to type, so it is never
  # guessed here either: it comes from the login this same credential performs.
  defp save_verified(path, id, handle, password, service, dependencies) do
    candidate = %{
      "id" => id,
      "handle" => handle,
      "did" => "did:plc:pending",
      "password" => password,
      "service" => service
    }

    with :ok <- AccountConfig.validate(candidate),
         {:ok, session} <- login(handle, password, service, dependencies),
         did when is_binary(did) and did != "" <- Map.get(session, :did),
         {:ok, saved} <-
           AccountConfig.add(path, %{
             candidate
             | "did" => did,
               "handle" => Map.get(session, :handle) || handle
           }) do
      {:ok, saved}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_account_identity}
    end
  end

  defp same_identity(%{did: did}, did), do: :ok
  defp same_identity(_, _), do: {:error, :account_identity_changed}

  defp reload_message do
    "Saved configuration changed. The running service is unchanged; reload or restart it to apply this file."
  end

  # Account verification logs in through the same backend the account runtime
  # uses, so setup and running an account cannot diverge in what a login means.
  defp login(handle, password, service, dependencies) do
    backend = Keyword.get(dependencies, :backend, AtMcp.Effects.ProtoRune)

    login =
      Keyword.get(dependencies, :login, fn h, p, opts ->
        backend.login([handle: h, password: p] ++ opts)
      end)

    case login.(handle, password, service: service) do
      {:ok, session} when is_map(session) -> {:ok, session}
      _ -> {:error, :authentication_failed}
    end
  end

  defp key_file_present(path),
    do: if(File.regular?(path), do: :ok, else: {:error, :key_file_missing})

  # A key is saved only once it has logged its account in. The check runs on
  # a helper of its own, with a state folder of its own, so it never touches
  # the running service's sessions, and it signs its session out after.
  defp key_login(did, key_file, dependencies) do
    check = Keyword.get(dependencies, :key_login, &check_key/2)

    case check.(did, key_file) do
      {:ok, %{did: ^did} = verified} ->
        {:ok, verified}

      {:ok, _other} ->
        {:error, :account_identity_changed}

      {:error, %AtMcp.Effects.Failure{detail: "key_refused"}} ->
        {:error, :key_refused}

      {:error, %AtMcp.Effects.Failure{detail: :spaces_unavailable}} ->
        {:error, :spaces_unavailable}

      _ ->
        {:error, :key_login_failed}
    end
  end

  defp check_key(did, key_file) do
    # Random, not unique_integer/1: two fresh nodes would pick the same one.
    dir =
      Path.join(
        System.tmp_dir!(),
        "at_mcp-key-check-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    {:ok, helper} = AtMcp.Spaces.Helper.start_link(name: nil, state_dir: dir)
    call = &AtMcp.Spaces.Helper.call(&1, &2, server: helper)

    try do
      with {:ok, %{"did" => ^did}} <-
             call.("oauth.login", %{
               account: did,
               keyFile: key_file,
               scope: AtMcp.Spaces.scope_for(did)
             }),
           {:ok, creds} <- call.("oauth.credentials", %{did: did}) do
        _ = call.("oauth.logout", %{did: did})
        {:ok, %{did: did, service: creds["serviceUrl"], handle: handle_of(did)}}
      else
        {:ok, %{"did" => other}} -> {:ok, %{did: other}}
        error -> error
      end
    after
      GenServer.stop(helper)
      File.rm_rf(dir)
    end
  end

  # Pairing runs on a helper of its own, with a state folder of its own, as
  # the key check does, so it never touches the running service's sessions.
  defp pairing(dependencies, fun) do
    case Keyword.fetch(dependencies, :pairing) do
      {:ok, deps} ->
        fun.(deps)

      :error ->
        dir =
          Path.join(
            System.tmp_dir!(),
            "at_mcp-pairing-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
          )

        {:ok, helper} = AtMcp.Spaces.Helper.start_link(name: nil, state_dir: dir)

        try do
          fun.(%{
            helper: &AtMcp.Spaces.Helper.call(&1, &2, server: helper),
            get_json: &AtMcp.Pairing.get_json/1
          })
        after
          GenServer.stop(helper)
          File.rm_rf(dir)
        end
    end
  end

  # The pending pairing for NAME: resumed (same key) when it was for the
  # same thing, started otherwise. One for something else is refused, so a
  # typo can't silently drop a key whose agent may exist.
  defp pending_pairing(id, wanted) do
    case AtMcp.Pairing.Pending.load(id) do
      {:ok, pending} ->
        if Map.take(pending, Map.keys(wanted)) == wanted,
          do: {:ok, pending, true},
          else: {:error, :pairing_pending}

      :none ->
        with {:ok, pending} <- AtMcp.Pairing.Pending.start(id, wanted),
             do: {:ok, pending, false}

      error ->
        error
    end
  end

  # Waiting ran out, or something failed after the key was made: whether the
  # principal acted is unknown, so the key stays for a resume or a cancel.
  defp unsettled(result, id) do
    case result do
      {:ok, _} = ok ->
        ok

      {:error, :pairing_timeout} ->
        {:error, :pairing_unsettled}

      # Refused before any link was shown: nothing can exist for this key.
      {:error, {:before_link, failure}} ->
        _ = AtMcp.Pairing.Pending.cancel(id)
        {:error, failure}

      error ->
        error
    end
  end

  defp cancel_pairing(id) do
    with :ok <- AtMcp.Pairing.Pending.cancel(id) do
      {:ok,
       %{
         cancelled: id,
         next:
           "The pending pairing and its key are gone. If the principal already created the agent (or enrolled the key), the account stays: they can delete it on the web, or run repair to give it a new key."
       }}
    end
  end

  defp repair_target(accounts, id, opts, dependencies) do
    case find(accounts, id) do
      {:ok, %{"key_file" => k} = current} when is_binary(k) ->
        if opts[:did] in [nil, current["did"]],
          do: {:ok, current, false},
          else: {:error, :account_identity_changed}

      {:ok, _} ->
        {:error, :no_login_key}

      _ ->
        with "did:" <> _ = did <- opts[:did] || {:error, :not_found},
             :ok <- name_valid(id, "given"),
             :ok <-
               if(Enum.any?(accounts, &(&1["did"] == did)),
                 do: {:error, :duplicate_did},
                 else: :ok
               ),
             {:ok, %{service: service, handle: handle}} <-
               pairing(dependencies, &AtMcp.Pairing.service_of(did, &1)) do
          {:ok,
           %{
             "id" => id,
             "did" => did,
             "handle" => handle || did,
             "service" => opts[:service] || service
           }, true}
        end
    end
  end

  defp save_repaired(file, account, true) do
    with :ok <- AccountConfig.validate(account), do: AccountConfig.add(file, account)
  end

  defp save_repaired(_file, account, false), do: {:ok, account}

  defp move_key(from, to) do
    with :ok <- File.rename(from, to), :ok <- File.chmod(to, 0o600), do: :ok
  end

  defp wait_valid(opts) do
    case opts[:wait_minutes] do
      nil -> :ok
      n when is_integer(n) and n > 0 and n <= 24 * 60 -> :ok
      _ -> {:error, :invalid_wait}
    end
  end

  defp wait_ms(opts), do: (opts[:wait_minutes] || 30) * 60_000

  # NAME is the account's name here, and, without --handle, the first label
  # of the agent's handle, so it must be both.
  defp name_valid(id, handle) do
    cond do
      not Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z/, id) ->
        {:error, :invalid_account}

      is_nil(handle) and not Regex.match?(~r/\A[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\z/, id) ->
        {:error, :invalid_agent_name}

      true ->
        :ok
    end
  end

  # The handle the DID document names, if the directory answers.
  defp handle_of("did:plc:" <> _ = did) do
    plc = Application.get_env(:at_mcp, :plc_url) || "https://plc.directory"

    with {:ok, %{status: 200, body: body}} <-
           Req.get(String.trim_trailing(plc, "/") <> "/" <> did, retry: false, decode_body: false),
         {:ok, %{"alsoKnownAs" => aka}} <- Jason.decode(body),
         "at://" <> handle <- Enum.find(aka, &String.starts_with?(&1, "at://")) do
      handle
    else
      _ -> nil
    end
  end

  defp handle_of(_did), do: nil

  defp password(opts, dependencies) do
    read =
      Keyword.get(dependencies, :password, fn ->
        if opts[:password_stdin] do
          IO.read(:stdio, :line)
        else
          IO.write(:stderr, "App password (hidden): ")
          value = :io.get_password()
          IO.write(:stderr, "\n")
          value
        end
      end)

    case read.() do
      value when is_binary(value) or is_list(value) ->
        case value |> to_string() |> String.trim() do
          "" -> {:error, :password_required}
          password -> {:ok, password}
        end

      _ ->
        {:error, :password_required}
    end
  end

  # A connection's grant ends after 90 days unless the command or the
  # installation (`AT_MCP_GRANT_LIFETIME_DAYS`) says otherwise: a grant that
  # leaks, or outlives the client it was for, stops working by itself.
  @connection_days 90

  defp lifetime(opts),
    do:
      opts[:expires_in] || Application.get_env(:at_mcp, :grant_lifetime_days) ||
        @connection_days

  # `write` unless asked: `manage` reaches agent control, app sign-ins and
  # deletions, which a client gets only when its operator chooses it.
  defp scope(opts) do
    case opts[:scope] do
      nil -> {:ok, :write}
      "read" -> {:ok, :read}
      "write" -> {:ok, :write}
      "manage" -> {:ok, :manage}
      _ -> {:error, :invalid_scope}
    end
  end

  defp format(opts) do
    case opts[:format] do
      nil ->
        {:ok, nil}

      format ->
        if format in AtMcp.MCP.Output.formats(),
          do: {:ok, format},
          else: {:error, :invalid_format}
    end
  end

  defp tool_set(opts) do
    case opts[:tools] do
      nil ->
        {:ok, nil}

      tools ->
        if tools in AtMcp.MCP.ToolSet.sets(),
          do: {:ok, tools},
          else: {:error, :invalid_tools}
    end
  end

  defp find(accounts, id) do
    case Enum.find(accounts, &(&1["id"] == id)) do
      nil -> {:error, :not_found}
      account -> {:ok, account}
    end
  end

  defp public(account), do: AccountConfig.public(account)

  # The operator reading the list is the one who set the limit.
  defp listed(account),
    do: Map.merge(public(account), Map.take(account, ["write_quota"]))

  defp descriptor(account, transport, deps),
    do: AccountConfig.descriptor(account, transport, deps)

  defp path(opts), do: Path.expand(opts[:file] || AccountConfig.path())

  # Grants belong to the accounts file they name accounts in, so `--file` moves
  # both together.
  defp grants_path(opts), do: AtMcp.Grants.path_for(path(opts))

  defp message(:usage),
    do: """
    Usage: at_mcp-accounts [--file PATH] COMMAND

      add NAME --handle HANDLE [--service URL]
                                [--password-stdin]
      update NAME [--handle HANDLE] [--service URL]
                  [--password-stdin]
      add-agent NAME --did DID [--key-file ABSOLUTE_PATH] [--handle HANDLE]
                     [--service URL]
      key NAME --key-file ABSOLUTE_PATH
      setup NAME | --name NAME --principal HANDLE [--handle HANDLE] [--service URL]
                 [--wait-minutes N] [--cancel]
      repair NAME [--did DID] [--principal HANDLE] [--wait-minutes N] [--cancel]
      rotation-key NAME --did-key did:key:...
      remove NAME
      delivery NAME --url URL --token-file ABSOLUTE_PATH
      delivery NAME --disable
      write-quota NAME [--limit N] [--window-seconds SECONDS]
      write-quota NAME --default
      list
      connection NAME [--transport http|stdio]
                      [--scope read|write|manage] [--format text|json]
                      [--tools default|full] [--expires-in DAYS]
                      (write and 90 days unless given)
      grants
      revoke GRANT_ID

    Running service: status | reload | disconnect NAME | reconnect NAME
    """

  defp message(:pairing_unsettled),
    do:
      "No account signed in with this key yet. The key is kept, since the principal may still act or may have acted already: run the same command again to keep waiting (it first checks whether the account exists), or add --cancel to discard it."

  defp message(:pairing_pending),
    do:
      "A pairing for this name is pending with other details (principal, handle, service or DID). Finish it with the same command, or discard it with --cancel."

  defp message(:no_pending_pairing), do: "No pairing is pending for this name."

  defp message(:pairing_state_unreadable),
    do:
      "The pending pairing's record in the key folder can't be read. Check the folder's permissions."

  defp message(:unresolvable_did),
    do: "That DID's document names no PDS. Check the DID, or give --service."

  defp message(:principal_not_found),
    do: "That principal's handle does not resolve. Check it, or give its DID."

  defp message(:unreadable_server),
    do: "The PDS did not say its DID (describeServer). Check --service."

  defp message(:no_handle_domain),
    do: "The PDS lists no handle domain. Give the agent's full handle with --handle."

  defp message(:no_confirmed_principal),
    do: "ident.link confirms no principal for this agent. Give the principal with --principal."

  defp message(:no_login_key),
    do:
      "This account has no login key, so it has nothing to repair. Use key NAME --key-file to give it one."

  defp message(:invalid_agent_name),
    do:
      "Without --handle, NAME is the start of the agent's handle: letters, digits and inner hyphens, at most 63."

  defp message(:invalid_wait), do: "--wait-minutes is a whole number from 1 to 1440."

  defp message(%AtMcp.Effects.Failure{message: m}) when is_binary(m), do: m

  defp message(:authentication_failed),
    do: "Login failed. Check the handle, app password and PDS URL. No account was saved."

  defp message(:account_identity_changed),
    do: "The new login does not match the saved account DID. No account was changed."

  defp message(:password_required),
    do: "An app password is required; enter it privately or use --password-stdin."

  defp message(:duplicate_id),
    do: "That account name already exists. Use list to inspect saved accounts."

  defp message(:duplicate_did),
    do:
      "This network account is already saved under another name. Use list, then connection NAME to share it."

  defp message(:invalid_account),
    do:
      "Use a simple account name and a valid PDS URL; a write limit and window are positive integers."

  defp message(:invalid_scope), do: "Choose --scope read, write or manage."

  defp message(:invalid_rotation_key),
    do:
      "Give the public rotation key as a did:key (did:key:z...). Only the public half: its private half stays offline."

  defp message(:key_file_missing),
    do:
      "No login key at that path. For an agent this installation created, leave --key-file out: its key is in the key folder under its DID."

  defp message(:key_refused),
    do:
      "The account's PDS refused this login key: it was never enrolled, or its principal revoked or replaced it. No account was changed."

  defp message(:key_login_failed),
    do:
      "The login key did not log the account in (the PDS may not offer agent authorization by key). No account was changed."

  defp message(:spaces_unavailable),
    do:
      "Logging in with a key needs the Spaces helper and Node 22 or later (docs/settings.md). No account was changed."

  defp message(:invalid_tools),
    do:
      "Choose --tools default (#{length(AtMcp.MCP.ToolSet.default())} tools, used when --tools is left out) or --tools full (every tool)."

  defp message(:invalid_format),
    do: "Choose --format text (the default) or json."

  defp message(:unknown_grant),
    do: "No grant has that id. Use grants to list the ones this installation holds."

  defp message(:config_busy),
    do: "Another account setup command is saving this file. Retry after it finishes."

  defp message(:config_insecure), do: "The account file must have private permissions (0600)."

  defp message(:config_symlink),
    do: "Select the actual private account file, not a symbolic link."

  defp message(:config_corrupt),
    do: "The account file is invalid. Preserve it and restore a valid configuration."

  defp message(:config_unavailable),
    do: "Cannot access the account file. Check --file and its directory permissions."

  defp message(:not_found), do: "No account has that name. Use list to see saved accounts."

  defp message(:release_required),
    do: "Run connection through the built release's at_mcp-accounts command."

  defp message(:invalid_transport), do: "Choose --transport http or --transport stdio."

  defp message(reason) when is_atom(reason), do: Atom.to_string(reason)
end
