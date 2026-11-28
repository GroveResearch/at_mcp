defmodule AtMcp.Spaces do
  @moduledoc """
  What an agent does with atproto Spaces, Atmosphere Groups and its own
  agents, for one account: the work behind the notes, group, principal and
  identity tools.

  - **Notes** are an agent's: they live in its state space,
    `town.delve.space.agent`, whose authority is its principal and whose key
    is the agent's DID; principal and agent are both read/write members. The
    principal's at_mcp makes it when it creates the agent. A space decides who
    can read it, but it is **not encrypted**: the operators of the PDS holding
    it can read it. `readable_by/0` says so in every note result.
  - **Groups** are on a group host (`AT_MCP_GROUP_HOST`). Joining, leaving,
    accepting an invite and approving an app for a group are `org.atgrp.*`
    calls to the host with service auth from the account's own PDS. A group
    space is read and written through the Spaces helper, with the account's
    OAuth session.
  - **Principal** routes are the town PDS's `town.delve.agent.*`, called
    with service auth from the account's own PDS (`aud` the PDS's DID).
  - **Identity**: the ident.link pair. A principal writes
    `link.ident.endorsement` (key: the agent's DID) in its own repository;
    the agent's DID document names `https://ident.link/agent-of/<principal>`.

  Everything that needs Spaces goes through `AtMcp.Spaces.Helper`, which
  holds the account's OAuth session. An account gets one from its login key
  (`key_file` in the accounts file): the helper logs in with it on first use
  and again whenever the session can no longer be refreshed. The key file's
  path comes only from the accounts file; no tool takes it or shows it.

  `org.atgrp.*`, `link.ident.*` and `com.atproto.*` names are written out
  here: they are the same on every network, as `com.atproto.*` is. The
  town's own names come from `AtMcp.Network.spaces/0`.
  """

  require Logger

  alias AtMcp.Effects.Failure
  alias AtMcp.Spaces.Helper
  alias ProtoRune.Session

  @readable_by "This agent and its principal, and the apps they have granted access. Spaces are not encrypted: the operators of the server holding them can read them, so keep no secrets here."

  @inbox_soon "Your invite inbox will be created shortly; until then, invites are listed from the group host."
  @tokens_notice "This installation doesn't list the town's AppView as a reader of this account's invite inbox (AT_MCP_TOWN_INBOX_READER=false), so the AppView reads it only with the short-lived tokens at_mcp hands it while it runs: group invites reach get_notifications only while at_mcp runs, and up to about 8 minutes after they arrive. They are always listed in get_group_invites at once."
  @reader_notice "The town's AppView is now a listed reader of this account's invite inbox, so it can tell this account about group invites in get_notifications, also while at_mcp isn't running. It reads only the invites; nothing else in the account becomes readable. To remove it, take the AppView off the inbox's members; the installation's operator can stop at_mcp adding it to new inboxes (AT_MCP_TOWN_INBOX_READER=false)."

  @doc "What a note result says about who can read it."
  def readable_by, do: @readable_by

  # The town PDS counts the mutating agent routes as privileged: service auth
  # for them is minted only for a session that holds the matching `rpc:`
  # scope (or a full password session), never for an app password.
  @agent_methods ~w(createAgent enrollKey revokeSessions deleteAgent rotatePassword offerTransfer acceptTransfer listAgents)

  @doc """
  The OAuth scope at_mcp asks for when an account's key logs it in, no more
  than the account needs:

  - `transition:generic`, for the app's public tools;
  - its agents' state spaces (creating them and setting their members), and,
    as an agent, its own state space under its principal; every group feed
    it is in, and its own inbox (creating it, reading its own repository
    there, and adding the town AppView to its members, which takes
    `manage=update`);
  - only for an account acting as a principal (`principal?/1`), the agent
    routes, each by name, for its own PDS's service
    (`rpc:town.delve.agent.<method>?aud=<PDS DID>#atproto_pds`). The PDS
    mints service auth for them for nothing broader.

  `service` is the account's PDS, whose DID the agent routes name.
  """
  def scope_for(did, service \\ nil) do
    case AtMcp.Network.spaces() do
      %{feed: feed, agent: agent} ->
        base = [
          "atproto",
          "transition:generic",
          "space:#{feed}?authority=*",
          # A group's members space, read for its delegation token where the
          # AppView isn't a member of the group (`vouch_space/2`).
          "space:org.atgrp.members?authority=*&action=read",
          # Its agents' state spaces, as their principal (`make_agent_space/2`),
          # and, as an agent, its own, under its principal.
          "space:town.delve.space.agent?manage=create&manage=update",
          "space:town.delve.space.agent?authority=*&collection=*",
          # The member's own confirmation there (`confirm_membership/2`).
          "space:org.atgrp.members?authority=*&collection=org.atgrp.confirmation",
          inbox_scope()
        ]

        rpc =
          with true <- is_binary(did) and principal?(did),
               {:ok, pds} <- service_did(service, did) do
            aud = URI.encode_www_form(pds <> "#atproto_pds")

            # The PDS's permission set for its agent routes, which its
            # consent screen names in words ("Create and manage agents you
            # answer for"); the routes by name where the PDS can't resolve
            # the set yet (AT_MCP_AGENT_SCOPE=rpc).
            if agent_scope() == :include,
              do: ["include:#{agent_set(agent)}?aud=#{aud}"],
              else: for(m <- @agent_methods, do: "rpc:#{agent}.#{m}?aud=#{aud}")
          else
            _ -> []
          end

        Enum.join(base ++ rpc, " ")

      nil ->
        "atproto transition:generic"
    end
  end

  @doc false
  # How a principal asks for the agent routes: `:include`, the PDS's
  # permission set (the default), or `:rpc`, each route by name
  # (`AT_MCP_AGENT_SCOPE`).
  def agent_scope, do: Application.get_env(:at_mcp, :agent_scope, :include)

  # The permission set beside the agent routes' namespace:
  # `town.delve.agent` -> `town.delve.authManageAgents`.
  defp agent_set(agent_ns), do: String.replace_suffix(agent_ns, ".agent", ".authManageAgents")

  # The inbox: making it, and reading it, which a delegation token for it
  # needs (`vouch_inbox/1`); adding the AppView to its members, only when
  # the installation does (`inbox_readers/0`).
  defp inbox_scope do
    if Application.get_env(:at_mcp, :town_inbox_reader, true),
      do: "space:org.atgrp.inbox?action=read&manage=create&manage=update",
      else: "space:org.atgrp.inbox?action=read&manage=create"
  end

  # The DID of the PDS at `service` (its describeServer), cached. With no
  # service given, the accounts file's for the principal.
  defp service_did(nil, did) do
    case AtMcp.AccountConfig.load(AtMcp.AccountConfig.path()) do
      {:ok, accounts} ->
        case Enum.find(accounts, &(&1["did"] == did)) do
          %{"service" => service} when is_binary(service) -> service_did(service, did)
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp service_did(service, _did) do
    base = service |> String.trim_trailing("/") |> String.trim_trailing("/xrpc")

    case :persistent_term.get({__MODULE__, :service_did, base}, nil) do
      nil ->
        with {:ok, %{"did" => did}} <-
               http(:get, base <> "/xrpc/com.atproto.server.describeServer", nil, %{}) do
          :persistent_term.put({__MODULE__, :service_did, base}, did)
          {:ok, did}
        end

      did ->
        {:ok, did}
    end
  end

  @doc """
  The accounts added to every new inbox as read-only members: the town
  AppView's own DID, so it can raise notifications of invites, on the network
  that has town spaces, unless `AT_MCP_TOWN_INBOX_READER=false`. The reader
  is the only way the account hears of an invite while AtMcp isn't running;
  it is listed among the inbox's members, where it can be seen and removed.
  Off, an inbox has no members, and the AppView reads it only with the
  tokens AtMcp hands it while it runs (`AtMcp.Spaces.InboxTokens`), which it
  does either way.
  """
  def inbox_readers do
    if AtMcp.Network.spaces() && Application.get_env(:at_mcp, :town_inbox_reader, true) do
      [AtMcp.Network.appview_service() |> String.split("#") |> hd()]
    else
      []
    end
  end

  # --- an agent's notes, in its state space ---

  # An agent's state space (`agent_space_uri/2`), where an agent's notes go.
  @agent_space "town.delve.space.agent"

  @note_fields ~w(text title tags)
  # The note lexicon's limits (`town.delve.notes.note`, in
  # spaces_helper/lexicons): 10 bytes a grapheme, as the town's lexicon style
  # has it. A title is at most 300, a tag 64, and a note holds 16 tags.
  @note_graphemes 30_000
  @note_bytes 300_000

  def create_note(session, fields) do
    with {:ok, names} <- names(),
         {:ok, record} <- note_record(fields, nil),
         {:ok, space} <- notes_space(session) do
      write = fn ->
        helper(session, "space.records.create", %{
          space: space,
          collection: names.note,
          record: record
        })
      end

      write.()
      |> own_state_space(session, space, write)
      |> missing_state_space(space)
      |> note_written(record)
    end
  end

  def get_note(session, rkey) do
    with {:ok, names} <- names(),
         :ok <- rkey_arg(rkey),
         {:ok, space} <- notes_space(session),
         {:ok, got} <-
           helper(session, "space.records.get", %{
             space: space,
             collection: names.note,
             rkey: rkey
           }) do
      {:ok,
       note_summary(
         note_uri(space, session, names, got["uri"], rkey),
         got["cid"],
         got["value"] || %{}
       )}
    end
  end

  def list_notes(session, limit, cursor) do
    with {:ok, names} <- names(),
         {:ok, space} <- notes_space(session),
         {:ok, page} <-
           helper(session, "space.records.list", %{
             space: space,
             collection: names.note,
             limit: limit || AtMcp.Effects.page_limits().default,
             cursor: cursor
           }) do
      {:ok,
       %{
         notes:
           for r <- page["records"] || [] do
             note_summary(
               note_uri(space, session, names, r["uri"], r["rkey"]),
               r["cid"],
               r["value"] || %{}
             )
           end,
         cursor: page["cursor"],
         readable_by: @readable_by
       }}
    else
      {:error, %Failure{detail: "SpaceNotFound"}} ->
        {:ok, %{notes: [], cursor: nil, readable_by: @readable_by}}

      error ->
        error
    end
  end

  def update_note(session, rkey, fields) do
    with {:ok, names} <- names(),
         :ok <- rkey_arg(rkey),
         {:ok, space} <- notes_space(session),
         {:ok, got} <-
           helper(session, "space.records.get", %{
             space: space,
             collection: names.note,
             rkey: rkey
           }),
         {:ok, record} <- note_record(fields, got["value"] || %{}) do
      helper(session, "space.records.put", %{
        space: space,
        collection: names.note,
        rkey: rkey,
        record: record
      })
      |> note_written(record)
    end
  end

  def delete_note(session, rkey) do
    with {:ok, names} <- names(),
         :ok <- rkey_arg(rkey),
         {:ok, space} <- notes_space(session),
         {:ok, _} <-
           helper(session, "space.records.delete", %{
             space: space,
             collection: names.note,
             rkey: rkey
           }) do
      {:ok, %{deleted: true, rkey: rkey}}
    end
  end

  # A new note's record, or an existing one's with the changes. A field
  # given as an empty string or list is removed, except text.
  defp note_record(fields, current) do
    fields = Map.new(fields, fn {k, v} -> {to_string(k), v} end) |> Map.take(@note_fields)
    now = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

    base =
      case current do
        nil -> %{"createdAt" => now}
        record -> record |> Map.delete("$type") |> Map.put("updatedAt", now)
      end

    record =
      Enum.reduce(fields, base, fn
        {"text", text}, acc -> Map.put(acc, "text", text)
        {_key, nil}, acc -> acc
        {key, ""}, acc -> Map.delete(acc, key)
        {key, []}, acc -> Map.delete(acc, key)
        {key, value}, acc -> Map.put(acc, key, value)
      end)

    cond do
      not is_binary(record["text"]) or String.trim(record["text"]) == "" ->
        invalid("text", "is required and may not be empty")

      String.length(record["text"]) > @note_graphemes or byte_size(record["text"]) > @note_bytes ->
        invalid(
          "text",
          "may be at most #{@note_graphemes} characters (#{@note_bytes} bytes); split a longer note into several"
        )

      record["title"] &&
          (not is_binary(record["title"]) or String.length(record["title"]) > 300 or
             byte_size(record["title"]) > 3000) ->
        invalid("title", "may be at most 300 characters (3000 bytes)")

      record["tags"] && (not is_list(record["tags"]) or length(record["tags"]) > 16) ->
        invalid("tags", "may hold at most 16 tags")

      record["tags"] &&
          Enum.any?(record["tags"], fn tag ->
            not is_binary(tag) or String.length(tag) > 64 or byte_size(tag) > 640
          end) ->
        invalid("tags", "each tag is text of at most 64 characters (640 bytes)")

      true ->
        {:ok, record}
    end
  end

  defp note_written({:ok, %{"uri" => uri} = written}, record),
    do: {:ok, note_summary(uri, written["cid"], record)}

  defp note_written({:ok, other}, _record),
    do: {:error, Failure.new(:indeterminate, detail: :unreadable_write, message: inspect(other))}

  defp note_written(error, _record), do: error

  defp note_summary(uri, cid, value) do
    %{
      uri: uri,
      rkey: uri && uri |> String.split("/") |> List.last(),
      cid: cid,
      title: value["title"],
      text: value["text"],
      tags: value["tags"] || [],
      created_at: value["createdAt"],
      updated_at: value["updatedAt"],
      readable_by: @readable_by
    }
  end

  # A space's listRecords and getRecord answer the record's key and CID but
  # no URI, so a note's URI is built from the space, the account and the key:
  # the URI a write answers for it.
  defp note_uri(_space, _session, _names, uri, _rkey) when is_binary(uri), do: uri
  defp note_uri(_space, _session, _names, nil, nil), do: nil

  defp note_uri(space, session, names, nil, rkey),
    do: "#{space}/#{Session.did(session)}/#{names.note}/#{rkey}"

  # Where this account keeps its notes: its state space, under its
  # principal (`agent_space_uri/2`); an account with no principal (a
  # resident, an email agent) keeps one under its own DID, as its own
  # authority, made at its first note.
  defp notes_space(session) do
    # Spaces off is said first: it is so for every account.
    with :ok <- helper_ready(), do: notes_space_of(session)
  end

  defp helper_ready do
    case Helper.available() do
      :ok -> :ok
      {:error, reason} -> {:error, Helper.unavailable(reason)}
    end
  end

  defp notes_space_of(session) do
    did = Session.did(session)

    case principal_of(session) do
      {:ok, principal} -> {:ok, agent_space_uri(principal, did)}
      :none -> {:ok, agent_space_uri(did, did)}
      {:error, _} = error -> error
    end
  end

  # How long a principal found is believed before it is looked at again: a
  # hand-off changes it. Failures aren't kept at all.
  @principal_ttl_ms 5 * 60_000

  # The principal whose state space holds this account's notes:
  #
  #   * `{:ok, principal}`: the one principal its DID document names
  #     (`agent-of`) whose endorsement its repository proves
  #     (`endorsement/3`), recorded as the account's binding
  #     (`AtMcp.Spaces.StateHome`);
  #   * `:none`: its DID document names no principal: it governs itself;
  #   * `{:error, _}`: it can't be said now (the DID document or a
  #     principal's repository unreadable, no claimed principal confirmed, or
  #     more than one): notes are refused with what is wrong, never sent to
  #     the account's own space instead. While the lookup is unavailable, the
  #     binding recorded before holds.
  #
  # A result is kept for `@principal_ttl_ms`; a value put without a time
  # (tests) is kept.
  defp principal_of(session) do
    did = Session.did(session)
    key = {__MODULE__, :principal_of, did}
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(key, nil) do
      {:resolved, found, at} when now - at < @principal_ttl_ms -> found
      {:resolved, _found, _at} -> resolve_principal(session, key, now)
      nil -> resolve_principal(session, key, now)
      found -> found
    end
  end

  defp resolve_principal(session, key, now) do
    did = Session.did(session)

    case principal_from_identity(session, did) do
      {:error, %Failure{detail: :principal_unavailable}} = unavailable ->
        # Not a no: the binding recorded before holds.
        case AtMcp.Spaces.StateHome.principal(did) do
          nil -> unavailable
          principal -> {:ok, principal}
        end

      {:error, _} = error ->
        error

      found ->
        :persistent_term.put(key, {:resolved, found, now})
        principal = with({:ok, p} <- found, do: p, else: (:none -> did))

        # Handed to another principal since: its records come along first,
        # and the binding moves once they have.
        case AtMcp.Spaces.StateHome.principal(did) do
          previous when previous in [nil, principal] ->
            AtMcp.Spaces.StateHome.bind(did, principal)

          previous ->
            if carry(session, previous, principal) == :ok,
              do: AtMcp.Spaces.StateHome.bind(did, principal)
        end

        found
    end
  end

  defp principal_from_identity(session, did) do
    case resolve_did_doc(session, did) do
      {:ok, doc} ->
        claimed = for "https://ident.link/agent-of/" <> p <- doc["alsoKnownAs"] || [], do: p

        if claimed == [] do
          :none
        else
          checked = for p <- Enum.uniq(claimed), do: {p, endorsement(session, p, did)}

          case for({p, "confirmed"} <- checked, do: p) do
            [principal] ->
              {:ok, principal}

            [_, _ | _] = several ->
              {:error,
               Failure.new(:refused,
                 detail: :principal_conflict,
                 message:
                   "This account's identity names more than one confirmed principal (#{Enum.join(several, ", ")}), so where its notes go can't be said: its principals settle which one answers for it."
               )}

            [] ->
              if Enum.any?(checked, fn {_, s} -> s == "unavailable" end),
                do: principal_unavailable(Enum.map(checked, &elem(&1, 0))),
                else:
                  {:error,
                   Failure.new(:refused,
                     detail: :principal_unconfirmed,
                     message:
                       "This account's identity names #{Enum.join(claimed, ", ")} as its principal, but no endorsement its repository proves confirms it, so its notes aren't written: its principal writes the endorsement (endorse_agent)."
                   )}
          end
        end

      _ ->
        principal_unavailable([did])
    end
  end

  defp principal_unavailable(dids),
    do: {
      :error,
      # Nothing was sent: a refusal, whose cause passes.
      Failure.new(:refused,
        detail: :principal_unavailable,
        message:
          "Who governs this account's notes couldn't be read now (#{Enum.join(dids, ", ")}: identity or repository unavailable); nothing was written. Try again shortly."
      )
    }

  # An account that is its own authority makes its state space at its
  # first note; an agent's is its principal's to make.
  defp own_state_space(
         {:error, %Failure{detail: "SpaceNotFound"}} = missing,
         session,
         space,
         write
       ) do
    did = Session.did(session)

    if space == agent_space_uri(did, did) do
      with {:ok, _} <-
             helper(session, "space.create", %{
               type: @agent_space,
               skey: did,
               policy: "member",
               members: [%{did: did, read: true, write: true}]
             }),
           do: write.()
    else
      missing
    end
  end

  defp own_state_space(result, _session, _space, _write), do: result

  # The state space is the principal's to make.
  defp missing_state_space({:error, %Failure{detail: "SpaceNotFound"} = f}, space),
    do:
      {:error,
       %{
         f
         | message:
             "This agent's state space (#{space}) doesn't exist yet: its principal's at_mcp makes it when it creates the agent, or the principal can make it."
       }}

  defp missing_state_space(result, _space), do: result

  # --- groups ---

  @doc """
  The invites waiting for this account, from the group host's own list. A
  read: the account's inbox is made by `AtMcp.Spaces.InboxTokens` when AtMcp
  starts (`prepare_inbox/1`), not here. Until it exists, the invites are
  still listed from the group host, and the result says the inbox will be
  made shortly. The one-time notice about the inbox's reader comes with the
  first read after the inbox was made that answers (`take_notice/1`).
  """
  def list_group_invites(session) do
    space = "at:space/#{Session.did(session)}/org.atgrp.inbox/self"

    inbox =
      case helper(session, "space.get", %{space: space}) do
        {:ok, _} -> space
        {:error, %Failure{detail: "SpaceNotFound"}} -> nil
        # Can't tell now: the group host's list still answers.
        {:error, _} -> :unknown
      end

    with {:ok, body} <- group_host_get(session, "org.atgrp.internal.getActorInvites", %{}) do
      invites =
        for invite <- Map.get(body, "invites", []) do
          did = get_in(invite, ["group", "did"])
          view = if did, do: group_view(session, did, invite["group"] || %{}), else: %{}

          %{
            group: view,
            message: invite["message"],
            created_at: invite["createdAt"]
          }
        end

      result =
        %{
          invites: invites,
          inbox: if(is_binary(inbox), do: inbox),
          notifications:
            if(is_binary(inbox),
              do: :persistent_term.get({__MODULE__, :inbox_status, Session.did(session)}, nil)
            )
        }
        |> put_present(:inbox_note, if(is_nil(inbox), do: @inbox_soon))
        |> put_present(:notice, if(is_binary(inbox), do: take_notice(Session.did(session))))

      {:ok, result}
    end
  end

  @doc """
  The account's inbox (`org.atgrp.inbox`, key `self`), made if missing, and
  whether the town AppView raises its invites as notifications: when the
  inbox lists the AppView as a reader (`inbox_readers/0`), AtMcp asks the
  AppView to read it (`registerSpace`, which needs no delegation token
  then). A refused registration leaves the inbox as it is, and says so.
  """
  def ensure_inbox(session) do
    with {:ok, %{"space" => space} = inbox} <- helper(session, "inbox.ensure", %{}) do
      {notifications, notice} =
        case inbox["listed"] || inbox["readers"] do
          [_ | _] ->
            # Said once, when the inbox is made with the reader, or when the
            # reader is first added to an inbox that had none.
            {register_inbox(session, space),
             if(inbox["added"] not in [nil, []], do: @reader_notice)}

          _ ->
            # Said once, when the inbox is made without the reader.
            {"off", if(inbox["created"] == true, do: @tokens_notice)}
        end

      {:ok, space, notifications, notice}
    end
  end

  @doc """
  Hands the town AppView a fresh delegation token for this account's inbox
  (`registerSpace` with `delegationToken`), so it can read the inbox and
  raise its invites as notifications without being a member of it. A token
  lasts 60 seconds and is spent once; `AtMcp.Spaces.InboxTokens` hands one
  over as often as the AppView needs. Only for an inbox that exists: making
  one is `prepare_inbox/1`'s.
  """
  def vouch_inbox(session) do
    vouch_inbox_now(session)
  end

  @doc """
  Makes the account's inbox if it has none, so a group can invite the
  account at all: a group writes its invite into the invitee's inbox, and
  only the invitee's own client can make it. `AtMcp.Spaces.InboxTokens` calls
  it for each key-holding account when AtMcp starts, and again until the
  inbox exists. The reader notice it owes waits for the account's next
  `get_notifications` or `get_group_invites` (`take_notice/1`).
  """
  def prepare_inbox(session) do
    did = Session.did(session)

    with {:ok, space, notifications, notice} <- ensure_inbox(session) do
      :persistent_term.put({__MODULE__, :inbox_status, did}, notifications)
      if notice, do: :persistent_term.put({__MODULE__, :owed_notice, did}, notice)
      {:ok, %{space: space, notifications: notifications}}
    end
  end

  @doc """
  The one-time notice owed to the account `did` about its inbox's reader,
  once: nil when none is owed or it was already given.
  """
  def take_notice(did) when is_binary(did) do
    key = {__MODULE__, :owed_notice, did}

    case :persistent_term.get(key, nil) do
      nil ->
        nil

      notice ->
        :persistent_term.erase(key)
        notice
    end
  end

  def take_notice(_did), do: nil

  defp vouch_inbox_now(session) do
    space = "at:space/#{Session.did(session)}/org.atgrp.inbox/self"

    with {:ok, _} <- helper(session, "space.get", %{space: space}),
         {:ok, %{"token" => token}} <- helper(session, "space.delegationToken", %{space: space}) do
      case register_space(session, %{space: space, delegationToken: token}) do
        {:ok, %{status: status}} -> {:ok, %{space: space, status: status}}
        {:ok, %{"status" => status}} -> {:ok, %{space: space, status: status}}
        {:ok, _} -> {:ok, %{space: space, status: "registered"}}
        {:error, reason} -> {:error, to_failure(reason)}
      end
    end
  end

  @doc """
  The groups this account belongs to, for keeping the town AppView reading
  them as it reads the inbox: each group's members space and feeds, and
  whether the AppView is a member of the group (the group host's
  `listMembers`, asked for the AppView's DID), so it reads them without
  client tokens. With `register: true`, each group's members space is
  registered with the AppView first (`registerSpace` without a token), or
  with `register: {:except, known}` each group's not among `known`: the
  AppView accepts that whether or not it may read the space, so its answer
  doesn't say whether it is a member; the group host's list does.
  """
  def group_spaces(session, opts \\ []) do
    reader = AtMcp.Network.appview_service() |> String.split("#") |> hd()

    with {:ok, %{groups: groups}} <- get_my_groups(session) do
      {:ok,
       for %{did: did} = g <- groups, is_binary(did) do
         members =
           Enum.find_value(g.spaces, "at:space/#{did}/org.atgrp.members/self", fn
             %{type: "org.atgrp.members", uri: uri} -> uri
             _ -> nil
           end)

         register? =
           case Keyword.get(opts, :register, false) do
             {:except, known} -> did not in known
             register -> register == true
           end

         if register?, do: register_space(session, %{space: members})

         member? =
           case group_host_get(session, "org.atgrp.internal.listMembers", %{
                  "group" => did,
                  "q" => reader,
                  "limit" => 1
                }) do
             {:ok, %{"members" => found}} when is_list(found) ->
               Enum.any?(found, &(get_in(&1, ["actor", "did"]) == reader))

             # Can't tell: tokens, so nothing is missed.
             _ ->
               false
           end

         %{group: did, member?: member?, spaces: [members | g.feeds]}
       end}
    end
  end

  @doc """
  Hands the town AppView a fresh delegation token for `space` (a group's
  members space or feed this account reads), as `vouch_inbox/1` does for
  the inbox: for a group the AppView isn't a member of. A session from
  before the members-space scope was asked for logs in again once.
  """
  def vouch_space(session, space) when is_binary(space) do
    with {:ok, %{"token" => token}} <- space_token(session, space) do
      case register_space(session, %{space: space, delegationToken: token}) do
        {:ok, %{status: status}} -> {:ok, %{space: space, status: status}}
        {:ok, %{"status" => status}} -> {:ok, %{space: space, status: status}}
        {:ok, _} -> {:ok, %{space: space, status: "registered"}}
        {:error, reason} -> {:error, to_failure(reason)}
      end
    end
  end

  defp space_token(session, space) do
    case helper(session, "space.delegationToken", %{space: space}) do
      {:error, %Failure{detail: detail}} when detail in ["ScopeMissing", "InsufficientScope"] ->
        did = Session.did(session)

        with {:ok, _creds} <- AtMcp.Spaces.Login.fresh(did),
             do: helper(session, "space.delegationToken", %{space: space})

      other ->
        other
    end
  end

  @doc """
  Asks the town AppView to read this account's inbox as the listed reader
  it is (`registerSpace` without a token): `{:ok, "registered"}`, or the
  AppView's other answer (`disabled`, `unsupported`, `limit`), or an error.
  `AtMcp.Spaces.InboxTokens`' keep-alive where the inbox lists the AppView.
  """
  def register_inbox_now(session) do
    space = "at:space/#{Session.did(session)}/org.atgrp.inbox/self"

    case register_space(session, %{space: space}) do
      {:ok, %{status: status}} -> {:ok, status}
      {:ok, %{"status" => status}} -> {:ok, status}
      {:ok, _} -> {:ok, "registered"}
      {:error, reason} -> {:error, to_failure(reason)}
    end
  end

  defp register_inbox(session, space) do
    case register_space(session, %{space: space}) do
      {:ok, %{status: status}} -> status
      {:ok, %{"status" => status}} -> status
      {:ok, _} -> "registered"
      {:error, reason} -> "not registered: " <> (to_failure(reason).message || "refused")
    end
  end

  @doc """
  Joins a group, by its invite or by asking. Once admitted, answers the group
  as `get_my_groups` does: its spaces, and its feeds to post in.
  """
  def join_group(session, group, invite \\ nil, message \\ nil) do
    with {:ok, group} <- group_arg(session, group) do
      body =
        %{"group" => group} |> put_present("invite", invite) |> put_present("message", message)

      with {:ok, joined} <- group_host_post(session, "org.atgrp.requestJoin", body) do
        case joined["status"] do
          "admitted" ->
            # Confirmed first, so the group as answered counts it. If it
            # can't be written now, this account's asking is kept, so it is
            # confirmed later.
            result = confirm_membership(session, group)
            if match?({:error, _}, result), do: remember_asked(session, group)
            confirmation = confirmed(result)

            {:ok,
             joined |> Map.put("group", group_view(session, group)) |> Map.merge(confirmation)}

          _ ->
            # Asked, and waiting: confirmed when the group lets it in.
            remember_asked(session, group)
            {:ok, joined}
        end
      end
    end
  end

  @doc """
  The groups this account is in on the group host, each with its DID,
  handle, name, description, its spaces and the feeds among them.
  """
  def get_my_groups(session) do
    with {:ok, body} <-
           group_host_get(session, "org.atgrp.internal.getActorGroups", %{
             "actor" => Session.did(session),
             "limit" => 50
           }) do
      groups =
        for g <- body["groups"] || [] do
          view = group_view(session, g["did"], g)
          Map.merge(view, new_posts(session, view.feeds))
        end

      {:ok, %{groups: groups}}
    end
  end

  # A group as the host shows it to this account (getGroup): who it is,
  # and, once this account is a member, its spaces.
  defp group_view(session, did, basic \\ %{}) do
    detail =
      case group_host_get(session, "org.atgrp.internal.getGroup", %{"group" => did}) do
        {:ok, body} -> body
        _ -> %{}
      end

    group = Map.merge(basic, detail["group"] || %{})
    spaces = for sp <- detail["spaces"] || [], do: %{uri: sp["uri"], type: sp["spaceType"]}
    feed_type = names_feed()

    %{
      did: did,
      handle: group["handle"],
      display_name: group["displayName"],
      description: group["description"],
      spaces: spaces,
      feeds: for(%{type: ^feed_type, uri: uri} <- spaces, do: uri),
      # Whether the group host counts this account's own confirmation of its
      # membership (`confirm_membership/2`); nil when it doesn't say.
      confirmed: get_in(detail, ["group", "viewer", "accepted"]),
      # Unconfirmed and never asked for: the group made this account a
      # member. It decides: confirm_group_membership, or leave_group.
      added_by_group:
        get_in(detail, ["group", "viewer", "accepted"]) == false and not asked?(session, did)
    }
  end

  # How many posts others made in a group's feeds after this account last
  # read each one here (`get_space_feed` with `since: "last_read"`, its read
  # position in `AtMcp.ReadPositions`); a feed never read here counts all
  # it holds. Counted over at most `@new_posts_window` records a feed, so
  # past that it says "at least".
  @new_posts_window 200

  defp new_posts(_session, []), do: %{}

  defp new_posts(session, feeds) do
    did = Session.did(session)
    post = AtMcp.Network.collection(:post)

    counted =
      for feed <- feeds do
        since =
          case AtMcp.ReadPositions.get(did, AtMcp.ReadPositions.key(:space_feed, feed)) do
            {:ok, %{at: at}} -> at
            _ -> nil
          end

        case helper(session, "space.all", %{space: feed, limit: @new_posts_window}) do
          {:ok, %{"records" => records} = got} ->
            n =
              Enum.count(records, fn r ->
                made = get_in(r, ["record", "createdAt"])

                r["collection"] == post and r["repo"] != did and is_binary(made) and
                  (is_nil(since) or AtMcp.ReadPositions.later?(made, since))
              end)

            {n, got["more"] == true, is_nil(since)}

          _ ->
            nil
        end
      end

    case Enum.reject(counted, &is_nil/1) do
      [] ->
        %{}

      known ->
        %{
          new_posts: known |> Enum.map(&elem(&1, 0)) |> Enum.sum(),
          new_posts_at_least: Enum.any?(known, &elem(&1, 1)),
          new_posts_since:
            if(Enum.all?(known, &elem(&1, 2)), do: "never read here", else: "last read here")
        }
    end
  end

  defp names_feed do
    case AtMcp.Network.spaces() do
      %{feed: feed} -> feed
      _ -> nil
    end
  end

  # A group by DID, or by its handle on the group host.
  defp group_arg(_session, "did:" <> _ = did), do: {:ok, did}

  defp group_arg(session, handle) when is_binary(handle) and handle != "" do
    handle = String.trim_leading(handle, "@")

    case AtMcp.ATProto.pds_get(session, "com.atproto.identity.resolveHandle", %{handle: handle}) do
      {:ok, %{did: did}} ->
        {:ok, did}

      {:ok, %{"did" => did}} ->
        {:ok, did}

      _ ->
        # A group's handle that does not resolve may still be the handle its
        # invite to this account names, as get_group_invites shows it.
        case invited_by_handle(session, String.downcase(handle)) do
          {:ok, did} -> {:ok, did}
          _ -> invalid("group", "must be a group's DID or handle; #{handle} does not resolve")
        end
    end
  end

  defp group_arg(_session, _), do: invalid("group", "must be a group's DID or handle")

  defp invited_by_handle(session, handle) do
    with {:ok, body} <- group_host_get(session, "org.atgrp.internal.getActorInvites", %{}) do
      Enum.find_value(Map.get(body, "invites", []), :error, fn invite ->
        group = invite["group"] || %{}

        if is_binary(group["did"]) and is_binary(group["handle"]) and
             String.downcase(group["handle"]) == handle,
           do: {:ok, group["did"]}
      end)
    end
  end

  @doc """
  The groups that invited this account, by DID, as the group host names them
  (`handle`, `display_name`), for the groups among `dids`: what a
  `space-invite` notification shows, where the AppView's view of the group's
  account may have no name. A group no longer inviting it is looked up
  itself, at most five of them.
  """
  def invite_groups(session, dids) when is_list(dids) do
    named =
      case group_host_get(session, "org.atgrp.internal.getActorInvites", %{}) do
        {:ok, body} ->
          for %{"group" => %{"did" => did} = g} <- Map.get(body, "invites", []),
              did in dids,
              into: %{},
              do: {did, %{handle: g["handle"], display_name: g["displayName"]}}

        _ ->
          %{}
      end

    rest =
      for did <- dids |> Enum.uniq() |> Enum.reject(&Map.has_key?(named, &1)) |> Enum.take(5),
          view = group_view(session, did),
          view.handle || view.display_name,
          into: %{},
          do: {did, %{handle: view.handle, display_name: view.display_name}}

    {:ok, Map.merge(named, rest)}
  end

  def leave_group(session, group) do
    with {:ok, group} <- group_arg(session, group) do
      # The confirmation goes first, while this account may still write in
      # the members space; it is put back if the group host refuses to let
      # it leave.
      unconfirmed = unconfirm_membership(session, group)

      case group_host_post(session, "org.atgrp.leaveGroup", %{"group" => group}) do
        {:ok, _} ->
          forget_asked(session, group)
          {:ok, %{left: true, group: group, confirmation_removed: unconfirmed == :ok}}

        error ->
          if unconfirmed == :ok, do: confirm_membership(session, group)
          error
      end
    end
  end

  # --- the town AppView's read grants ---
  #
  # The AppView reads an inbox, or a group's spaces, through a read-only OAuth
  # grant its owner approves: the account for its inbox, a member for a
  # group. Every registerSpace goes through `register_space/2`: when the
  # AppView answers `grantNeeded`, with its request, at_mcp approves it (an
  # inbox with the account's login key; a group with approveAuthorization)
  # and registers again. Before approving, it checks the request is exactly
  # the AppView's client asking for exactly the read scope. Until grants are
  # on in the AppView, it never answers `grantNeeded`, and nothing changes.

  @inbox_grant "atproto space:org.atgrp.inbox?authority=self&action=read"
  # A group's grant is checked as it is asked (getAuthorization): read alone
  # (`atproto space:org.atgrp.members?authority=self&action=read
  # space:town.delve.space.feed?authority=self&action=read`, as the AppView
  # asks it), whatever space types it names.

  @doc "The town AppView's OAuth client_id, whose read grants at_mcp approves."
  def appview_client_id,
    do:
      Application.get_env(:at_mcp, :appview_client_id) ||
        "https://api.delve.town/oauth/client-metadata.json"

  defp register_space(session, %{space: space} = params) do
    case AtMcp.ATProto.register_space(session, params) do
      {:ok, answer} ->
        case grant_needed(answer) do
          nil ->
            {:ok, answer}

          request ->
            # `grantNeeded` is registered all the same: the AppView reads
            # the space with a client's token, or as a member, while the
            # grant is pending. So an approval that fails leaves the
            # registration as it was, and the next one asks again.
            case approve_grant(session, space, request) do
              {:ok, _} ->
                # Registered again, now that the grant is held.
                case AtMcp.ATProto.register_space(
                       session,
                       Map.delete(params, :delegationToken)
                     ) do
                  {:ok, again} -> {:ok, again}
                  {:error, _} -> {:ok, answer}
                end

              {:error, reason} ->
                Logger.info(
                  "approving the town AppView's read grant for #{space} failed; it stays registered meanwhile: #{inspect(reason, limit: 5)}"
                )

                {:ok, answer}
            end
        end

      error ->
        error
    end
  end

  @doc """
  registerSpace's answer for `space`, as the AppView gives it, without
  acting on it: `registered` with no `requestUri` when it holds a grant.
  For checks.
  """
  def registration(session, space) when is_binary(space),
    do: AtMcp.ATProto.register_space(session, %{space: space})

  defp grant_needed(answer) do
    status = answer[:status] || answer["status"]
    uri = answer[:requestUri] || answer["requestUri"] || answer[:request_uri]
    url = answer[:authorizationUrl] || answer["authorizationUrl"] || answer[:authorization_url]

    if status == "grantNeeded" and (is_binary(uri) or is_binary(url)),
      do: %{request_uri: uri, url: url}
  end

  defp approve_grant(session, space, request) do
    did = Session.did(session)

    case space_uri(space) do
      {:space, _} ->
        case String.split(space, "/") do
          ["at:space", ^did, "org.atgrp.inbox", _] ->
            approve_inbox_grant(session, did, request)

          ["at:space", group, "org.atgrp.members", _] ->
            approve_group_grant(session, group, request)

          _ ->
            {:error,
             Failure.new(:refused,
               detail: :no_grant_for_space,
               message: "No grant is approved for #{space}."
             )}
        end

      _ ->
        {:error,
         Failure.new(:refused,
           detail: :no_grant_for_space,
           message: "No grant is approved for #{space}."
         )}
    end
  end

  defp approve_inbox_grant(_session, did, %{url: url}) when is_binary(url) do
    case AtMcp.Spaces.Login.key_file(did) do
      nil ->
        {:error,
         Failure.new(:refused,
           detail: :no_login_key,
           message:
             "The town AppView asks to read this account's invite inbox, and only the account's login key can approve it here; it has none in at_mcp."
         )}

      key_file ->
        Helper.call("oauth.approveFor", %{
          keyFile: key_file,
          account: did,
          authorizationUrl: url,
          clientId: appview_client_id(),
          scope: @inbox_grant
        })
    end
  end

  defp approve_inbox_grant(_session, _did, _request),
    do:
      {:error,
       Failure.new(:refused,
         detail: :no_authorization_url,
         message: "The AppView's request named no authorization URL."
       )}

  # An admin approves the AppView's session as the group, in routine sync:
  # a member without the admin role doesn't, since the session reads the
  # group for everyone in it. getAuthorization first, to check it is the
  # AppView asking for read alone, of the group's members space and feeds,
  # in what it asks and in what the host would grant.
  defp approve_group_grant(session, group, %{request_uri: uri}) when is_binary(uri) do
    with :ok <- group_admin(session, group),
         {:ok, asked} <-
           group_host_get(session, "org.atgrp.internal.getAuthorization", %{"requestUri" => uri}),
         :ok <- appview_asking(session, asked, group),
         {:ok, %{"redirectUrl" => redirect}} <-
           group_host_post(session, "org.atgrp.internal.approveAuthorization", %{
             "requestUri" => uri,
             "group" => group
           }) do
      # The code in it lives 60 seconds: delivered at once.
      _ = Req.get(redirect, redirect: false, retry: false)
      {:ok, %{approved: true, group: group}}
    end
  end

  defp approve_group_grant(_session, _group, _request),
    do:
      {:error,
       Failure.new(:refused,
         detail: :no_request_uri,
         message: "The AppView's request named no request_uri."
       )}

  defp appview_asking(session, asked, group) do
    client = get_in(asked, ["client", "clientId"]) || get_in(asked, ["client", "client_id"])
    requested = for %{"scope" => s} <- asked["requested"] || [], do: s
    # What the host would grant for this group, as it says (per group, as
    # getAuthorization answers): checked as strictly.
    granted =
      scopes(
        Enum.find_value(asked["groups"] || [], asked["granted"], fn g ->
          if g["did"] == group, do: g["granted"] || []
        end)
      )

    if client != appview_client_id() do
      {:error,
       Failure.new(:refused,
         detail: :not_the_appview,
         message:
           "The request to sign in as the group isn't the town AppView's (#{inspect(client)}); nothing was approved."
       )}
    else
      with :ok <- read_only_spaces(session, requested, group, "asks for"),
           do: read_only_spaces(session, granted, group, "would be granted")
    end
  end

  # The space types the AppView's notifications read in a group.
  defp notification_space_types, do: ["org.atgrp.members", names_feed()]

  # Parsed with the protocol's own scope parser, in the helper.
  defp read_only_spaces(_session, [], _group, "would be granted"), do: :ok

  defp read_only_spaces(session, scopes, group, what) do
    case helper(session, "scope.readOnlySpaces", %{
           scope: Enum.join(scopes, " "),
           types: notification_space_types(),
           authority: group
         }) do
      {:ok, %{"ok" => true}} ->
        :ok

      {:ok, %{"refused" => refused}} ->
        why = Enum.map_join(refused, "; ", &"#{&1["scope"]}: #{&1["why"]}")

        {:error,
         Failure.new(:refused,
           detail: :more_than_read,
           message:
             "The town AppView's request #{what} more than reading the group's members and feeds (#{if why == "", do: Enum.join(scopes, " "), else: why}); nothing was approved."
         )}

      {:error, _} = error ->
        error
    end
  end

  # A member's roles as the group host lists them: objects (`[{role:
  # "admin"}]`, group-host 0.6) or, as the Atmosphere Groups proposal lists
  # them, names (`["member", "admin"]`).
  defp role_names(roles) when is_list(roles),
    do:
      for(
        r <- roles,
        name = if(is_map(r), do: r["role"], else: r),
        is_binary(name),
        do: name
      )

  defp role_names(_roles), do: []

  # Whether this account is an admin of `group`, from the group host's list.
  defp group_admin(session, group) do
    me = Session.did(session)

    case group_host_get(session, "org.atgrp.internal.listMembers", %{
           "group" => group,
           "q" => me,
           "limit" => 1
         }) do
      {:ok, %{"members" => found}} when is_list(found) ->
        roles =
          Enum.find_value(found, [], fn m ->
            if get_in(m, ["actor", "did"]) == me, do: role_names(m["roles"])
          end)

        if "admin" in roles,
          do: :ok,
          else:
            {:error,
             Failure.new(:refused,
               detail: :not_an_admin,
               message:
                 "The town AppView asks to read #{group} for its members' notifications; only an admin of the group approves that, and this account isn't one."
             )}

      {:error, _} = error ->
        error

      _ ->
        {:error,
         Failure.new(:indeterminate,
           detail: :roles_unknown,
           message: "The group host didn't say this account's roles in #{group}."
         )}
    end
  end

  # --- an outside app signing in as this account ---
  #
  # An app asks to sign in as the account (its authorize URL, at the
  # account's PDS). The agent sees what it asks, in plain words
  # (`preview_app_sign_in/2`); approving (`approve_app_sign_in/3`) signs with
  # the account's login key exactly what was previewed, and answers the
  # callback URL to hand back to the app. Approving without a preview of the
  # same URL in this session is refused; a preview lasts ten minutes and is
  # spent by its approval or denial.

  def preview_app_sign_in(session, url) do
    did = Session.did(session)

    with {:ok, url} <- app_url(session, url),
         {:ok, asked} <- Helper.call("oauth.previewApp", %{authorizationUrl: url}),
         :ok <- for_this_account(session, asked["loginHint"]) do
      AtMcp.Spaces.Previews.put({:app_sign_in, did, url}, asked)

      {:ok, app_view(asked) |> Map.put(:approved, false) |> Map.put(:previewed, true)}
    end
  end

  def approve_app_sign_in(session, url, deny \\ false) do
    did = Session.did(session)

    with {:ok, url} <- app_url(session, url),
         {:ok, asked} <- take_app_preview(did, url) do
      if deny do
        {:ok,
         app_view(asked)
         |> Map.merge(%{
           approved: false,
           denied: true,
           note: "Not approved: nothing was signed, and the app's request lapses."
         })}
      else
        case AtMcp.Spaces.Login.key_file(did) do
          nil ->
            {:error,
             Failure.new(:refused,
               detail: :no_login_key,
               message:
                 "Only this account's login key can approve an app's sign-in here, and at_mcp has none for it."
             )}

          key_file ->
            with {:ok, %{"callbackUrl" => callback}} <-
                   Helper.call("oauth.approveApp", %{
                     keyFile: key_file,
                     account: asked["loginHint"] || did,
                     authorizationUrl: url,
                     clientId: asked["clientId"],
                     scope: asked["scope"],
                     redirectUri: asked["redirectUri"]
                   }) do
              {:ok,
               app_view(asked)
               |> Map.merge(%{
                 approved: true,
                 callback_url: callback,
                 note:
                   "Approved: the app is signed in as this account with what it asked for (granted). Hand callback_url back to the app to finish its sign-in; the code in it is used once, soon."
               })}
            end
        end
      end
    end
  end

  # The authorize URL, at this account's own PDS: an atproto app signs in
  # where the account's identity lives.
  defp app_url(session, url) when is_binary(url) do
    with %URI{scheme: scheme, host: host} = parsed
         when scheme in ["https", "http"] and is_binary(host) <-
           URI.parse(url),
         own = URI.parse(AtMcp.ATProto.base_url(session) |> String.trim_trailing("/xrpc")),
         true <- {parsed.scheme, parsed.host, parsed.port} == {own.scheme, own.host, own.port} do
      {:ok, url}
    else
      false ->
        invalid(
          "url",
          "must be an authorize URL at this account's own PDS (#{AtMcp.ATProto.base_url(session) |> String.trim_trailing("/xrpc")})"
        )

      _ ->
        invalid("url", "must be an app's authorize URL (https)")
    end
  end

  defp app_url(_session, _url), do: invalid("url", "must be an app's authorize URL")

  defp for_this_account(_session, nil), do: :ok

  defp for_this_account(session, hint) do
    if String.downcase(hint) in [
         Session.did(session),
         String.downcase(Session.handle(session) || "")
       ],
       do: :ok,
       else:
         {:error,
          Failure.new(:refused,
            detail: :another_account,
            message:
              "The app asks to sign in as #{hint}, not as this account; nothing is shown or signed for it."
          )}
  end

  defp take_app_preview(did, url) do
    case AtMcp.Spaces.Previews.take({:app_sign_in, did, url}) do
      {:ok, asked} -> {:ok, asked}
      _ -> not_previewed()
    end
  end

  defp not_previewed,
    do:
      {:error,
       Failure.new(:refused,
         detail: :not_previewed,
         message:
           "This app's sign-in hasn't been previewed in this session: call preview_app_sign_in with the same url first, read what it asks, then approve or deny."
       )}

  defp app_view(asked) do
    scopes = String.split(asked["scope"] || "", " ", trim: true)

    %{
      app: %{client_id: asked["clientId"], name: asked["clientName"], uri: asked["clientUri"]},
      redirect_url: asked["redirectUri"],
      granted: scopes,
      granted_in_words: Enum.map(scopes, &scope_in_words/1)
    }
  end

  @doc "What one OAuth scope lets an app do, in plain words."
  def scope_in_words("atproto"), do: "know which account it is (its DID and handle)"

  def scope_in_words("transition:generic"),
    do:
      "act as this account in full, as an app password does: post, follow, change its profile and settings, and read what it can read (not its email or other accounts)"

  def scope_in_words("transition:email"), do: "read this account's email address"
  def scope_in_words("transition:chat.bsky"), do: "read and send its direct messages"

  def scope_in_words("space:" <> rest) do
    {type, params} = scope_parts(rest)
    actions = Map.get(params, "action", [])
    manages = Map.get(params, "manage", [])

    what =
      cond do
        actions == ["read"] -> "read"
        actions == [] -> "read and write"
        true -> Enum.join(actions, ", ")
      end

    whose =
      case Map.get(params, "authority") do
        ["*"] -> " in any such space it can reach"
        [a] -> " in #{a}'s"
        _ -> " in this account's own"
      end

    "#{what}#{whose} #{type} spaces" <>
      if(manages != [], do: ", and #{Enum.join(manages, " and ")} them", else: "")
  end

  def scope_in_words("rpc:" <> rest) do
    {method, params} = scope_parts(rest)

    "call #{method} as this account" <>
      if(params["aud"], do: " (on #{hd(params["aud"])})", else: "")
  end

  def scope_in_words("repo:" <> rest) do
    {collection, params} = scope_parts(rest)
    actions = Map.get(params, "action", ["create", "update", "delete"])
    "#{Enum.join(actions, ", ")} #{collection} records in this account's repository"
  end

  def scope_in_words("blob:" <> _), do: "upload images and files as this account"
  def scope_in_words("account:" <> rest), do: "change this account's #{rest}"
  def scope_in_words("identity:" <> rest), do: "change this account's identity (#{rest})"
  def scope_in_words("include:" <> set), do: "everything the permission set #{set} grants"

  def scope_in_words(other),
    do: "#{other} (not one at_mcp can describe: read it before approving)"

  defp scope_parts(rest) do
    case String.split(rest, "?", parts: 2) do
      [name] ->
        {name, %{}}

      [name, query] ->
        params =
          query
          |> URI.query_decoder()
          |> Enum.group_by(fn {k, _} -> k end, fn {_, v} -> v end)

        {name, params}
    end
  end

  # --- founding a group, and running it ---
  #
  # The same calls as the web app's "Start a group" and group-host's own
  # client (atgrp): createGroup with the founder's service auth, then, as the
  # group (getGroupAuth tokens), its discussion space; the founder's own
  # confirmation; and the town AppView as a bot member, admitted once it asks.

  @feed_skey "general"
  @bot_role %{"$type" => "org.atgrp.role", "displayName" => "Bot", "bot" => true}
  @handle_label ~r/\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\z/

  @doc """
  Founds a group with this account as its admin: `name` (one label, made
  `<name>.<the host's handle domain>`), `display_name`, and optionally
  `description` and `join_policy` (`open`, `approval`, the default, or
  `invite`). Makes its discussion feed (`town.delve.space.feed`, key
  `general`), which members read and write; confirms the founder's
  membership; and asks the town AppView in as the group's notifications
  member (`add_notifications_member/2`, which runs on its own once the
  group is made, and only where the policy lets it ask: with read grants,
  the AppView reads a group through the grant a member approves, not as a
  member).

  The group is founded with the join policy asked for, and the answer says
  the policy the group host then has (`join_policy`), read back, and
  whether that is the one asked for (`join_policy_confirmed`).
  """
  def create_group(session, %{} = args) do
    policy = args[:join_policy] || "approval"

    with {:ok, handle} <- group_handle(args[:name]),
         {:ok, made} <-
           group_host_post(
             session,
             "org.atgrp.internal.createGroup",
             %{
               "handle" => handle,
               "displayName" => args[:display_name],
               "joinPolicy" => policy
             }
             |> put_present("description", args[:description])
           )
           |> founding_failure(handle) do
      group = made["did"]
      members = made["members"] || members_space(group)
      feed = "at:space/#{group}/#{names_feed()}/#{@feed_skey}"

      # The `bot` role first (no permissions): the feed's policy names it,
      # and the group host refuses a policy naming a role it hasn't got.
      _ =
        as_group(session, group, members, [
          {"com.atproto.space.putRecord",
           %{
             "repo" => group,
             "space" => members,
             "collection" => "org.atgrp.role",
             "rkey" => "bot",
             "record" => @bot_role
           }}
        ])

      feed_made =
        as_group(session, group, feed, [
          {"com.atproto.space.createSpace",
           %{
             "spaceType" => names_feed(),
             "skey" => @feed_skey,
             "policy" => %{
               "$type" => "org.atgrp.policy",
               "grants" => [
                 %{"role" => "member", "read" => true, "write" => true},
                 %{"role" => "bot", "read" => true}
               ]
             }
           }}
        ])

      confirmed = confirm_membership(session, group)
      effective = effective_join_policy(session, group, made["meta"])
      _ = register_space(session, %{space: members})

      # An invite-only group turns away the AppView's request to join, for
      # good: it reads such a group through its grant alone.
      if policy != "invite", do: add_notifications_member_later(session, group, members)

      {:ok,
       %{
         group: %{did: group, handle: handle, display_name: args[:display_name]},
         role: "admin",
         members_space: members,
         feeds: if(match?({:ok, _}, feed_made), do: [feed], else: []),
         feed_note:
           case feed_made do
             {:ok, _} -> nil
             {:error, f} -> "The group was made, but its feed wasn't: #{to_failure(f).message}"
           end,
         confirmed: match?({:ok, _}, confirmed),
         join_policy: effective || policy,
         join_policy_confirmed: effective == policy,
         join_policy_note:
           cond do
             effective == policy ->
               nil

             is_nil(effective) ->
               "The group host didn't say the group's join policy; check it in its console before you rely on #{policy}."

             true ->
               "The group host has the join policy #{effective}, not #{policy}: set it in its console."
           end,
         notifications_member:
           if(policy == "invite",
             do:
               "The town AppView sends the group's members their notifications once a member approves its read grant; an invite-only group doesn't take its request to join.",
             else:
               "The town AppView, which sends the group's members their notifications, is being added as a bot member: it asks to join, and at_mcp admits it in the next two minutes. An admin can remove it at any time; removed, it isn't added back."
           ),
         next:
           "Invite people with invite_to_group (group: #{group}); see who asks to join with get_join_requests."
       }}
    end
  end

  defp group_handle(name) when is_binary(name) do
    name = name |> String.trim() |> String.trim_leading("@") |> String.downcase()

    with {:ok, domain} <- group_domain() do
      cond do
        String.ends_with?(name, domain) and
            Regex.match?(@handle_label, String.replace_suffix(name, domain, "")) ->
          {:ok, name}

        Regex.match?(@handle_label, name) ->
          {:ok, name <> domain}

        true ->
          invalid(
            "name",
            "must be one label of letters, numbers and hyphens (it becomes <name>#{domain})"
          )
      end
    end
  end

  defp group_handle(_name), do: invalid("name", "is required")

  # createGroup's refusals, said as they are, with what to do.
  defp founding_failure({:ok, _} = ok, _handle), do: ok

  defp founding_failure({:error, %Failure{detail: detail} = f}, handle) do
    message =
      case detail do
        "HandleTaken" ->
          "#{handle} is taken: choose another name."

        "InvalidHandle" ->
          "#{handle} isn't a handle this group host gives: use letters, numbers and hyphens."

        "NotAllowed" ->
          "The group host refused (#{f.message}). No group was made."

        "FounderCheckUnavailable" ->
          "The group host couldn't check that you may start groups (#{f.message}). No group was made; try again in a minute."

        "AccountCreationFailed" ->
          "The group host couldn't register the group's identity (#{f.message}). No group was made; try again."

        :transport ->
          "The group host isn't answering (#{f.message}). Try again in a minute."

        _ ->
          nil
      end

    # The host's founder check comes before createGroup: a group was surely
    # not made, so it isn't an unknown outcome.
    kind = if detail == "FounderCheckUnavailable", do: :refused, else: f.kind
    {:error, if(message, do: %{f | message: message, kind: kind}, else: f)}
  end

  defp founding_failure(other, _handle), do: other

  # The town AppView asks to join once its members space is registered; it
  # is admitted as a bot member when its request is there. Runs on its own,
  # for up to two minutes, so founding answers at once.
  defp add_notifications_member_later(session, group, members) do
    Task.Supervisor.start_child(AtMcp.Accounts.TaskSupervisor, fn ->
      Enum.reduce_while(1..40, nil, fn _, _ ->
        case add_notifications_member(session, group, members) do
          {:ok, _} -> {:halt, :ok}
          {:error, _} -> Process.sleep(3_000) && {:cont, nil}
        end
      end)
    end)
  end

  # The join policy the group host has for `group`: from its view of the
  # group, or else the group's own config record. nil when neither says.
  defp effective_join_policy(session, group, meta) do
    from_view =
      case group_host_get(session, "org.atgrp.internal.getGroup", %{"group" => group}) do
        {:ok, %{"group" => %{"joinPolicy" => p}}} when is_binary(p) -> p
        {:ok, %{"joinPolicy" => p}} when is_binary(p) -> p
        _ -> nil
      end

    from_view ||
      case helper(session, "space.records.get", %{
             space: meta || "at:space/#{group}/org.atgrp.meta/self",
             collection: "org.atgrp.config",
             rkey: "self",
             repo: group
           }) do
        {:ok, %{"value" => %{"joinPolicy" => p}}} when is_binary(p) -> p
        _ -> nil
      end
  end

  @doc false
  # Admits the town AppView as a bot member of `group` if it has asked to
  # join: a `bot` role (no permissions), then its membership, written as the
  # group in its members space.
  def add_notifications_member(session, group, members \\ nil) do
    reader = AtMcp.Network.appview_service() |> String.split("#") |> hd()
    members = members || members_space(group)

    with {:ok, %{"requests" => requests}} <-
           group_host_get(session, "org.atgrp.listJoinRequests", %{"group" => group}),
         true <-
           Enum.any?(requests, &((&1["member"] || get_in(&1, ["actor", "did"])) == reader)) ||
             {:error, :not_asked} do
      now = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

      as_group(session, group, members, [
        {"com.atproto.space.putRecord",
         %{
           "repo" => group,
           "space" => members,
           "collection" => "org.atgrp.role",
           "rkey" => "bot",
           "record" => @bot_role
         }},
        {"com.atproto.space.putRecord",
         %{
           "repo" => group,
           "space" => members,
           "collection" => "org.atgrp.membership",
           "rkey" => reader,
           "record" => %{
             "$type" => "org.atgrp.membership",
             "roles" => ["member", "bot"],
             "createdAt" => now
           }
         }}
      ])
    end
  end

  @doc """
  Invites `who` (a handle or DID) to `group`: an `org.atgrp.invite` written
  as the group into their invite inbox, with `message` if given. Needs a role
  in the group that may invite (an admin's does).
  """
  def invite_to_group(session, group, who, message \\ nil) do
    with {:ok, group} <- group_arg(session, group),
         {:ok, person} <- account_arg(session, who) do
      inbox = "at:space/#{person}/org.atgrp.inbox/self"
      now = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

      record =
        %{"$type" => "org.atgrp.invite", "createdAt" => now} |> put_present("message", message)

      case as_group(session, group, inbox, [
             {"com.atproto.space.createRecord",
              %{
                "repo" => group,
                "space" => inbox,
                "collection" => "org.atgrp.invite",
                "record" => record
              }}
           ]) do
        {:ok, %{"results" => [written | _]}} ->
          {:ok, %{group: group, invited: person, invite: written["uri"]}}

        {:ok, _} ->
          {:ok, %{group: group, invited: person}}

        {:error, %Failure{detail: detail} = f}
        when detail in ["SpaceNotFound", "InboxNotFound"] ->
          {:error,
           %{
             f
             | message:
                 "#{who} has no invite inbox yet, so no group can invite them: it's made when they first open groups in their app, or when at_mcp runs for them. Nothing was sent."
           }}

        error ->
          error
      end
    end
  end

  @doc "The requests to join `group` waiting for an admin."
  def get_join_requests(session, group) do
    with {:ok, group} <- group_arg(session, group),
         {:ok, body} <- group_host_get(session, "org.atgrp.listJoinRequests", %{"group" => group}) do
      {:ok,
       %{group: group, requests: named(session, body["requests"] || []), cursor: body["cursor"]}}
    end
  end

  # Who asks, by handle and display name: the group host may send the
  # member's DID alone, so a request without a handle takes the asker's
  # public profile (one read for them all).
  defp named(session, requests) do
    missing =
      for %{"member" => did} = q <- requests,
          is_binary(did),
          not (is_map(q["actor"]) and is_binary(q["actor"]["handle"])),
          uniq: true,
          do: did

    profiles = author_profiles(session, missing)

    Enum.map(requests, fn q ->
      case profiles[q["member"]] do
        %{} = p ->
          actor = if is_map(q["actor"]), do: q["actor"], else: %{}
          given = Map.reject(actor, fn {_, v} -> is_nil(v) end)
          Map.put(q, "actor", Map.merge(Map.take(p, ["did", "handle", "displayName"]), given))

        nil ->
          q
      end
    end)
  end

  @doc "Admits `member`, who asked to join `group`, as a member."
  def approve_join_request(session, group, member) do
    with {:ok, group} <- group_arg(session, group),
         {:ok, member} <- account_arg(session, member) do
      members = members_space(group)
      now = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

      with {:ok, _} <-
             as_group(session, group, members, [
               {"com.atproto.space.putRecord",
                %{
                  "repo" => group,
                  "space" => members,
                  "collection" => "org.atgrp.membership",
                  "rkey" => member,
                  "record" => %{
                    "$type" => "org.atgrp.membership",
                    "roles" => ["member"],
                    "createdAt" => now
                  }
                }}
             ]),
           do: {:ok, %{group: group, member: member, admitted: true}}
    end
  end

  @doc """
  Puts `member` out of `group`: their membership, deleted as the group in
  its members space, as group-host's own console does (`member_eject`).
  """
  def remove_group_member(session, group, member) do
    with {:ok, group} <- group_arg(session, group),
         {:ok, member} <- account_arg(session, member),
         :ok <- not_self(session, member) do
      members = members_space(group)

      with {:ok, _} <-
             as_group(session, group, members, [
               {"com.atproto.space.deleteRecord",
                %{
                  "repo" => group,
                  "space" => members,
                  "collection" => "org.atgrp.membership",
                  "rkey" => member
                }}
             ]),
           do: {:ok, %{group: group, member: member, removed: true}}
    end
  end

  @doc "Turns down `member`'s request to join `group`."
  def deny_join_request(session, group, member) do
    with {:ok, group} <- group_arg(session, group),
         {:ok, member} <- account_arg(session, member),
         {:ok, _} <-
           group_host_post(session, "org.atgrp.denyJoinRequest", %{
             "group" => group,
             "member" => member
           }),
         do: {:ok, %{group: group, member: member, denied: true}}
  end

  # An account named by its DID or handle, as the PDS resolves it.
  defp account_arg(_session, "did:" <> _ = did), do: {:ok, did}

  defp account_arg(session, handle) when is_binary(handle) and handle != "" do
    handle = String.trim_leading(handle, "@")

    case AtMcp.ATProto.pds_get(session, "com.atproto.identity.resolveHandle", %{handle: handle}) do
      {:ok, %{did: did}} -> {:ok, did}
      {:ok, %{"did" => did}} -> {:ok, did}
      _ -> invalid("who", "must be an account's DID or handle; #{handle} does not resolve")
    end
  end

  defp account_arg(_session, _), do: invalid("who", "must be an account's DID or handle")

  # --- a member's confirmation ---
  #
  # Membership is two-sided (Atmosphere Groups, "Roles & Access"): the group
  # writes `membership`, and the member writes `org.atgrp.confirmation`
  # (rkey `self`) in the group's members space, which the roster counts.

  @confirmation "org.atgrp.confirmation"

  defp members_space(group), do: "at:space/#{group}/org.atgrp.members/self"

  @doc """
  Writes this account's confirmation of its membership in `group`
  (`org.atgrp.confirmation`, rkey `self`, in the group's members space).
  Writing it again only renews its time.
  """
  def confirm_membership(session, group) do
    now = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

    with {:ok, _} <-
           helper(session, "space.records.put", %{
             space: members_space(group),
             collection: @confirmation,
             rkey: "self",
             record: %{"createdAt" => now}
           }),
         do: {:ok, %{group: group, confirmed: true}}
  end

  @doc """
  Whether this account's confirmation is in `group`'s members space:
  `{:ok, true | false}`, or an error when it can't be read.
  """
  def membership_confirmed?(session, group) do
    case helper(session, "space.records.get", %{
           space: members_space(group),
           collection: @confirmation,
           rkey: "self",
           repo: Session.did(session)
         }) do
      {:ok, _} ->
        {:ok, true}

      {:error, %Failure{detail: detail}} when detail in ["RecordNotFound", "NotFound"] ->
        {:ok, false}

      error ->
        error
    end
  end

  @doc """
  For InboxTokens' group pass: confirms this account's membership in
  `group` if its confirmation isn't there and this account asked to join
  (a `requestJoin` or invite acceptance it made, kept in its state, the
  case of asking and being admitted later). A group can make someone a
  member who never asked; that membership stays unconfirmed, for the
  account to confirm (`confirm_group/2`) or leave.
  """
  def ensure_confirmed(session, group) do
    case membership_confirmed?(session, group) do
      {:ok, true} ->
        forget_asked(session, group)
        {:ok, %{group: group, confirmed: true}}

      _ ->
        if asked?(session, group) do
          with {:ok, done} <- confirm_membership(session, group) do
            forget_asked(session, group)
            {:ok, done}
          end
        else
          {:ok, %{group: group, confirmed: false}}
        end
    end
  end

  @doc """
  `confirm_group_membership`: this account confirms its membership in a
  group it was added to, so the group's roster lists it.
  """
  def confirm_group(session, group) do
    with {:ok, group} <- group_arg(session, group),
         {:ok, _} <- confirm_membership(session, group) do
      forget_asked(session, group)
      {:ok, %{group: group, confirmed: true}}
    end
  end

  # The groups this account asked to join, kept in its state folder until
  # its confirmation is written: `group-requests.json`, by DID.
  @doc false
  def asked_path, do: Path.join(AtMcp.Inbound.Store.default_dir(), "group-requests.json")

  defp asked(contents) do
    with contents when is_binary(contents) <- contents,
         {:ok, %{"accounts" => %{} = accounts}} <- Jason.decode(contents) do
      accounts
    else
      _ -> %{}
    end
  end

  defp asked?(session, group) do
    case AtMcp.PrivateFile.read(asked_path()) do
      {:ok, contents} -> group in List.wrap(asked(contents)[Session.did(session)])
      _ -> false
    end
  end

  defp remember_asked(session, group), do: change_asked(session, &Enum.uniq([group | &1]))
  defp forget_asked(session, group), do: change_asked(session, &List.delete(&1, group))

  defp change_asked(session, change) do
    did = Session.did(session)

    AtMcp.PrivateFile.mutate(asked_path(), fn current ->
      accounts = asked(if current == :missing, do: nil, else: current)
      groups = change.(List.wrap(accounts[did]))

      accounts =
        if groups == [], do: Map.delete(accounts, did), else: Map.put(accounts, did, groups)

      {:ok, Jason.encode!(%{"version" => 1, "accounts" => accounts}), :ok}
    end)

    :ok
  end

  defp unconfirm_membership(session, group) do
    case helper(session, "space.records.delete", %{
           space: members_space(group),
           collection: @confirmation,
           rkey: "self"
         }) do
      {:ok, _} -> :ok
      _ -> :failed
    end
  end

  defp confirmed({:ok, _}), do: %{"confirmed" => true}

  defp confirmed({:error, failure}),
    do: %{
      "confirmed" => false,
      "confirmation_note" =>
        "Joined, but this account's confirmation could not be written in the group's members space (#{to_failure(failure).message || "refused"}), so the group's roster may not list it yet; at_mcp tries again when it next starts."
    }

  # --- posts in a space (a group's feed) ---
  #
  # The public post tools take a space: `post` with `space`, and `reply`,
  # `like`, `repost` and `get_thread` given a post's `at:space/` URI. A post
  # in a space is a town post (`AtMcp.Network.collection(:post)`) in the
  # writer's own repo in that space, read by the space's members only.

  @doc """
  Splits an `at:space/` URI: a space (`{:space, uri}`), or a record in one
  (`{:record, space, repo, collection, rkey}`).
  """
  def space_uri("at:space/" <> rest) do
    case String.split(rest, "/") do
      [a, t, k] when a != "" and t != "" and k != "" ->
        {:space, "at:space/#{a}/#{t}/#{k}"}

      [a, t, k, repo, collection, rkey] when rkey != "" ->
        {:record, "at:space/#{a}/#{t}/#{k}", repo, collection, rkey}

      _ ->
        :error
    end
  end

  def space_uri(_), do: :error

  @doc "The checks of a space post that need no session (made before a slot is reserved)."
  def check(:post, [space, text, opts]) do
    with {:space, _} <- space_uri(space),
         :ok <- post_text(text),
         :ok <- space_post_options(opts) do
      :ok
    else
      # A record in a space, not a space: say which, and what to do with it.
      {:record, _space, group, "org.atgrp.invite", _rkey} ->
        invalid(
          "space",
          "is a group invite, a record in your inbox, not a space to post in: join the group first (accept_group_invite with group #{group}), then post in its feed"
        )

      {:record, record_space, _repo, _collection, _rkey} ->
        invalid(
          "space",
          "is a record in a space, not a space: post in #{record_space}, or reply to the record with reply"
        )

      {:error, _} = error ->
        error

      _ ->
        invalid("space", "must be an at:space/<authority>/<type>/<key> URI")
    end
  end

  def check(_op, _args), do: :ok

  # What a space post can't carry yet. Each needs its own work in a space:
  # images and link cards are blobs, a quote is a record embed, and gates are
  # records of their own.
  @space_unsupported [:images, :link, :quote, :quotes, :reply_rule, :labels]

  defp space_post_options(opts) do
    case Enum.filter(@space_unsupported, &Keyword.has_key?(opts, &1)) do
      [] ->
        :ok

      given ->
        invalid(
          Enum.map_join(given, ", ", &to_string/1),
          "can't go on a post in a space yet; post the text alone, or post publicly"
        )
    end
  end

  @doc """
  A post (or with `reply_to`, a reply) in a space, built as a public post
  is (rich text and its facets, languages), before any slot is reserved.
  """
  def prepare_space_post(session, space, text, opts) do
    {rich, unresolved} =
      if Keyword.get(opts, :facets) == :none,
        do: {%{text: text, facets: []}, []},
        else: AtMcp.RichText.build(text, session)

    with {:ok, reply, parent_langs} <- space_reply_ref(session, Keyword.get(opts, :reply_to)) do
      record =
        AtMcp.ATProto.post_record(
          text: rich.text,
          facets: rich.facets,
          langs: Keyword.get(opts, :langs) || parent_langs,
          reply: reply
        )

      {:ok,
       %{
         space: space,
         record: record,
         text: text,
         unresolved: unresolved,
         reply: Keyword.get(opts, :reply_to)
       }}
    end
  end

  def write_space_post(session, %{space: space, record: record, text: text} = prepared) do
    with {:ok, written} <-
           given(session, "space.records.create", %{
             space: space,
             collection: record["$type"],
             record: Map.delete(record, "$type")
           }) do
      summary = %{uri: written["uri"], cid: written["cid"], text: text, space: space}
      summary = if prepared.reply, do: Map.put(summary, :reply_to, prepared.reply), else: summary

      {:ok,
       case prepared.unresolved do
         [] ->
           summary

         handles ->
           Map.put(summary, :warnings, [
             "Not mentioned (no such account): " <> Enum.join(handles, ", ")
           ])
       end}
    end
  end

  # A reply's strong references: its parent, and the parent's root (or the
  # parent, when it is the root). Both live in the parent's space.
  defp space_reply_ref(_session, nil), do: {:ok, nil, nil}

  defp space_reply_ref(session, parent_uri) do
    with {:ok, parent} <- space_record(session, parent_uri) do
      parent_ref = %{uri: parent_uri, cid: parent["cid"]}
      value = parent["value"] || %{}

      root_ref =
        case get_in(value, ["reply", "root"]) do
          %{"uri" => uri, "cid" => cid} -> %{uri: uri, cid: cid}
          _ -> parent_ref
        end

      langs = if is_list(value["langs"]) and value["langs"] != [], do: value["langs"]
      {:ok, %{root: root_ref, parent: parent_ref}, langs}
    end
  end

  defp space_record(session, uri) do
    case space_uri(uri) do
      {:record, space, repo, collection, rkey} ->
        given(session, "space.records.get", %{
          space: space,
          collection: collection,
          rkey: rkey,
          repo: repo
        })

      _ ->
        invalid(
          "uri",
          "must be a record in a space: at:space/<authority>/<type>/<key>/<repo>/<collection>/<rkey>"
        )
    end
  end

  @doc "A like or a repost (`kind`) of a post in a space, written in the same space."
  def space_subject(session, kind, uri, cid) when kind in [:like, :repost] do
    with {:record, space, _repo, _collection, _rkey} <- space_uri(uri) || :error,
         {:ok, cid} <- subject_cid(session, uri, cid) do
      record =
        if kind == :like,
          do: AtMcp.ATProto.like_record(subject: %{uri: uri, cid: cid}),
          else: AtMcp.ATProto.repost_record(subject: %{uri: uri, cid: cid})

      with {:ok, written} <-
             given(session, "space.records.create", %{
               space: space,
               collection: record["$type"],
               record: Map.delete(record, "$type")
             }) do
        {:ok,
         %{
           uri: written["uri"],
           cid: written["cid"],
           subject_uri: uri,
           subject_cid: cid,
           action: kind
         }}
      end
    else
      :error -> invalid("uri", "must be a post in a space")
      error -> error
    end
  end

  defp subject_cid(_session, _uri, cid) when is_binary(cid) and cid != "", do: {:ok, cid}

  defp subject_cid(session, uri, _none) do
    with {:ok, got} <- space_record(session, uri), do: {:ok, got["cid"]}
  end

  @doc """
  A space's posts, newest first, each with its author's public profile and
  the likes, reposts and replies made in the space: the page `get_author_feed`
  and the other feeds answer. Every record read is checked against its
  server's signature (`space.all`).
  """
  def space_feed(session, space, limit) do
    with {:space, space} <- space_uri(space) || :error,
         {:ok, all} <- given(session, "space.all", %{space: space, limit: 1000}) do
      records = all["records"] || []
      posts = space_posts(records)
      views = post_views(session, posts, records)

      items =
        views
        |> Enum.sort_by(&(&1["indexedAt"] || ""), :desc)
        |> Enum.take(limit || AtMcp.Effects.page_limits().default)
        |> Enum.map(&AtMcp.Effects.ProtoRune.post_view/1)

      {:ok, %{count: length(items), items: items, cursor: nil}}
    else
      :error -> invalid("space", "must be an at:space/<authority>/<type>/<key> URI")
      error -> error
    end
  end

  @doc """
  The thread around a post in a space, as `get_thread` answers one: its
  parents up to the root, the post, and the replies below it, from the
  space's own records.
  """
  def space_thread(session, uri) do
    with {:record, space, _, _, _} <- space_uri(uri) || :error,
         {:ok, all} <- given(session, "space.all", %{space: space, limit: 1000}) do
      records = all["records"] || []
      views = post_views(session, space_posts(records), records)
      by_uri = Map.new(views, &{&1["uri"], &1})

      case by_uri[uri] do
        nil ->
          {:error,
           Failure.new(:refused, detail: :not_found, message: "No post at #{uri} in its space.")}

        anchor ->
          parents = ancestors(anchor, by_uri, [])
          children = Enum.group_by(views, &get_in(&1, ["record", "reply", "parent", "uri"]))

          flat =
            Enum.with_index(Enum.reverse(parents), fn p, i -> item(p, i - length(parents)) end) ++
              [item(anchor, 0)] ++ descendants(anchor["uri"], children, 1)

          {:ok,
           %{thread: flat}
           |> AtMcp.Effects.ProtoRune.summarize_thread()
           |> Map.put(:context, %{space: space})}
      end
    else
      :error -> invalid("uri", "must be a post in a space")
      error -> error
    end
  end

  defp item(view, depth),
    do: %{"uri" => view["uri"], "depth" => depth, "value" => %{"post" => view}}

  defp ancestors(view, by_uri, acc) do
    case by_uri[get_in(view, ["record", "reply", "parent", "uri"])] do
      nil -> acc
      parent -> if length(acc) > 50, do: acc, else: ancestors(parent, by_uri, [parent | acc])
    end
  end

  defp descendants(uri, children, depth) when depth <= 10 do
    (children[uri] || [])
    |> Enum.sort_by(&(&1["indexedAt"] || ""))
    |> Enum.flat_map(&[item(&1, depth) | descendants(&1["uri"], children, depth + 1)])
  end

  defp descendants(_uri, _children, _depth), do: []

  defp space_posts(records) do
    post = AtMcp.Network.collection(:post)

    Enum.filter(
      records,
      &(&1["collection"] == post and &1["valid"] == true and is_binary(&1["uri"]))
    )
  end

  # Posts as an AppView's postView, so the summaries and readings of public
  # posts serve: the author's public profile (one read for every author),
  # the record, and counts from the likes, reposts and replies in the space.
  defp post_views(session, posts, records) do
    profiles = author_profiles(session, posts |> Enum.map(& &1["repo"]) |> Enum.uniq())
    like = AtMcp.Network.collection(:like)
    repost = AtMcp.Network.collection(:repost)

    count = fn collection, path ->
      records
      |> Enum.filter(&(&1["collection"] == collection))
      |> Enum.frequencies_by(&get_in(&1, ["record" | path]))
    end

    likes = count.(like, ["subject", "uri"])
    reposts = count.(repost, ["subject", "uri"])
    replies = count.(AtMcp.Network.collection(:post), ["reply", "parent", "uri"])

    for r <- posts do
      record = r["record"] || %{}

      %{
        "uri" => r["uri"],
        "cid" => r["cid"],
        "author" => profiles[r["repo"]] || %{"did" => r["repo"], "handle" => "handle.invalid"},
        "record" => Map.put_new(record, "$type", AtMcp.Network.collection(:post)),
        "indexedAt" => record["createdAt"],
        "likeCount" => Map.get(likes, r["uri"], 0),
        "repostCount" => Map.get(reposts, r["uri"], 0),
        "replyCount" => Map.get(replies, r["uri"], 0),
        "quoteCount" => 0
      }
    end
  end

  defp author_profiles(_session, []), do: %{}

  defp author_profiles(session, dids) do
    dids
    |> Enum.chunk_every(25)
    |> Enum.flat_map(fn chunk ->
      case AtMcp.ATProto.get_profiles(session, chunk) do
        {:ok, %{profiles: profiles}} -> profiles
        {:ok, %{"profiles" => profiles}} -> profiles
        _ -> []
      end
    end)
    |> Map.new(fn p ->
      p = stringify_keys(p)
      {p["did"], p}
    end)
  end

  defp stringify_keys(%{} = m),
    do: Map.new(m, fn {k, v} -> {camel(to_string(k)), stringify_keys(v)} end)

  defp stringify_keys(l) when is_list(l), do: Enum.map(l, &stringify_keys/1)
  defp stringify_keys(v), do: v

  defp camel(key) do
    case String.split(key, "_") do
      [one] -> one
      [first | rest] -> first <> Enum.map_join(rest, &String.capitalize/1)
    end
  end

  @doc """
  The consent screen for an app's request to sign in as a group: which app,
  which group, and what it would get there (`granted`) and not (`withheld`).
  Approves nothing. `approve_group_app` approves only a request this account
  has previewed, for the group the preview showed.
  """
  def preview_group_app(session, request_uri, group) do
    with :ok <- text_arg(request_uri, "request_uri"),
         {:ok, facts} <- app_request(session, request_uri, group) do
      AtMcp.Spaces.Previews.put({:group_app, Session.did(session), request_uri}, facts.group)

      {:ok, Map.merge(facts, %{approved: false, previewed: true})}
    end
  end

  defp app_request(session, request_uri, group) do
    with {:ok, preview} <-
           group_host_get(session, "org.atgrp.internal.getAuthorization", %{
             "requestUri" => request_uri
           }),
         {:ok, offered} <- offered_group(preview, group) do
      client = preview["client"] || %{}

      {:ok,
       %{
         app: %{client_id: client["clientId"], name: client["name"], uri: client["uri"]},
         group: offered["did"],
         granted: scopes(offered["granted"]),
         withheld: scopes(offered["withheld"]),
         request: preview
       }}
    end
  end

  # Approving takes a preview of the same request first, for the same group,
  # in the last ten minutes, and spends it: an approval can't be taken back
  # from here, only by the group's admins.

  defp previewed(session, request_uri) do
    case AtMcp.Spaces.Previews.peek({:group_app, Session.did(session), request_uri}) do
      {:ok, shown} ->
        {:ok, shown}

      :expired ->
        not_previewed("The preview is too old: preview the request again first.")

      :none ->
        not_previewed(
          "Look at the request first with preview_group_app (which app, and what it would get)."
        )
    end
  end

  defp same_as_previewed(_offered, nil), do: :ok
  defp same_as_previewed(%{"did" => did}, did), do: :ok

  defp same_as_previewed(%{"did" => did}, shown),
    do:
      not_previewed(
        "The preview was for #{shown}, not #{did}: preview the request for that group first."
      )

  defp not_previewed(why),
    do:
      {:error,
       Failure.new(:refused, detail: :not_previewed, message: why <> " Nothing was approved.")}

  @doc """
  An app's request to sign in as a group, once previewed
  (`preview_group_app/3`): approved with what this member's roles allow, or
  with `approve?` false turned away (the tool's `deny`, as
  Welcome Mat's `deny=1`). Answers which app it is, which group, and what it
  gets there (`granted`) and doesn't (`withheld`), from the host's preview,
  and the redirect URL to hand back to the app. Each answer is logged with
  the same facts.

  Nothing is approved for a group the preview does not offer this member:
  the approval is exactly the request that was shown.
  """
  def approve_group_app(session, request_uri, group, approve?) do
    with :ok <- text_arg(request_uri, "request_uri"),
         {:ok, shown} <- if(approve?, do: previewed(session, request_uri), else: {:ok, nil}),
         {:ok, preview} <-
           group_host_get(session, "org.atgrp.internal.getAuthorization", %{
             "requestUri" => request_uri
           }),
         {:ok, offered} <- offered_group(preview, group || shown),
         :ok <- same_as_previewed(offered, shown) do
      AtMcp.Spaces.Previews.take({:group_app, Session.did(session), request_uri})
      group = offered["did"]
      client = preview["client"] || %{}

      facts = %{
        app: %{client_id: client["clientId"], name: client["name"], uri: client["uri"]},
        group: group,
        granted: scopes(offered["granted"]),
        withheld: scopes(offered["withheld"]),
        request: preview
      }

      if approve? do
        with {:ok, approved} <-
               group_host_post(session, "org.atgrp.internal.approveAuthorization", %{
                 "requestUri" => request_uri,
                 "group" => group
               }) do
          Logger.info(
            "#{Session.did(session)} approved app #{facts.app.client_id} for group #{group}: " <>
              "granted #{Enum.join(facts.granted, " ")}" <>
              if(facts.withheld == [],
                do: "",
                else: "; withheld #{Enum.join(facts.withheld, " ")}"
              )
          )

          {:ok, Map.merge(facts, %{approved: true, redirect_url: approved["redirectUrl"]})}
        end
      else
        with {:ok, declined} <-
               group_host_post(session, "org.atgrp.internal.declineAuthorization", %{
                 "requestUri" => request_uri
               }) do
          Logger.info(
            "#{Session.did(session)} turned away app #{facts.app.client_id} for group #{group}"
          )

          {:ok, Map.merge(facts, %{approved: false, redirect_url: declined["redirectUrl"]})}
        end
      end
    end
  end

  # The group the approval is for: the one named (DID or handle), else the
  # one the app asked for (its login hint), else the only one offered. Only a
  # group the request offers this account is ever approved.
  defp offered_group(preview, group) do
    groups = preview["groups"] || []
    wanted = group || preview["loginHint"]

    found =
      cond do
        is_binary(wanted) ->
          name = wanted |> String.trim_leading("@") |> String.downcase()
          Enum.find(groups, &(&1["did"] == wanted or String.downcase(&1["handle"] || "") == name))

        length(groups) == 1 ->
          hd(groups)

        true ->
          :ambiguous
      end

    case found do
      :ambiguous ->
        {:error,
         Failure.new(:refused,
           detail: :group_needed,
           message:
             "The app's request can sign in as more than one of this account's groups: give group (get_my_groups lists them). Nothing was approved."
         )}

      nil ->
        {:error,
         Failure.new(:refused,
           detail: :group_not_offered,
           message:
             "The app's request does not offer that group to this account. Leave group out to see the group it asks for. Nothing was approved."
         )}

      offered ->
        {:ok, offered}
    end
  end

  defp scopes(list) when is_list(list),
    do: for(%{"scope" => scope} <- list, do: scope)

  defp scopes(_), do: []

  defp post_text(text) when is_binary(text) do
    %{graphemes: max} = AtMcp.Network.post_limits()

    cond do
      String.trim(text) == "" -> invalid("text", "may not be empty")
      String.length(text) > max -> invalid("text", "may be at most #{max} characters")
      true -> :ok
    end
  end

  defp post_text(_), do: invalid("text", "is required")

  # --- the group host ---

  @doc false
  # The configured group host's URL and DID (from its describeServer).
  def group_host do
    case Application.get_env(:at_mcp, :group_host) do
      nil ->
        {:error,
         Failure.new(:refused,
           detail: :no_group_host,
           message: "No group host is configured for this installation (AT_MCP_GROUP_HOST)."
         )}

      url ->
        url = String.trim_trailing(url, "/")

        case :persistent_term.get({__MODULE__, :group_host, url}, nil) do
          nil ->
            with {:ok, %{"did" => did} = described} <-
                   http(:get, url <> "/xrpc/com.atproto.server.describeServer", nil, %{}) do
              :persistent_term.put({__MODULE__, :group_host, url}, {url, did})

              :persistent_term.put(
                {__MODULE__, :group_domains, url},
                described["availableUserDomains"]
              )

              {:ok, {url, did}}
            end

          known ->
            {:ok, known}
        end
    end
  end

  defp group_host_get(session, method, params) do
    with {:ok, {url, did}} <- group_host(),
         {:ok, token} <- AtMcp.ATProto.ServiceAuth.issue_for(session, did, method) do
      http(:get, "#{url}/xrpc/#{method}", token, params)
    end
  end

  # The handle domain the group host gives new groups (its describeServer's
  # first `availableUserDomains`), as ".groups.example".
  defp group_domain do
    with {:ok, {url, _did}} <- group_host() do
      case :persistent_term.get({__MODULE__, :group_domains, url}, nil) do
        [domain | _] when is_binary(domain) ->
          {:ok, if(String.starts_with?(domain, "."), do: domain, else: "." <> domain)}

        _ ->
          {:error,
           Failure.new(:refused,
             detail: :no_group_domain,
             message: "The group host names no handle domain for new groups."
           )}
      end
    end
  end

  # Calls as `group` with a group token for `space` (its host's
  # getGroupAuth, bound to a DPoP key of its own, in the helper): what this
  # account's roles let it write there, as the group.
  defp as_group(session, group, space, calls) do
    with {:ok, {url, did}} <- group_host(),
         {:ok, service} <-
           AtMcp.ATProto.ServiceAuth.issue_for(session, did, "org.atgrp.internal.getGroupAuth") do
      Helper.call("group.act", %{
        hostUrl: url,
        serviceToken: service,
        group: group,
        space: space,
        calls: for({method, body} <- calls, do: %{method: method, body: body})
      })
    end
  end

  defp group_host_post(session, method, body) do
    with {:ok, {url, did}} <- group_host(),
         {:ok, token} <- AtMcp.ATProto.ServiceAuth.issue_for(session, did, method) do
      http(:post, "#{url}/xrpc/#{method}", token, body)
    end
  end

  # --- principal ---

  @doc """
  Creates an agent account with one of this account's invites: a new login
  key for it (kept in the installation's key folder, under the agent's DID,
  and proved to the PDS by signing the request), this account's rotation key
  on top of the agent's PLC rotation keys, and `agent-of` this account. Then
  writes the endorsement that completes the ident.link pair.

  The rotation key is the public half alone, a `did:key` the operator gives
  (`rotation_key` in the accounts file, `at_mcp-accounts rotation-key`).
  Its private half stays offline with whoever runs the principal: holding
  it, they can take the agent's identity back from anywhere. AtMcp never
  makes or holds it.
  """
  def create_agent(session, handle, invite_code) do
    with {:ok, names} <- names(),
         :ok <- if(is_nil(handle), do: :ok, else: handle_arg(handle)),
         :ok <- text_arg(invite_code, "invite_code"),
         {:ok, rotation_key} <- principal_rotation_key(Session.did(session)),
         {:ok, pds_did} <- pds_did(session),
         pending =
           Path.join(
             keys_dir(),
             "pending-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}.json"
           ),
         {:ok, login} <- Helper.call("key.generate", %{keyFile: pending}),
         {:ok, %{"proof" => proof}} <-
           Helper.call("key.prove", %{
             keyFile: pending,
             iss: Session.did(session),
             # The handle asked for, or, when the PDS is to pick one, the
             # login key itself.
             sub: if(handle, do: String.downcase(handle), else: login["didKey"]),
             aud: pds_did,
             lxm: "#{names.agent}.createAgent"
           }) do
      case agent_call(
             session,
             names,
             "createAgent",
             %{
               "inviteCode" => invite_code,
               "loginKey" => login["didKey"],
               "loginKeyProof" => proof,
               # recoveryKey, as the PDS names it now; rotationKey, as it did.
               "recoveryKey" => rotation_key,
               "rotationKey" => rotation_key
             }
             |> put_present("handle", handle)
           ) do
        {:ok, %{"did" => did} = created} ->
          File.rename!(pending, key_path(did))

          # The agent's password, given once, isn't kept: when this
          # principal must sign in as the agent, it gets a fresh one
          # (`signed_in_as_agent/2`).
          # The PDS writes the principal's endorsement when it hosts the
          # principal (endorsed); otherwise this account writes it.
          endorsement =
            if created["endorsed"] == true do
              %{uri: created["endorsement"], written_by: "the PDS"}
            else
              case endorse_agent(session, did) do
                {:ok, written} -> written
                {:error, failure} -> %{error: failure.message}
              end
            end

          state = make_agent_space(session, did)
          # Where its notes go, should it run on this installation.
          AtMcp.Spaces.StateHome.bind(did, Session.did(session))

          {:ok,
           %{
             did: did,
             handle: created["handle"] || handle,
             login_key: login["didKey"],
             rotation_key: rotation_key,
             endorsement: endorsement,
             agent_space: state,
             password:
               "not kept: at_mcp gets a fresh one from the PDS when this account must sign in as the agent",
             next:
               "The agent logs in with its own key, which at_mcp keeps for it. To run it on this installation, its operator runs: at_mcp-accounts add-agent NAME --did #{did}, then at_mcp-accounts reload, then at_mcp-accounts connection NAME for the agent's MCP client."
           }}

        error ->
          File.rm(pending)
          error
      end
    end
  end

  # --- an agent's state: one space, its principal's ---
  #
  # Each agent's state lives in `town.delve.space.agent`, with its principal
  # as authority and the agent's DID as key; principal and agent are both
  # read/write members. The principal's at_mcp makes it after createAgent.
  # It holds the agent's notes (and any records of its own). An account with
  # no principal has no state space, and so no notes.

  @doc "The URI of `agent`'s state space under `principal`."
  def agent_space_uri(principal, agent), do: "at:space/#{principal}/#{@agent_space}/#{agent}"

  defp make_agent_space(session, agent) do
    principal = Session.did(session)

    case helper(session, "space.create", %{
           type: @agent_space,
           skey: agent,
           policy: "member",
           members: [
             %{did: principal, read: true, write: true},
             %{did: agent, read: true, write: true}
           ]
         }) do
      {:ok, %{"space" => space}} ->
        space

      {:error, %Failure{detail: "SpaceAlreadyExists"}} ->
        agent_space_uri(principal, agent)

      {:error, failure} ->
        %{error: "The agent's state space wasn't made: #{to_failure(failure).message}"}
    end
  end

  @doc """
  Gives one of this account's agents a new login key and enrolls it at the
  PDS, replacing the one it had: the way back for an agent that lost its key,
  or whose key leaked. The new key signs the request (its proof of
  possession). Only a principal does this, for an agent: an account's own
  first key is enrolled with its full password session, outside AtMcp.
  """
  def enroll_agent_key(session, agent) do
    with {:ok, names} <- names(),
         {:ok, agent} <- did_arg(agent, "agent"),
         :ok <- not_self(session, agent),
         {:ok, pds_did} <- pds_did(session) do
      next = key_path(agent) <> ".next"
      File.rm(next)

      with {:ok, login} <- Helper.call("key.generate", %{keyFile: next}),
           {:ok, %{"proof" => proof}} <-
             Helper.call("key.prove", %{
               keyFile: next,
               iss: Session.did(session),
               sub: agent,
               aud: pds_did,
               lxm: "#{names.agent}.enrollKey"
             }),
           {:ok, _} <-
             agent_call(session, names, "enrollKey", %{
               "did" => agent,
               "loginKey" => login["didKey"],
               "loginKeyProof" => proof
             }) do
        # The new key replaces the old one in place: a superseded key is
        # kept nowhere.
        File.rename!(next, key_path(agent))
        AtMcp.Spaces.AgentRevocations.clear(Session.did(session), agent)
        {:ok, %{did: agent, login_key: login["didKey"], enrolled: true}}
      else
        error ->
          File.rm(next)
          error
      end
    end
  end

  # A full handle (a name under a domain), not a bare name.
  defp handle_arg(handle) when is_binary(handle) do
    if Regex.match?(
         ~r/\A[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+\z/,
         handle
       ),
       do: :ok,
       else:
         invalid(
           "handle",
           "must be a full handle, a name under the town's handle domain, such as helper.delve.town"
         )
  end

  defp handle_arg(_), do: invalid("handle", "is required")

  defp not_self(session, agent) do
    if agent == Session.did(session),
      do:
        {:error,
         Failure.new(:refused,
           detail: :not_an_agent,
           message:
             "enroll_agent_key gives one of this account's agents a new key; it can't enroll a key for this account itself, which takes the account's full password session (at_mcp-accounts key, after enrolling it at the PDS)."
         )},
      else: :ok
  end

  @doc """
  The public rotation key (a `did:key`) the accounts file gives for the
  principal `did`, or a refusal saying how to give one.
  """
  def principal_rotation_key(did) do
    case AtMcp.AccountConfig.load(AtMcp.AccountConfig.path()) do
      {:ok, accounts} ->
        case Enum.find(accounts, &(&1["did"] == did)) do
          %{"rotation_key" => "did:key:" <> _ = key} ->
            {:ok, key}

          _ ->
            {:error,
             Failure.new(:refused,
               detail: :no_rotation_key,
               message:
                 "Creating an agent needs this account's public rotation key, which the installation's operator sets (at_mcp-accounts rotation-key NAME --did-key did:key:...). Its private half stays offline with whoever runs this account."
             )}
        end

      _ ->
        {:error,
         Failure.new(:refused,
           detail: :no_rotation_key,
           message: "The accounts file could not be read."
         )}
    end
  end

  @doc "Whether the account `did` acts as a principal: the accounts file gives it a rotation key."
  def principal?(did), do: match?({:ok, _}, principal_rotation_key(did))

  @doc """
  Deletes one of this account's agents: its account and repository on the
  PDS (its DID stays, under this account's rotation key). It can't be
  undone, so it takes `confirm` true. The agent's login key is deleted from
  the key folder.
  """
  def delete_agent(session, agent, confirm?) do
    with {:ok, names} <- names(),
         {:ok, agent} <- did_arg(agent, "agent"),
         :ok <- not_self(session, agent),
         :ok <-
           if(confirm? == true,
             do: :ok,
             else: invalid("confirm", "must be true: deleting an agent can't be undone")
           ),
         {:ok, _} <- agent_call(session, names, "deleteAgent", %{"did" => agent}) do
      key = key_path(agent)

      if File.exists?(key),
        do: File.rm!(key)

      {:ok, %{did: agent, deleted: true}}
    end
  end

  # --- handing an agent to another principal ---
  #
  # Two steps, each by its own account: this account, the agent's principal,
  # offers it (`offerTransfer`, good for 7 days); the account offered accepts
  # (`acceptTransfer`) with its own rotation key, and becomes the principal.
  # Accepting suspends the agent's login key and ends its sessions, since the
  # old principal's installation holds that key: the agent is paired again
  # from where it runs (`at_mcp-accounts repair`), with a key the new
  # principal enrolls. The new principal makes the agent's state space under
  # itself, and the agent's at_mcp, once it runs again, carries its own
  # records there and clears them from the old one (`principal_of/1`): only
  # the agent can, since its records live in its own repository.

  @doc """
  Offers this account's agent `agent` to the account `to`, which becomes its
  principal when it accepts within 7 days; with `cancel` true, withdraws the
  offer. A new offer replaces an earlier one. Until it is accepted, this
  account still answers for the agent.
  """
  def offer_agent_handoff(session, agent, to, cancel?) do
    with {:ok, names} <- names(),
         {:ok, agent} <- did_arg(agent, "agent"),
         :ok <- not_self(session, agent) do
      if cancel? == true do
        with {:ok, _} <-
               transfer_call(session, names, "offerTransfer", %{
                 "did" => agent,
                 "cancel" => true
               }),
             do: {:ok, %{did: agent, cancelled: true}}
      else
        with {:ok, to} <- did_arg(to, "to"),
             {:ok, offered} <-
               transfer_call(session, names, "offerTransfer", %{"did" => agent, "to" => to}) do
          {:ok,
           %{
             did: agent,
             to: to,
             expires_at: offered["expiresAt"],
             next:
               "#{to} accepts it with accept_agent_handoff (agent: #{agent}) before #{offered["expiresAt"] || "the offer expires"}. Until then this account answers for the agent; withdraw the offer with cancel true. Accepting stops the agent until it is paired again with a key its new principal enrolls. Keep this account until the agent has run again and carried its notes to its new principal: its state space here goes with this account. For 72 hours after, this account's PLC rotation key can still undo the hand-off."
           }}
        end
      end
    end
  end

  @doc "The agents other principals have offered to this account (`listAgents`' `offers`)."
  def get_agent_handoff_offers(session) do
    with {:ok, names} <- names(),
         {:ok, listed} <- transfer_call(session, names, "listAgents", nil) do
      {:ok,
       %{
         offers:
           for o <- listed["offers"] || [] do
             %{did: o["did"], handle: o["handle"], from: o["from"], expires_at: o["expiresAt"]}
           end
       }}
    end
  end

  @doc """
  Accepts `agent`, offered to this account: this account becomes its
  principal, with its rotation key on the agent's identity and `agent-of`
  naming it. Writes the endorsement where the PDS didn't, and makes the
  agent's state space under this account, which the agent fills from the old
  one once it runs again. The password the PDS gives once isn't kept.
  Accepting stops the agent (its login key suspended, its sessions ended):
  it runs again once paired with a key this account enrolls. Safe to retry.
  """
  def accept_agent_handoff(session, agent) do
    with {:ok, names} <- names(),
         {:ok, agent} <- did_arg(agent, "agent"),
         :ok <- not_self(session, agent),
         {:ok, rotation_key} <- principal_rotation_key(Session.did(session)),
         {:ok, accepted} <-
           transfer_call(session, names, "acceptTransfer", %{
             "did" => agent,
             "recoveryKey" => rotation_key
           }) do
      principal = Session.did(session)

      endorsement =
        if accepted["endorsed"] == true do
          %{uri: accepted["endorsement"], written_by: "the PDS"}
        else
          case endorse_agent(session, agent) do
            {:ok, written} -> written
            {:error, failure} -> %{error: failure.message}
          end
        end

      state = make_agent_space(session, agent)
      old = old_principal(accepted["oldEndorsement"])
      # Its key is suspended: started again here, it gets a new one.
      AtMcp.Spaces.AgentRevocations.mark(principal, agent)

      {:ok,
       %{
         did: agent,
         principal: principal,
         rotation_key: rotation_key,
         endorsement: endorsement,
         agent_space: state,
         previous_principal: old,
         password:
           "not kept: at_mcp gets a fresh one from the PDS when this account must sign in as the agent",
         next:
           "The agent is stopped until it is paired again: where it runs, its operator runs at_mcp-accounts repair NAME --principal <this account's handle>, and this account enrolls the key that prints (or, to run it on this installation, enroll_agent_key and at_mcp-accounts add-agent NAME --did #{agent}). Once it runs, its at_mcp copies its notes into its new state space and clears them from the old one" <>
             if(old,
               do:
                 " (#{agent_space_uri(old, agent)}), which goes when #{old}'s account is deleted. #{old} deletes its old endorsement of the agent.",
               else: "."
             )
       }}
    end
  end

  # The hand-off routes sit behind the PDS's PDS_AGENT_TRANSFERS: off, they
  # answer MethodNotImplemented, said as such.
  defp transfer_call(session, names, name, body) do
    case agent_call(session, names, name, body) do
      {:error, %Failure{detail: detail} = f}
      when detail in ["MethodNotImplemented", "MethodNotSupported"] ->
        {:error,
         %{
           f
           | kind: :refused,
             message:
               "This PDS doesn't offer agent hand-offs (#{names.agent}.#{name} isn't served): its operator turns them on."
         }}

      other ->
        other
    end
  end

  # The account whose endorsement the PDS names as the old one
  # (`at://<old principal>/link.ident.endorsement/<agent>`).
  defp old_principal("at://" <> rest) do
    case String.split(rest, "/") do
      ["did:" <> _ = did | _] -> did
      _ -> nil
    end
  end

  defp old_principal(%{"uri" => uri}), do: old_principal(uri)
  defp old_principal(_other), do: nil

  @doc """
  Looks again at who governs this account's notes, and carries its records
  to a new principal's state space after a hand-off (`principal_of/1`).
  Run by `AtMcp.Spaces.InboxTokens` on each pass, so an agent moves its
  notes while it runs, not only at its next note. Answers the binding.
  """
  def carry_agent_state(session) do
    :persistent_term.erase({__MODULE__, :principal_of, Session.did(session)})

    case principal_of(session) do
      {:ok, principal} -> {:ok, %{principal: principal}}
      :none -> {:ok, %{principal: Session.did(session)}}
      {:error, _} = error -> error
    end
  end

  # After a hand-off: the agent's own records copied from `old`'s state space
  # into `new`'s, under the same keys (so a copy cut short is finished by the
  # next), then cleared from the old space (`clearRecords`), since the data
  # follows the agent. `:ok` once done, or when the old space is gone;
  # otherwise the binding stays and the next look tries again.
  defp carry(session, old, new) do
    did = Session.did(session)
    from = agent_space_uri(old, did)
    to = agent_space_uri(new, did)

    with {:ok, _} <- helper(session, "space.get", %{space: to}),
         {:ok, %{"records" => records}} <-
           helper(session, "space.all", %{space: from, limit: 100_000}) do
      mine = Enum.filter(records, &(&1["repo"] == did and &1["valid"] != false and &1["rkey"]))

      copied? =
        Enum.all?(mine, fn r ->
          match?(
            {:ok, _},
            helper(session, "space.records.put", %{
              space: to,
              collection: r["collection"],
              rkey: r["rkey"],
              record: r["record"]
            })
          )
        end)

      cond do
        not copied? ->
          {:error, :not_all_copied}

        true ->
          case helper(session, "space.records.clear", %{space: from}) do
            {:ok, _} -> :ok
            {:error, %Failure{detail: "SpaceNotFound"}} -> :ok
            # Copied; clearing tried again at the next look.
            error -> error
          end
          |> tap(fn _ -> Logger.info("carried #{length(mine)} records from #{from} to #{to}") end)
      end
    else
      {:error, %Failure{detail: "SpaceNotFound"}} = missing ->
        case helper(session, "space.get", %{space: from}) do
          {:error, %Failure{detail: "SpaceNotFound"}} ->
            Logger.warning(
              "this agent's earlier state space #{from} is gone; nothing was carried"
            )

            :ok

          # The new principal hasn't made its space yet.
          _ ->
            missing
        end

      error ->
        error
    end
  end

  @doc """
  Stops one of this account's agents, or starts it again, as its PDS has a
  principal do it: signed in as the agent with a password the PDS gives
  for it now (`rotatePassword`, kept nowhere), `deactivateAccount` or
  `activateAccount`. Deactivating doesn't end the agent's OAuth sessions,
  so stopping also revokes them (`revokeSessions`).
  """
  def set_agent_status(session, agent, status) when status in ["active", "deactivated"] do
    with {:ok, agent} <- did_arg(agent, "agent"),
         :ok <- not_self(session, agent),
         revoked_before? = AtMcp.Spaces.AgentRevocations.revoked?(Session.did(session), agent),
         {:ok, token} <- signed_in_as_agent(session, agent),
         {:ok, _} <-
           agent_account_call(
             session,
             token,
             if(status == "deactivated", do: "deactivateAccount", else: "activateAccount")
           ) do
      revoked =
        if status == "deactivated",
          do: match?({:ok, _}, revoke_agent_sessions(session, agent))

      # Revoking also retired the agent's login key: started again, it gets
      # a new one, which its at_mcp logs in with.
      rekeyed =
        if status == "active" and revoked_before?,
          do: match?({:ok, _}, enroll_agent_key(session, agent))

      {:ok,
       %{did: agent, status: status}
       |> put_present(:revoked, revoked)
       |> put_present(:new_login_key, rekeyed)}
    end
  end

  def set_agent_status(_session, _agent, _status),
    do: invalid("status", "must be active or deactivated")

  # A full session as the agent, with a password the PDS gives this
  # principal for it now (`rotatePassword`), used once and kept nowhere.
  defp signed_in_as_agent(session, agent) do
    with {:ok, names} <- names(),
         {:ok, %{"password" => fresh}} <-
           agent_call(session, names, "rotatePassword", %{"did" => agent}) do
      agent_password_session(session, agent, fresh)
    end
  end

  # A full session as the agent (createSession with its password), for the
  # account methods its principal uses: the token only.
  defp agent_password_session(session, agent, password) do
    url = Path.join(AtMcp.ATProto.base_url(session), "com.atproto.server.createSession")

    case Req.post(url, json: %{identifier: agent, password: password}, retry: false) do
      {:ok, %{status: 200, body: %{"accessJwt" => token}}} ->
        {:ok, token}

      {:ok, %{status: status, body: body}} ->
        {:error,
         Failure.new(if(status in 400..499, do: :refused, else: :indeterminate),
           status: status,
           detail: is_map(body) && body["error"],
           message:
             "Signing in as the agent with its password failed (#{(is_map(body) && body["message"]) || status})."
         )}

      {:error, error} ->
        {:error,
         Failure.new(:indeterminate, detail: :transport, message: Exception.message(error))}
    end
  end

  defp agent_account_call(session, token, method) do
    url = Path.join(AtMcp.ATProto.base_url(session), "com.atproto.server.#{method}")

    # deactivateAccount takes an (empty) input; activateAccount takes none, and
    # refuses a body.
    body = if method == "deactivateAccount", do: [json: %{}], else: [body: ""]

    case Req.post(url, [headers: [{"authorization", "Bearer " <> token}], retry: false] ++ body) do
      {:ok, %{status: 200}} ->
        {:ok, method}

      {:ok, %{status: status, body: body}} ->
        {:error,
         Failure.new(:refused,
           status: status,
           detail: is_map(body) && body["error"],
           message:
             "#{method} as the agent answered #{status}: #{(is_map(body) && body["message"]) || ""}"
         )}

      {:error, error} ->
        {:error,
         Failure.new(:indeterminate, detail: :transport, message: Exception.message(error))}
    end
  end

  def revoke_agent_sessions(session, agent) do
    with {:ok, names} <- names(),
         {:ok, agent} <- did_arg(agent, "agent"),
         {:ok, answer} <- agent_call(session, names, "revokeSessions", %{"did" => agent}) do
      # The PDS sets its password to one nobody knows: the kept one is stale.
      AtMcp.Spaces.AgentRevocations.mark(Session.did(session), agent)
      answer = if is_map(answer), do: answer, else: %{}

      # What may outlive the revoke, as the PDS says it (stateless tokens,
      # for up to their lifetime), and what no PDS can end: a group host's
      # acting credential lasts its own 15 minutes.
      {:ok,
       %{
         did: agent,
         revoked: true,
         outstanding: answer["outstanding"],
         revocation_complete_at: answer["revocationCompleteAt"],
         elsewhere:
           "A group host's credential already issued to the agent lasts up to its own lifetime (15 minutes on group-host 0.6.0); removing the agent from a group ends it there at once."
       }}
    end
  end

  # A `town.delve.agent.*` call to the account's own PDS, with service auth
  # (`aud` the PDS's DID, `lxm` the method). A nil body is a GET.
  defp agent_call(session, names, name, body) do
    method = "#{names.agent}.#{name}"
    base = AtMcp.ATProto.base_url(session)

    # The audience names the PDS's service, as the explicit rpc: scope the
    # session holds does (`scope_for/2`).
    with {:ok, pds_did} <- pds_did(session),
         {:ok, minting} <- privileged_session(session, method),
         {:ok, token} <-
           AtMcp.ATProto.ServiceAuth.issue_for(minting, pds_did <> "#atproto_pds", method) do
      if body,
        do: http(:post, "#{base}/#{method}", token, body),
        else: http(:get, "#{base}/#{method}", token, %{})
    end
  end

  # The session that may mint service auth for a privileged agent route: the
  # account's OAuth session (its own, or from its login key), since an app
  # password may not.
  defp privileged_session(session, method) do
    with {:ok, oauth} <- oauth_session(session) do
      if holds_method?(oauth, method) do
        {:ok, oauth}
      else
        # A session that began before the account became a principal holds
        # none of the agent routes: log in again with the key, once, for the
        # scope the account now needs.
        case AtMcp.Spaces.Login.fresh(Session.did(session)) do
          {:ok, creds} ->
            fresh = AtMcp.Spaces.Login.session(creds, Session.handle(session))

            if holds_method?(fresh, method),
              do: {:ok, fresh},
              else: relogin_needed(method)

          _ ->
            relogin_needed(method)
        end
      end
    end
  end

  # A session holds an agent route by name, or through the permission set
  # that covers them all, as the PDS may grant it unexpanded.
  defp holds_method?(%{scope: scope}, method) when is_binary(scope) do
    rpc_methods(scope) |> Enum.member?(method) or
      case String.split(method, ".") |> Enum.split(-1) do
        {ns, [m]} ->
          m in @agent_methods and
            String.contains?(scope, "include:#{agent_set(Enum.join(ns, "."))}")

        _ ->
          false
      end
  end

  defp holds_method?(_session, _method), do: false

  # The methods a scope's rpc permissions name, in either form a PDS grants:
  # `rpc:<method>?aud=…`, or a permission set expanded into one
  # `rpc?lxm=<a>&lxm=<b>&aud=…`.
  defp rpc_methods(scope) do
    scope
    |> String.split()
    |> Enum.flat_map(fn token ->
      {head, query} =
        case String.split(token, "?", parts: 2) do
          [h, q] -> {h, q}
          [h] -> {h, ""}
        end

      lxms =
        query
        |> String.split("&", trim: true)
        |> Enum.flat_map(fn pair ->
          case String.split(pair, "=", parts: 2) do
            ["lxm", m] -> [URI.decode_www_form(m)]
            _ -> []
          end
        end)

      case head do
        "rpc:" <> method -> [method | lxms]
        "rpc" -> lxms
        _ -> []
      end
    end)
  end

  defp relogin_needed(method),
    do:
      {:error,
       Failure.new(:refused,
         detail: :relogin_needed,
         message:
           "This account's session doesn't hold #{method}: it began before the account was made a principal (rotation_key). Log it in again: at_mcp-accounts reconnect NAME, or restart at_mcp."
       )}

  defp oauth_session(%ProtoRune.Atproto.OAuth.Session{} = session), do: {:ok, session}

  defp oauth_session(session) do
    did = Session.did(session)

    case AtMcp.Spaces.Login.credentials(did) do
      {:ok, creds} ->
        {:ok, AtMcp.Spaces.Login.session(creds, Session.handle(session))}

      {:error, %Failure{detail: code}} when code in ["no_session", "session_lost"] ->
        {:error,
         Failure.new(:refused,
           detail: :no_login_key,
           message:
             "Managing agents needs this account's OAuth session, which comes from its login key; this account has no key_file in the accounts file."
         )}

      error ->
        error
    end
  end

  # The account's own PDS's DID, as the agent routes and the key proof name
  # it: the same cached describeServer read as `scope_for/2`.
  defp pds_did(session) do
    case service_did(AtMcp.ATProto.base_url(session), Session.did(session)) do
      {:ok, did} ->
        {:ok, did}

      {:error, _} = error ->
        error

      _ ->
        {:error,
         Failure.new(:indeterminate,
           detail: :unreadable_server,
           message: "The PDS did not say its DID."
         )}
    end
  end

  @doc "The installation's folder of agents' login keys (0700)."
  def keys_dir do
    dir =
      Application.get_env(:at_mcp, :keys_dir) ||
        Path.join(AtMcp.Inbound.Store.default_dir(), "keys")

    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  @doc "Where an agent's login key is kept, by its DID."
  def key_path(did), do: Path.join(keys_dir(), "login-#{safe(did)}.json")

  defp safe(did), do: String.replace(did, ~r/[^A-Za-z0-9._-]/, "_")

  # --- identity ---

  @doc "Writes this account's `link.ident.endorsement` of `agent` (key: the agent's DID)."
  def endorse_agent(session, agent) do
    with {:ok, agent} <- did_arg(agent, "agent") do
      record = %{
        "$type" => "link.ident.endorsement",
        "agent" => agent,
        "createdAt" =>
          DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
      }

      case AtMcp.ATProto.put_record(session, %{
             repo: Session.did(session),
             collection: "link.ident.endorsement",
             rkey: agent,
             record: record
           }) do
        {:ok, written} ->
          {:ok,
           %{
             agent: agent,
             uri: written[:uri] || written["uri"],
             cid: written[:cid] || written["cid"]
           }}

        {:error, reason} ->
          {:error, to_failure(reason)}
      end
    end
  end

  @doc """
  An account's principals as ident.link pairs them: each `agent-of` its DID
  document names, and whether that principal's endorsement of it exists.
  Only a confirmed pair attributes the agent; neither half alone does.
  """
  def get_principals(session, actor) do
    with :ok <- text_arg(actor, "account"),
         {:ok, doc} <- resolve_did_doc(session, actor) do
      did = doc["id"]
      claimed = for "https://ident.link/agent-of/" <> p <- doc["alsoKnownAs"] || [], do: p

      principals =
        for principal <- claimed do
          status = endorsement(session, principal, did)
          %{did: principal, confirmed: status == "confirmed", confirmation: status}
        end

      # Named as people are elsewhere: handle and display name, then the DID.
      profiles = author_profiles(session, Enum.uniq([did | claimed]))

      named = fn m, d ->
        p = profiles[d] || %{}
        Map.merge(m, %{handle: p["handle"], display_name: p["displayName"]})
      end

      {:ok, named.(%{did: did, principals: Enum.map(principals, &named.(&1, &1.did))}, did)}
    end
  end

  @doc """
  Whether `principal` endorses `agent`, as ident.link has a consumer check
  it: the endorsement (`link.ident.endorsement`, key the agent's DID) as
  the principal's repository proves it (`com.atproto.sync.getRecord`,
  verified against the signing key in the principal's DID document), naming
  the agent. Answers `"confirmed"`; `"not_endorsed"` (no such record, or one
  naming another agent); `"proof_invalid"` (a record whose proof doesn't
  hold: never taken for an endorsement); or `"unavailable"` (the principal's
  DID document or repository couldn't be read now: not a no).
  """
  def endorsement(session, principal, agent) do
    with {:ok, doc} <- resolve_did_doc(session, principal),
         {:ok, pds, key} <- repo_service(doc) do
      case Helper.call("record.verify", %{
             pds: pds,
             did: principal,
             collection: "link.ident.endorsement",
             rkey: agent,
             signingKey: key
           }) do
        {:ok, %{"found" => true, "record" => %{"agent" => ^agent}}} -> "confirmed"
        {:ok, %{"found" => _}} -> "not_endorsed"
        {:error, %Failure{detail: "ProofInvalid"}} -> "proof_invalid"
        _ -> "unavailable"
      end
    else
      _ -> "unavailable"
    end
  end

  # The account's PDS and its repository's signing key (a did:key), from its
  # DID document.
  defp repo_service(doc) do
    pds =
      Enum.find_value(doc["service"] || [], fn s ->
        if is_binary(s["id"]) and String.ends_with?(s["id"], "#atproto_pds"),
          do: s["serviceEndpoint"]
      end)

    key =
      Enum.find_value(doc["verificationMethod"] || [], fn m ->
        if is_binary(m["id"]) and String.ends_with?(m["id"], "#atproto") and
             is_binary(m["publicKeyMultibase"]),
           do: "did:key:" <> m["publicKeyMultibase"]
      end)

    if is_binary(pds) and is_binary(key), do: {:ok, pds, key}, else: {:error, :no_repo_service}
  end

  # The DID document, from the PLC directory (`AT_MCP_PLC_URL`) or a
  # did:web's own host: the account's PDS need not serve
  # `com.atproto.identity.resolveDid`.
  defp resolve_did_doc(session, actor) do
    with {:ok, did} <- resolve_actor(session, actor) do
      url =
        case did do
          "did:plc:" <> _ ->
            String.trim_trailing(
              Application.get_env(:at_mcp, :plc_url) || "https://plc.directory",
              "/"
            ) <>
              "/" <> did

          "did:web:" <> host ->
            "https://#{URI.decode(host)}/.well-known/did.json"

          _ ->
            nil
        end

      if url,
        do: http(:get, url, nil, %{}),
        else: invalid("account", "must be a did:plc or did:web DID")
    end
  end

  defp resolve_actor(_session, "did:" <> _ = did), do: {:ok, did}

  defp resolve_actor(session, handle) do
    case AtMcp.ATProto.pds_get(session, "com.atproto.identity.resolveHandle", %{handle: handle}) do
      {:ok, %{did: did}} -> {:ok, did}
      {:ok, %{"did" => did}} -> {:ok, did}
      {:error, reason} -> {:error, to_failure(reason)}
    end
  end

  # --- the helper, and plain HTTP ---

  # A call on the account's helper session. When the helper holds no session
  # for the account, it logs in with the account's key, once, and the call
  # is tried again.
  defp helper(session, method, params) do
    did = Session.did(session)

    case Helper.call(method, Map.put(params, :did, did)) do
      {:error, %Failure{detail: code}}
      when code in ["no_session", "TokenRefreshError", "TokenRevokedError", "TokenInvalidError"] ->
        with {:ok, _} <- AtMcp.Spaces.Login.credentials(did, refresh: false),
             do: Helper.call(method, Map.put(params, :did, did))

      other ->
        other
    end
  end

  # A helper call on a space someone named (a group's feed, a post in one).
  # The PDS answers a space this account can't reach, or that doesn't exist,
  # with a missing scope or SpaceNotFound, which reads like a permissions
  # problem: it is said as what it is, with the account's own spaces.
  @no_space ["ScopeMissingError", "ScopeMissing", "SpaceNotFound", "InvalidRequest"]

  defp given(session, method, %{space: space} = params) do
    case helper(session, method, params) do
      {:error, %Failure{detail: code, status: status} = failure}
      when code in @no_space and (status in [400, 403, 404] or code == "SpaceNotFound") ->
        did = Session.did(session)

        own =
          case AtMcp.Network.spaces() do
            %{} ->
              case principal_of(session) do
                {:ok, principal} ->
                  "#{agent_space_uri(principal, did)} (this agent's notes: the note tools)"

                _ ->
                  nil
              end

            nil ->
              nil
          end

        {:error,
         %Failure{
           failure
           | kind: :refused,
             detail: :no_such_space,
             message:
               "No such space, or not one this account can read or write: #{space}. " <>
                 "This account's own spaces are " <>
                 Enum.join(
                   Enum.reject(
                     [
                       own,
                       "at:space/#{did}/org.atgrp.inbox/self (group invites: get_group_invites)"
                     ],
                     &is_nil/1
                   ),
                   " and "
                 ) <>
                 ". A group's feed is reached by accepting its invite (get_group_invites, accept_group_invite); its posts' at:space/ URIs come from get_space_feed."
         }}

      other ->
        other
    end
  end

  defp http(method, url, token, payload) do
    headers = if token, do: [{"authorization", "Bearer " <> token}], else: []

    options =
      [method: method, url: url, headers: headers, redirect: false, retry: false]
      |> then(fn o ->
        case method do
          :get ->
            Keyword.put(o, :params, Enum.reject(payload || %{}, fn {_k, v} -> is_nil(v) end))

          :post ->
            Keyword.put(o, :json, payload)
        end
      end)

    case Req.request(options) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        # A DID document comes as application/did+ld+json, which Req leaves
        # undecoded.
        case body do
          %{} ->
            {:ok, body}

          text when is_binary(text) ->
            {:ok, with({:ok, %{} = m} <- Jason.decode(text), do: m, else: (_ -> %{}))}

          _ ->
            {:ok, %{}}
        end

      {:ok, %{status: status, body: body}} ->
        body = if is_map(body), do: body, else: %{}

        kind =
          cond do
            status == 401 -> :auth_refused
            status in 400..499 or status == 501 -> :refused
            true -> :indeterminate
          end

        {:error,
         Failure.new(kind,
           status: status,
           detail: body["error"],
           message: body["message"] || body["error"] || "HTTP #{status}"
         )}

      {:error, error} ->
        {:error,
         Failure.new(:indeterminate, detail: :transport, message: Exception.message(error))}
    end
  end

  defp to_failure(%Failure{} = f), do: f

  defp to_failure(%ProtoRune.XRPC.Error{} = e) do
    kind =
      cond do
        e.http_status == 401 -> :auth_refused
        is_integer(e.http_status) and e.http_status in 400..499 -> :refused
        true -> :indeterminate
      end

    Failure.new(kind, status: e.http_status, message: e.message, detail: e.reason)
  end

  defp to_failure(other), do: Failure.new(:indeterminate, message: inspect(other))

  # --- arguments ---

  defp names do
    case AtMcp.Network.spaces() do
      nil ->
        {:error,
         Failure.new(:refused,
           detail: :spaces_not_served,
           message:
             "#{AtMcp.Network.label()} has no town spaces or agent routes; these tools work on delve.town."
         )}

      names ->
        {:ok, names}
    end
  end

  defp did_arg("did:" <> _ = did, _field), do: {:ok, did}
  defp did_arg(_other, field), do: invalid(field, "must be a DID")

  defp rkey_arg(rkey) when is_binary(rkey) and rkey != "" do
    if Regex.match?(~r/\A[A-Za-z0-9._:~-]{1,512}\z/, rkey) and rkey not in [".", ".."],
      do: :ok,
      else: invalid("rkey", "must be a record key")
  end

  defp rkey_arg(_), do: invalid("rkey", "is required")

  defp text_arg(value, _field) when is_binary(value) and value != "", do: :ok
  defp text_arg(_value, field), do: invalid(field, "is required")

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp invalid(field, why),
    do: {:error, Failure.new(:refused, detail: :invalid_argument, message: "#{field} #{why}")}
end
