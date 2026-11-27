defmodule AtMcp.Spaces.InboxTokens do
  @moduledoc """
  Keeps the town AppView reading each running key-holding account's invite
  inbox, so group invites reach its notifications, with as few calls as that
  takes.

  First it makes the account's inbox if it has none (`prepare/1`), on its
  first pass after AtMcp starts: a group can invite only an account whose
  inbox exists, and only the account's own client can make it. A failed
  attempt is tried again after 5 seconds, then twice as long each time up to
  the 100-second pass, until the inbox exists.

  Then, by how the AppView reads the inbox:

    * **The inbox lists the AppView as a reader** (`AT_MCP_TOWN_INBOX_READER`,
      the default): the AppView reads it as a member, so it needs no client
      tokens. AtMcp registers the inbox (`registerSpace` without a token)
      when it makes or finds it, again when the account's session is
      established anew (`renewed/1`), and otherwise every 30 minutes as a
      keep-alive. If the AppView answers anything but `registered`, the
      account falls back to client tokens, and the keep-alive tries the
      reader again later.
    * **The reader is off, or the account removed it:** AtMcp hands the
      AppView a delegation token for the inbox at most every 8 minutes, as
      the web app does. The AppView holds a space credential for 600 seconds
      and takes a client's token only while it is under 50 seconds old, so
      invites read this way can reach the notifications up to about 8
      minutes late: the cost of opting out of the reader.

  The account's groups follow the same rule: a group the AppView is a member
  of (the default on groups.delve.town) has its members space registered
  once, at start and on a new session, with no tokens; a group without the
  AppView gets a token for its members space and each feed at most every 8
  minutes, so an agent hears from it as a person in it does through the web
  app. Whether the AppView is a member comes from the group host's member
  list, looked at again every 30 minutes, which also finds groups joined
  since.

  Whatever the AppView answers, no space gets a token more often than every
  8 minutes, except one at once after the account's session is established
  anew. The pass runs every 100 seconds and checks each account; most passes
  send nothing.
  """

  use GenServer

  require Logger

  @every_ms 100_000
  @first_ms 5_000

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "How often the pass runs, in milliseconds: it checks each account, and most passes send nothing."
  def every_ms, do: @every_ms

  # A missing inbox that could not be made is tried again sooner than the
  # next pass: 5 s, then twice as long each time, up to the pass itself.
  @retry_first_ms 5_000
  # Where the AppView reads the inbox as a member: a keep-alive registration.
  @keepalive_ms 30 * 60_000
  # Where it doesn't: a delegation token at most this often, as the web app.
  @token_ms 8 * 60_000

  @doc "How often, at most, an inbox's delegation token is handed over."
  def token_ms, do: @token_ms

  @doc "How often an inbox the AppView reads as a member is registered again."
  def keepalive_ms, do: @keepalive_ms

  @doc """
  The account `did`'s session was established anew: register its inbox with
  the AppView again at the next pass. A no-op when this isn't running.
  """
  def renewed(did) when is_binary(did), do: GenServer.cast(__MODULE__, {:renewed, did})
  def renewed(_did), do: :ok

  @doc false
  # The state a pass starts from, for tests that drive passes themselves.
  def initial(opts \\ []) do
    {:ok, state} = init(Keyword.put(opts, :first_ms, :infinity))
    state
  end

  @impl true
  def init(opts) do
    every = Keyword.get(opts, :every_ms, @every_ms)
    first = Keyword.get(opts, :first_ms, @first_ms)
    if first != :infinity, do: Process.send_after(self(), :vouch, first)

    {:ok,
     %{
       every: every,
       keepalive: Keyword.get(opts, :keepalive_ms, @keepalive_ms),
       token_every: Keyword.get(opts, :token_ms, @token_ms),
       last: %{},
       # account id => %{mode: :reader | :tokens, at: when last registered}
       modes: %{},
       renewed: MapSet.new(),
       # account id => %{checked_at, groups: %{group DID => %{member?, spaces, token_at}}}
       groups: %{},
       retry_first: Keyword.get(opts, :retry_first_ms, @retry_first_ms),
       retries: %{}
     }}
  end

  @impl true
  def handle_cast({:renewed, did}, state),
    do: {:noreply, %{state | renewed: MapSet.put(state.renewed, did)}}

  @impl true
  def handle_info(:vouch, state) do
    Process.send_after(self(), :vouch, state.every)
    {last, state} = vouch_all(state)
    {:noreply, %{state | last: last}}
  end

  # One account's inbox, tried again after a failure, until it exists.
  def handle_info({:prepare, id}, state) do
    state = %{state | retries: Map.update(state.retries, id, nil, &Map.put(&1, :timer, nil))}

    case on?() && List.keyfind(running(), id, 0) do
      {^id, effects} -> {:noreply, prepare_or_retry(state, id, effects)}
      _ -> {:noreply, %{state | retries: Map.delete(state.retries, id)}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc "Whether AtMcp keeps the AppView reading inboxes: town spaces and Spaces on."
  def on? do
    AtMcp.Network.spaces() != nil and AtMcp.Spaces.Helper.available() == :ok
  end

  @doc false
  # One pass over the running accounts that have a login key: each one's
  # inbox is made if it has none, then kept read as its mode says. Answers
  # what each account did, and the state after.
  def vouch_all(state, accounts \\ nil) do
    if on?() do
      now = System.monotonic_time(:millisecond)

      Enum.reduce(accounts || running(), {%{}, state}, fn {id, effects}, {last, state} ->
        {did_now, state} = pass(state, id, effects, now)
        {Map.put(last, id, did_now), state}
      end)
    else
      {%{}, state}
    end
  end

  defp pass(state, id, effects, now) do
    renewed? = MapSet.member?(state.renewed, did_of(effects))
    state = %{state | renewed: MapSet.delete(state.renewed, did_of(effects))}
    {status, state} = inbox_pass(state, id, effects, now, renewed?)
    {status, groups_pass(state, id, effects, now, renewed?)}
  end

  # The account's groups, as its inbox: the AppView reads a group it is a
  # member of (the default on groups.delve.town) without tokens, so each
  # group's members space is registered once, at start and on a new session;
  # a group without the AppView gets a token for its members space and feeds
  # at most every 8 minutes. Membership is looked at again every 30 minutes,
  # which also finds groups joined since.
  defp groups_pass(state, id, effects, now, renewed?) do
    entry = state.groups[id]

    entry =
      cond do
        is_nil(entry) or renewed? -> check_groups(effects, true, entry, now)
        now - entry.checked_at >= state.keepalive -> check_groups(effects, :new, entry, now)
        true -> entry
      end

    case entry do
      nil ->
        state

      entry ->
        groups =
          Map.new(entry.groups, fn
            {g, %{member?: true} = info} ->
              {g, info}

            {g, info} ->
              if renewed? or is_nil(info.token_at) or now - info.token_at >= state.token_every do
                Enum.each(info.spaces, &vouch_space(effects, &1))
                {g, %{info | token_at: now}}
              else
                {g, info}
              end
          end)

        %{state | groups: Map.put(state.groups, id, %{entry | groups: groups})}
    end
  end

  defp check_groups(effects, register, previous, now) do
    known = if previous, do: previous.groups, else: %{}

    register =
      if register == :new, do: {:except, Map.keys(known)}, else: register

    case AtMcp.Effects.spaces(effects, :group_spaces, [[register: register]]) do
      {:ok, found} ->
        groups =
          Map.new(found, fn %{group: g} = info ->
            {g,
             %{
               member?: info.member?,
               spaces: info.spaces,
               token_at: get_in(known, [g, :token_at])
             }}
          end)

        %{checked_at: now, groups: groups}

      {:error, reason} ->
        Logger.info("reading the account's groups failed: #{inspect(reason, limit: 5)}")
        # Tried again at the next pass when nothing was known yet.
        previous && %{previous | checked_at: now}
    end
  catch
    :exit, _ -> previous
  end

  defp vouch_space(effects, space) do
    AtMcp.Effects.spaces(effects, :vouch_space, [space])
  catch
    :exit, _ -> :failed
  end

  defp inbox_pass(state, id, effects, now, renewed?) do
    case state.modes[id] do
      nil ->
        if pending_retry?(state, id) do
          {:waiting, state}
        else
          state = prepare_or_retry(state, id, effects)
          {if(state.modes[id], do: state.modes[id].mode, else: :no_inbox), state}
        end

      %{mode: :reader, at: at} when not renewed? and now - at < state.keepalive ->
        {:reader, state}

      %{mode: :reader} ->
        keep_alive(state, id, effects, now, renewed?)

      %{mode: :tokens, listed: false} ->
        # The inbox doesn't list the AppView: tokens are the only way.
        token(state, id, effects, now, renewed?)

      %{mode: :tokens, at: at} ->
        # Listed, but the AppView wouldn't read it as a member: now and
        # then, see whether it does again.
        if renewed? or now - at >= state.keepalive,
          do: keep_alive(state, id, effects, now, renewed?),
          else: token(state, id, effects, now, false)
    end
  end

  # Registers the inbox without a token where it lists the AppView; any
  # answer but `registered` falls back to tokens.
  defp keep_alive(state, id, effects, now, renewed?) do
    token_at = get_in(state.modes, [id, :token_at])

    case register(effects) do
      "registered" ->
        {"registered", put_mode(state, id, :reader, now, token_at, true)}

      _other ->
        state |> put_mode(id, :tokens, now, token_at, true) |> token(id, effects, now, renewed?)
    end
  end

  # A delegation token, at most every 8 minutes for the inbox, whatever the
  # AppView answers; once at once after the session is established anew.
  defp token(state, id, effects, now, renewed?) do
    token_at = get_in(state.modes, [id, :token_at])

    if renewed? or is_nil(token_at) or now - token_at >= state.token_every do
      status = vouch(effects)
      {status, put_in(state.modes[id][:token_at], now)}
    else
      {:tokens, state}
    end
  end

  defp put_mode(state, id, mode, now, token_at, listed),
    do: %{
      state
      | modes:
          Map.put(state.modes, id, %{mode: mode, at: now, token_at: token_at, listed: listed})
    }

  defp pending_retry?(state, id), do: match?(%{timer: t} when t != nil, state.retries[id])

  defp prepare_or_retry(state, id, effects) do
    case prepared(effects) do
      {:ok, notifications} ->
        # Registered as a listed reader when the inbox was made or found:
        # no tokens. Otherwise tokens, from this pass on.
        mode = if notifications == "registered", do: :reader, else: :tokens
        # "off": the inbox doesn't list the AppView.
        listed = notifications != "off"
        now = System.monotonic_time(:millisecond)

        state = %{
          put_mode(state, id, mode, now, nil, listed)
          | retries: Map.delete(state.retries, id)
        }

        if mode == :tokens,
          do: state |> token(id, effects, now, false) |> elem(1),
          else: state

      :failed ->
        delay = next_delay(state.retries[id], state.retry_first, state.every)

        # At the pass's own length the pass tries it; sooner, a timer does.
        timer =
          if delay < state.every, do: Process.send_after(self(), {:prepare, id}, delay)

        %{state | retries: Map.put(state.retries, id, %{delay: delay, timer: timer})}
    end
  end

  @doc false
  # How long after a failed attempt to make an inbox the next one comes.
  def next_delay(%{delay: previous}, _first, every), do: min(previous * 2, every)
  def next_delay(_none, first, _every), do: first

  defp running do
    for id <- AtMcp.Identities.list_ids(),
        effects = AtMcp.Identity.effects_name(id),
        effects != nil,
        key?(effects),
        do: {id, effects}
  end

  defp key?(effects) do
    case AtMcp.Effects.session_did(effects) do
      did when is_binary(did) -> AtMcp.Spaces.Login.key?(did)
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  @doc false
  # Makes the account's inbox, with the town AppView as its listed reader
  # where that is on, and registers it with the AppView.
  def prepare(effects) do
    case prepared(effects) do
      {:ok, _notifications} -> :ok
      :failed -> :failed
    end
  end

  # As prepare/1, with whether the AppView then reads the inbox as a member
  # (`"registered"`) or not.
  defp prepared(effects) do
    case AtMcp.Effects.spaces(effects, :prepare_inbox, []) do
      {:ok, %{notifications: notifications}} ->
        {:ok, notifications}

      {:error, reason} ->
        Logger.info("making the account's invite inbox failed: #{inspect(reason, limit: 5)}")
        :failed
    end
  catch
    :exit, _ -> :failed
  end

  # The keep-alive registration, without a token: the AppView's answer.
  defp register(effects) do
    case AtMcp.Effects.spaces(effects, :register_inbox_now, []) do
      {:ok, status} -> status
      {:error, _reason} -> :failed
    end
  catch
    :exit, _ -> :failed
  end

  defp did_of(effects) do
    AtMcp.Effects.session_did(effects)
  catch
    :exit, _ -> nil
  end

  @doc false
  def vouch(effects) do
    case AtMcp.Effects.spaces(effects, :vouch_inbox, []) do
      {:ok, %{status: status}} ->
        status

      {:error, %AtMcp.Effects.Failure{detail: "SpaceNotFound"}} ->
        :no_inbox

      {:error, reason} ->
        Logger.info(
          "handing the town AppView an inbox token failed: #{inspect(reason, limit: 5)}"
        )

        :failed
    end
  catch
    :exit, _ -> :failed
  end
end
