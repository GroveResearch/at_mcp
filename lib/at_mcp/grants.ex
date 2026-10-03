defmodule AtMcp.Grants do
  @moduledoc """
  Credentials AtMcp issues and validates itself: which identity a client acts as,
  and how much of the tool surface it may reach.

  A grant names one account and one scope. A client presents it as
  `Authorization: Bearer <token>` and `AtMcp.MCP.HTTP` resolves it to that
  account, so an agent acts as the identity its credential names rather than as
  whichever account owns the address it connected to. Two agents in one party,
  trusted differently, are separated by holding different grants.

  There is no authorization server, no TLS requirement and no introspection
  endpoint: AtMcp runs on loopback on one person's machine. `Bearer` is the
  standard shape, so a grant that later becomes an issuer-signed token with a
  resource indicator changes no client.

  A grant is not a sandbox. It is a bearer token on loopback with no binding to
  the process holding it: it separates what each client was given, not what each
  process could obtain.

  ## Where grants live

  In `accounts.grants.json`, a private file beside the accounts file. It stores
  a SHA-256 digest of each token and never the token, and deleting it revokes
  every grant while leaving the installation's identities intact.

  The path follows the accounts file it belongs to (`Path.rootname/1` of the
  accounts path plus `.grants.json`), because a grant names an account: an
  installation pointed at a different accounts file must not resolve grants
  issued against another one. Nothing in the environment moves it, so the
  service and the command that issues its grants cannot disagree about where
  they are.

  ## Scope

  Three scopes, ordered, each derived from what AtMcp's own tools declare about
  themselves rather than from a list of verb names kept in step by hand:

    * `:read` — every tool whose `readOnlyHint` is true.
    * `:write` — those, plus tools that write without destroying anything
      (`post`, `like`, `follow`).
    * `:manage` — those, plus every tool whose `destructiveHint` is true
      (`delete_post`, `block`, `unfollow`).

  A tool AtMcp does not declare is permitted by no scope, so a renamed tool fails
  closed instead of inheriting the last classification it had.

  Revocation is removing the grant, and takes effect on the next request: this
  module reads the file on each call rather than caching it, the way the
  accounts file already reloads without a restart.
  """

  @version 1
  @scopes [:read, :write, :manage]
  @rank %{read: 0, write: 1, manage: 2}
  @id_pattern ~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z/

  @type scope :: :read | :write | :manage
  @type grant :: %{id: binary(), account: binary(), scope: scope(), issued_at: binary()}

  @doc "Path to the grants file for the accounts file in use."
  def path, do: path_for(AtMcp.AccountConfig.path())

  @doc """
  The grants file belonging to one accounts file.

  `at_mcp-accounts --file X` works on a configuration that is not the running
  installation's, and its grants belong with it. Deriving rather than reading the
  environment is what keeps `--file` from issuing a credential into somebody
  else's installation.
  """
  def path_for(accounts_path) when is_binary(accounts_path),
    do: Path.rootname(Path.expand(accounts_path)) <> ".grants.json"

  @doc """
  Issue a grant for one account.

  Returns the token once. Only its digest is stored, so a lost token is reissued
  rather than recovered — the same property that makes the file safe to read.

  The account need not be configured yet: whether it exists and is running is
  answered when a request arrives, not here, so an operator can issue a grant
  and add the account in either order.
  """
  @spec issue(binary(), keyword()) :: {:ok, %{required(atom()) => term()}} | {:error, term()}
  def issue(account, opts \\ []) when is_binary(account) do
    scope = Keyword.get(opts, :scope, :manage)
    file = Keyword.get(opts, :path) || path()

    with :ok <- valid_account(account),
         :ok <- valid_scope(scope) do
      # Published bearer format stays stable; existing digests remain valid.
      token = "kite-" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      row = %{
        "id" => Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false),
        "account" => account,
        "scope" => Atom.to_string(scope),
        "digest" => digest(token),
        "issued_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }

      case write(file, fn grants -> {:ok, grants ++ [row], row} end) do
        {:ok, saved} -> {:ok, saved |> public() |> Map.put(:token, token)}
        error -> error
      end
    end
  end

  @doc """
  The account a token names, or `{:error, :unknown_grant}`.

  An unreadable grants file is `{:error, :grants_unreadable}` and never an empty
  one: answering "no such grant" because the file could not be read would tell a
  client the opposite of what is true, and send an operator to reissue a
  credential that already works.
  """
  @spec resolve(binary(), keyword()) ::
          {:ok, binary()} | {:error, :unknown_grant | :grants_unreadable}
  def resolve(token, opts \\ []) do
    case find(token, Keyword.get(opts, :path) || path()) do
      {:ok, row} -> {:ok, row["account"]}
      error -> error
    end
  end

  @doc """
  The account and scope a token names, in one lookup.

  What a request needs, and `resolve/2` followed by `scope/2` is not it: that
  reads the file twice, so a grant revoked between the two reads answers with an
  account and no scope, and a file that becomes unreadable between them reports
  a tool out of scope rather than a store AtMcp could not read. One read cannot
  disagree with itself.
  """
  @spec authorize(binary(), keyword()) ::
          {:ok, binary(), scope()} | {:error, :unknown_grant | :grants_unreadable}
  def authorize(token, opts \\ []) do
    case find(token, Keyword.get(opts, :path) || path()) do
      {:ok, row} -> {:ok, row["account"], String.to_existing_atom(row["scope"])}
      error -> error
    end
  end

  @doc "The scope a token carries, or `nil` when it names nothing."
  @spec scope(binary(), keyword()) :: scope() | nil
  def scope(token, opts \\ []) do
    case find(token, Keyword.get(opts, :path) || path()) do
      {:ok, row} -> String.to_existing_atom(row["scope"])
      _ -> nil
    end
  end

  @doc """
  Whether a token's scope reaches one tool.

  The classification comes from the tool's own `readOnlyHint` and
  `destructiveHint`, so adding a tool classifies it without editing this module.
  """
  @spec permits?(binary(), binary(), keyword()) :: boolean()
  def permits?(token, tool, opts \\ [])

  def permits?(token, tool, opts) when is_binary(tool) do
    case scope(token, opts) do
      nil -> false
      scope -> permits_scope?(scope, tool)
    end
  end

  def permits?(_, _, _), do: false

  @doc "Whether a scope reaches one tool, without a token."
  @spec permits_scope?(scope(), binary()) :: boolean()
  def permits_scope?(scope, tool) when scope in @scopes and is_binary(tool) do
    case Map.fetch(tool_scopes(), tool) do
      {:ok, required} -> @rank[scope] >= @rank[required]
      :error -> false
    end
  end

  def permits_scope?(_, _), do: false

  @doc "Remove a grant. Already absent is `:ok`: the outcome asked for is the outcome."
  @spec revoke(binary()) :: :ok | {:error, term()}
  def revoke(token, opts \\ [])

  def revoke(token, opts) when is_binary(token) do
    wanted = digest(token)
    file = Keyword.get(opts, :path) || path()

    case write(file, fn grants -> {:ok, Enum.reject(grants, &(&1["digest"] == wanted)), :ok} end) do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  def revoke(_, _), do: {:error, :unknown_grant}

  @doc "Remove a grant by the id `issue/2` returned, for an operator who no longer holds the token."
  @spec revoke_id(binary(), keyword()) :: :ok | {:error, term()}
  def revoke_id(id, opts \\ []) when is_binary(id) do
    result =
      write(Keyword.get(opts, :path) || path(), fn grants ->
        case Enum.any?(grants, &(&1["id"] == id)) do
          true -> {:ok, Enum.reject(grants, &(&1["id"] == id)), :ok}
          false -> {:error, :unknown_grant}
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  @doc "Every grant, without its digest. Nothing here reconstructs a token."
  @spec list(keyword()) :: {:ok, [grant()]} | {:error, term()}
  def list(opts \\ []) do
    case load(Keyword.get(opts, :path) || path()) do
      {:ok, grants} -> {:ok, Enum.map(grants, &public/1)}
      error -> error
    end
  end

  @doc "Remove every grant naming one account, for an account being removed."
  @spec revoke_account(binary(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def revoke_account(account, opts \\ []) when is_binary(account) do
    write(Keyword.get(opts, :path) || path(), fn grants ->
      {keep, drop} = Enum.split_with(grants, &(&1["account"] != account))
      {:ok, keep, length(drop)}
    end)
  end

  # --- internals ---

  defp find(token, file) when is_binary(token) and token != "" do
    wanted = digest(token)

    case load(file) do
      {:ok, grants} ->
        case Enum.find(grants, &Plug.Crypto.secure_compare(&1["digest"], wanted)) do
          nil -> {:error, :unknown_grant}
          row -> {:ok, row}
        end

      {:error, :config_missing} ->
        {:error, :unknown_grant}

      {:error, _} ->
        {:error, :grants_unreadable}
    end
  end

  defp find(_, _), do: {:error, :unknown_grant}

  defp load(file) do
    with {:ok, contents} <- AtMcp.PrivateFile.read(file) do
      decode(contents)
    end
  end

  defp decode(contents) do
    with {:ok, %{"version" => @version, "grants" => grants}} when is_list(grants) <-
           Jason.decode(contents),
         true <- Enum.all?(grants, &row?/1) do
      {:ok, grants}
    else
      _ -> {:error, :config_corrupt}
    end
  end

  defp row?(%{"id" => id, "account" => account, "scope" => scope, "digest" => digest})
       when is_binary(id) and is_binary(account) and is_binary(digest) do
    scope in Enum.map(@scopes, &Atom.to_string(&1)) and byte_size(digest) == 64
  end

  defp row?(_), do: false

  defp write(file, change) do
    AtMcp.PrivateFile.mutate(file, fn
      :missing -> apply_change(change, [])
      contents -> with {:ok, grants} <- decode(contents), do: apply_change(change, grants)
    end)
  end

  defp apply_change(change, grants) do
    with {:ok, next, result} <- change.(grants) do
      {:ok, Jason.encode!(%{"version" => @version, "grants" => next}), result}
    end
  end

  defp public(row) do
    %{
      id: row["id"],
      account: row["account"],
      scope: String.to_existing_atom(row["scope"]),
      issued_at: row["issued_at"]
    }
  end

  defp digest(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp valid_account(account) do
    if Regex.match?(@id_pattern, account), do: :ok, else: {:error, :invalid_account}
  end

  defp valid_scope(scope) do
    if scope in @scopes, do: :ok, else: {:error, :invalid_scope}
  end

  @doc """
  The scope each declared tool requires, read off the tool surface itself.

  Computed once per node from the tools declared by `AtMcp.MCP.Server`. It is read
  at runtime rather than at compile time so that this module does not have to be
  compiled after the tool surface it describes.
  """
  @spec tool_scopes() :: %{binary() => scope()}
  def tool_scopes do
    case :persistent_term.get({__MODULE__, :tool_scopes}, nil) do
      nil ->
        scopes = classify_tools()
        :persistent_term.put({__MODULE__, :tool_scopes}, scopes)
        scopes

      scopes ->
        scopes
    end
  end

  defp classify_tools do
    {:ok, tools, _cursor, _state} = AtMcp.MCP.Server.handle_list_tools(nil, :state)

    Map.new(tools, fn tool ->
      annotations = Map.get(tool, :annotations) || %{}

      required =
        cond do
          Map.get(annotations, :destructiveHint) == true -> :manage
          Map.get(annotations, :readOnlyHint) == true -> :read
          true -> :write
        end

      {tool.name, required}
    end)
  end
end
