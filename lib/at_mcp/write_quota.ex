defmodule AtMcp.WriteQuota do
  @moduledoc """
  The write quota: a durable, account-wide limit on attempted writes per window.

  The first write opens a fixed window. Every client and grant for that DID
  shares it. Reservations reach disk before an external effect; failures and
  ambiguous outcomes are not refunded. One application owns the state directory.

  ## Time

  `status/2` reports `resets_at_unix` in unix seconds, the unit the ledger keeps.
  The MCP boundary renders it as `resets_at`, an ISO8601 string, because that is
  what an agent reads. The two names are different on purpose: one key carrying
  two types across a boundary is a defect waiting for a caller to trust it.

  The ledger is monotonic: it reads `max(clock, last_seen)`, so a clock moved
  backwards cannot grant a fresh window. A clock moved *forwards* extends the
  current window, and the quota stays exhausted until real time catches up.
  That direction is the safe one — a stuck window refuses writes, where a reset
  one would let an account write past its limit — and `identity_status` reports
  it.

  ## The default: 16 per hour

  What it protects against: an agent publishing under the account's name
  faster than a person would notice and stop it, such as a loop that replies
  to its own replies, a retry storm, or a conversation between two agents that
  never ends. Posts, replies and reposts are what other people see, so only
  they count (`AtMcp.Effects.publishing/0`; on the first night agents used the
  quota, likes and follows used it up within minutes). A refused write is the
  visible failure: the refusal and `identity_status` name the limit and the
  reset time.

  Why this number and window: 16 is the per-turn write budget an earlier
  version had. It was kept when the bound moved from the turn to the account
  and the hour (decisions.md, 2026-09-13), and it has not been measured
  against how accounts publish. An hour bounds a loop to 16 posts before it
  stops, and an account that reaches the limit can write again within the
  hour. It is a cautious starting point, not a measured one. An account in a
  busy conversation reaches it at one reply every four minutes, and an
  operator who expects that raises `AT_MCP_WRITE_LIMIT` or
  `AT_MCP_WRITE_WINDOW_SECONDS` (`config/runtime.exs`).
  """
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def reserve(server \\ __MODULE__, did)

  def reserve(server, did) when is_binary(did) and did != "" do
    GenServer.call(server, {:reserve, did})
  catch
    :exit, _ -> {:error, :write_quota_unavailable}
  end

  def reserve(_server, _did), do: {:error, :account_identity_unavailable}

  def status(server \\ __MODULE__, did) do
    GenServer.call(server, {:status, did})
  catch
    :exit, _ -> {:error, :write_quota_unavailable}
  end

  @impl true
  def init(opts) do
    # Why 16 per hour: the moduledoc, "The default".
    limit = Keyword.get(opts, :limit, 16)
    seconds = Keyword.get(opts, :window_seconds, 3600)

    if not (is_integer(limit) and limit > 0 and is_integer(seconds) and seconds > 0),
      do: raise(ArgumentError, "write quota limit and window_seconds must be positive integers")

    dir = Keyword.get_lazy(opts, :state_dir, &AtMcp.Inbound.Store.default_dir/0)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    path = Path.join(dir, "write-quota.json")

    data =
      case File.read(path) do
        {:error, :enoent} -> %{"version" => 1, "last_seen" => 0, "accounts" => %{}}
        {:ok, bytes} -> decode!(bytes)
        {:error, reason} -> raise File.Error, reason: reason, action: "read", path: path
      end

    {:ok,
     %{
       path: path,
       data: data,
       limit: limit,
       seconds: seconds,
       clock: Keyword.get(opts, :clock, fn -> System.system_time(:second) end)
     }}
  end

  @impl true
  def handle_call({:reserve, did}, _from, state) do
    now = max(state.clock.(), state.data["last_seen"])
    accounts = Map.reject(state.data["accounts"], fn {_, entry} -> entry["ends_at"] <= now end)
    entry = Map.get(accounts, did, %{"used" => 0, "ends_at" => now + state.seconds})

    if entry["used"] >= state.limit do
      {:reply, {:error, {:write_quota_exhausted, entry["ends_at"]}}, state}
    else
      entry = Map.update!(entry, "used", &(&1 + 1))
      data = %{state.data | "last_seen" => now, "accounts" => Map.put(accounts, did, entry)}
      persist!(state.path, data)
      {:reply, :ok, %{state | data: data}}
    end
  end

  def handle_call({:status, did}, _from, state) do
    now = max(state.clock.(), state.data["last_seen"])
    entry = state.data["accounts"][did]
    active = entry && entry["ends_at"] > now

    {:reply,
     %{
       limit: state.limit,
       window_seconds: state.seconds,
       used: if(active, do: entry["used"], else: 0),
       resets_at_unix: if(active, do: entry["ends_at"], else: nil)
     }, state}
  end

  defp decode!(bytes) do
    %{"version" => 1, "last_seen" => seen, "accounts" => accounts} = data = Jason.decode!(bytes)
    true = is_integer(seen) and seen >= 0 and is_map(accounts)

    true =
      Enum.all?(accounts, fn {did, entry} ->
        is_binary(did) and did != "" and is_map(entry) and
          is_integer(entry["used"]) and entry["used"] >= 0 and
          is_integer(entry["ends_at"]) and entry["ends_at"] > 0
      end)

    data
  end

  defp persist!(path, data) do
    tmp = path <> ".tmp"
    {:ok, file} = :file.open(String.to_charlist(tmp), [:write, :binary, :raw])

    try do
      :ok = File.chmod(tmp, 0o600)
      :ok = :file.write(file, Jason.encode!(data))
      :ok = :file.sync(file)
    after
      :file.close(file)
    end

    File.rename!(tmp, path)
  end
end
