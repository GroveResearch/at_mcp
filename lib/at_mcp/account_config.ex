defmodule AtMcp.AccountConfig do
  @moduledoc """
  Private, versioned account configurations. Account verification belongs to the caller;
  this module validates and serializes configuration without contacting a PDS.

  An account carries no port: one MCP endpoint serves the whole installation and
  the grant a client presents decides which identity it acts as
  (`AtMcp.MCP.HTTP`). An `mcp_port` key found in a file, which an account had
  before one endpoint served them all, is dropped when the file is read, and
  the next write leaves it out; a caller that passes one is refused.
  """

  @fields ~w(id handle did password service)

  @doc "Configuration path, overridable with AT_MCP_ACCOUNTS_FILE."
  def path do
    (System.get_env("AT_MCP_ACCOUNTS_FILE") ||
       AtMcp.Rename.default_path(
         Path.join(to_string(:filename.basedir(:user_config, ~c"at_mcp")), "accounts.json"),
         Path.join(to_string(:filename.basedir(:user_config, ~c"kite")), "accounts.json"),
         "AT_MCP_ACCOUNTS_FILE"
       ))
    |> Path.expand()
  end

  @doc "Load validated account configurations. A missing file is an empty configuration."
  def load(path) when is_binary(path) do
    case AtMcp.PrivateFile.read(path) do
      {:ok, contents} -> decode(contents)
      {:error, :config_missing} -> {:ok, []}
      error -> error
    end
  end

  @doc """
  The fields of an account that may be shown to anyone who can already ask.

  Never the app password.
  """
  def public(account), do: Map.take(account, ["id", "handle", "did", "service"])

  @doc """
  How a host reaches one account, in the shape an MCP client already consumes.

  The descriptor carries the shared endpoint and a grant for this account. The
  grant is what makes the descriptor specific: the URL is the same for every
  identity, and the credential in the `Authorization` header is what the endpoint
  resolves to this one.

  Generating a descriptor therefore **issues a credential**. A grant's token is
  stored only as a digest and cannot be recovered, so a descriptor that carried
  an existing grant would have to carry a token nobody still has. Pass
  `grant: %{token: ...}` to use one you already hold, or `scope:` to narrow what
  the issued grant reaches; the default is `:manage`, because a descriptor
  regenerated to replace a per-port one must not silently do less than the
  endpoint it replaces. `path:` is the grants file to issue into, for a caller
  working on a configuration that is not the running installation's.

  `grant: :none` leaves the credential out. That is for a caller that must not
  mint one — `AtMcp.Control` serves discovery to any local process, and a
  discovery endpoint that handed out a `:manage` grant for any identity on
  request would undo the separation the grant exists to make. The result is
  everything a host would otherwise be told by hand, and nothing it could attach
  with.

  The published header is retained across the at_mcp rename for existing clients.
  `x-kite-account-did` is still present and still only confirms: a host is never
  made to type a DID, and a grant naming a different account than the header
  claims is refused rather than acted on.
  """
  def descriptor(account, transport, dependencies \\ [])

  def descriptor(account, "http", dependencies) do
    with {:ok, token} <- grant(account, dependencies) do
      credential =
        case token do
          :none -> []
          token -> [%{name: "authorization", value: "Bearer " <> token}]
        end

      {:ok,
       %{
         name: "at_mcp-#{account["id"]}",
         type: "http",
         url: endpoint(),
         headers: credential ++ [%{name: "x-kite-account-did", value: account["did"]}]
       }}
    end
  end

  def descriptor(account, "stdio", dependencies) do
    release = Keyword.get(dependencies, :release_root) || System.get_env("RELEASE_ROOT")

    if is_binary(release) do
      with {:ok, token} <- grant(account, dependencies) do
        {:ok,
         %{
           name: "at_mcp-#{account["id"]}",
           command: command_path(release, "at_mcp-connect"),
           args: ["--url", endpoint(), "--did", account["did"]],
           # The grant travels in the environment, not in argv: every process on
           # the machine can read another's command line, and a credential that
           # `ps` discloses separates nothing.
           env: if(token == :none, do: %{}, else: %{"AT_MCP_GRANT" => token})
         }}
      end
    else
      {:error, :release_required}
    end
  end

  def descriptor(_account, _transport, _dependencies), do: {:error, :invalid_transport}

  # A host keeps the command it is given, and an old release's directory is
  # deleted sooner or later. A release unpacked as the README lays it out
  # (AT_MCP/releases/NAME, beside AT_MCP/current) is named through `current`, so
  # the command keeps working across upgrades. RELEASE_ROOT is a
  # physical path (`bin/at_mcp` resolves it with `pwd -P`), so it never already
  # goes through `current`.
  defp command_path(release, command) do
    releases = Path.dirname(release)
    current = Path.join(Path.dirname(releases), "current")

    root =
      if Path.basename(releases) == "releases" and File.dir?(current), do: current, else: release

    Path.join(root, "bin/" <> command)
  end

  defp grant(account, dependencies) do
    case Keyword.get(dependencies, :grant) do
      :none ->
        {:ok, :none}

      %{token: token} when is_binary(token) ->
        {:ok, token}

      nil ->
        scope = Keyword.get(dependencies, :scope, :manage)
        opts = [scope: scope] ++ Keyword.take(dependencies, [:path])

        case AtMcp.Grants.issue(account["id"], opts) do
          {:ok, %{token: token}} -> {:ok, token}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  The one loopback MCP endpoint this installation serves.

  The running listener's port, not the configured one: a descriptor has to carry
  the address the service is actually listening on. They differ whenever the
  configured port was 0, and they differ silently after a configuration change
  the service has not been restarted for.
  """
  def endpoint, do: "http://127.0.0.1:#{port()}/mcp"

  @doc false
  def port do
    :ranch.get_port(:at_mcp_http)
  rescue
    _ -> Application.get_env(:at_mcp, :mcp_port, 4400)
  catch
    _, _ -> Application.get_env(:at_mcp, :mcp_port, 4400)
  end

  @doc "Add one account configuration without replacing an existing account."
  def add(path, account) when is_binary(path) do
    with :ok <- validate(account) do
      mutate(path, fn accounts -> {:ok, accounts ++ [account], account} end)
    end
  end

  @doc "Replace an account configuration while preserving its account name and verified DID."
  def update(path, id, account) when is_binary(path) and is_binary(id) do
    with :ok <- validate(account) do
      mutate(path, fn accounts ->
        case Enum.find(accounts, &(&1["id"] == id)) do
          nil ->
            {:error, :not_found}

          current ->
            if account["id"] == id and account["did"] == current["did"] do
              {:ok, Enum.map(accounts, fn row -> if row["id"] == id, do: account, else: row end),
               account}
            else
              {:error, :account_identity_changed}
            end
        end
      end)
    end
  end

  @doc "Remove saved credentials only; whether the account is running or disconnected, and its history, are separate."
  def remove(path, id) when is_binary(path) and is_binary(id) do
    mutate(path, fn accounts ->
      case Enum.find(accounts, &(&1["id"] == id)) do
        nil -> {:error, :not_found}
        account -> {:ok, Enum.reject(accounts, &(&1["id"] == id)), account}
      end
    end)
  end

  @permitted_errors [
    :duplicate_id,
    :duplicate_did,
    :config_insecure,
    :config_symlink,
    :config_corrupt,
    :config_unavailable,
    :config_busy,
    :not_found,
    :account_identity_changed
  ]

  defp mutate(path, change) do
    result =
      AtMcp.PrivateFile.mutate(path, fn contents ->
        with {:ok, accounts} <- current(contents),
             {:ok, next, result} <- change.(accounts),
             :ok <- unique(next) do
          {:ok, Jason.encode!(%{"version" => 1, "accounts" => next}), result}
        end
      end)

    case result do
      {:ok, value} -> {:ok, value}
      {:error, reason} when reason in @permitted_errors -> {:error, reason}
      _ -> {:error, :config_unavailable}
    end
  end

  defp current(:missing), do: {:ok, []}
  defp current(contents), do: decode(contents)

  defp decode(contents) do
    with {:ok, decoded} <- Jason.decode(contents),
         %{"version" => 1, "accounts" => accounts} when is_list(accounts) <-
           without_ports(decoded),
         true <- Enum.all?(accounts, &(validate(&1) == :ok)),
         :ok <- unique(accounts) do
      {:ok, accounts}
    else
      _ -> {:error, :config_corrupt}
    end
  end

  # One endpoint serves every account, so a per-account `mcp_port` left in a
  # file is dropped rather than refused as corrupt, which would lose an
  # operator their accounts.
  defp without_ports(%{"accounts" => accounts} = file) when is_list(accounts) do
    %{
      file
      | "accounts" =>
          Enum.map(accounts, &if(is_map(&1), do: Map.delete(&1, "mcp_port"), else: &1))
    }
  end

  defp without_ports(file), do: file

  @doc "Validate an account configuration without filesystem or network access."
  def validate(account) when is_map(account) do
    valid =
      Enum.sort(Map.keys(account)) == Enum.sort(@fields) and
        Enum.all?(
          @fields,
          &(is_binary(account[&1]) and String.valid?(account[&1]) and
              String.trim(account[&1]) != "")
        )

    if valid and Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z/, account["id"]) and
         Regex.match?(~r/\Adid:[a-z0-9]+:[^\s]+\z/, account["did"]) and
         valid_service?(account["service"]),
       do: :ok,
       else: {:error, :invalid_account}
  end

  def validate(_), do: {:error, :invalid_account}

  defp valid_service?(service) do
    uri = URI.parse(service)

    is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo) and
      is_nil(uri.query) and is_nil(uri.fragment) and
      is_integer(uri.port) and uri.port in 1..65535 and
      not Regex.match?(~r/\s/, service) and
      (uri.scheme == "https" or
         (uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1", "::1"]))
  rescue
    _ -> false
  end

  defp unique(accounts) do
    Enum.reduce_while([{"id", :duplicate_id}, {"did", :duplicate_did}], :ok, fn {field, error},
                                                                                :ok ->
      values = Enum.map(accounts, &Map.fetch!(&1, field))

      if length(Enum.uniq(values)) == length(values),
        do: {:cont, :ok},
        else: {:halt, {:error, error}}
    end)
  end
end
