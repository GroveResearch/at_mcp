defmodule AtMcp.AccountSetup do
  @moduledoc "Named account setup for a release, without starting a second account runtime."

  alias AtMcp.AccountConfig

  @switches [
    file: :string,
    handle: :string,
    service: :string,
    scope: :string,
    password_stdin: :boolean,
    transport: :string
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
      {:ok, %{accounts: Enum.map(accounts, &public/1)}}
    end
  end

  # A grant's token exists only at the moment it is issued, so generating a
  # connection issues a new credential every time it is run. `revoke` removes
  # the ones nobody holds.
  defp dispatch(["connection", id], opts, dependencies) do
    with {:ok, scope} <- scope(opts),
         {:ok, accounts} <- AccountConfig.load(path(opts)),
         {:ok, account} <- find(accounts, id),
         {:ok, descriptor} <-
           descriptor(
             account,
             opts[:transport] || "http",
             [scope: scope, path: grants_path(opts)] ++ dependencies
           ) do
      {:ok,
       %{
         account: public(account),
         mcp: descriptor,
         grant: %{scope: scope},
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

  defp dispatch(_, _, _), do: {:error, :usage}

  @doc """
  Write an accounts file for an installation that has only `BLUESKY_*` set.

  AtMcp is configured one way: by the accounts file. An installation that
  predates it was configured by `BLUESKY_HANDLE` / `BLUESKY_APP_PASSWORD` (and
  the `_2` pair), so those are read once, here, to write the file the single
  path then reads. With a file already present — even an empty one — the
  environment is not consulted, so this cannot silently change which accounts
  exist. The account ids are the ones that installation already had: `default`
  and `second`. `AT_MCP_PORT` is now the installation's one endpoint rather
  than an account's, so it is not migrated per account.

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
              "AtMcp account configuration: BLUESKY_* environment could not be migrated into " <>
                path <> ": #{message(reason)}"
    end
  end

  defp env_accounts do
    [{"", "default"}, {"_2", "second"}]
    |> Enum.map(fn {suffix, id} ->
      %{
        id: id,
        handle: env("BLUESKY_HANDLE" <> suffix),
        password: env("BLUESKY_APP_PASSWORD" <> suffix),
        service: env("BLUESKY_SERVICE" <> suffix) || AtMcp.Network.default_service()
      }
    end)
    |> Enum.filter(&(is_binary(&1.handle) and is_binary(&1.password)))
  end

  defp env(key) do
    case System.get_env(key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: nil, else: String.trim(value)

      _ ->
        nil
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

  defp scope(opts) do
    case opts[:scope] do
      nil -> {:ok, :manage}
      "read" -> {:ok, :read}
      "write" -> {:ok, :write}
      "manage" -> {:ok, :manage}
      _ -> {:error, :invalid_scope}
    end
  end

  defp find(accounts, id) do
    case Enum.find(accounts, &(&1["id"] == id)) do
      nil -> {:error, :not_found}
      account -> {:ok, account}
    end
  end

  defp public(account), do: AccountConfig.public(account)

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
      remove NAME
      list
      connection NAME [--transport http|stdio]
                      [--scope read|write|manage]
      grants
      revoke GRANT_ID

    Running service: status | reload | disconnect NAME | reconnect NAME
    """

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
    do: "Use a simple account name and a valid PDS URL."

  defp message(:invalid_scope), do: "Choose --scope read, write or manage."

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
