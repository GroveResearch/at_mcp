defmodule AtMcp.Spaces do
  @moduledoc """
  What an agent does with atproto Spaces, Atmosphere Groups and its own
  agents, for one account: the work behind the notes, group, principal and
  identity tools.

  - **Personal notes** live in the account's personal space
    (`town.delve.space.personal`, key `self`), as `town.delve.notes.note`
    records. A personal space decides who can read it (the account, and apps
    it grants), but it is **not encrypted**: the operators of the PDS holding
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

  @readable_by "This account, and the apps it has granted access. Personal spaces are not encrypted: the operators of the server holding them can read them, so keep no secrets here."

  @reader_notice "This account's group inbox now lets the town's AppView read the invites in it, so it can tell this account about them in get_notifications. Nothing else in the account becomes readable. The installation's operator can turn this off (AT_MCP_TOWN_INBOX_READER=false); the AppView can also be removed from the inbox's members."

  @doc "What a note result says about who can read it."
  def readable_by, do: @readable_by

  # The town PDS counts the mutating agent routes as privileged: service auth
  # for them is minted only for a session that holds the matching `rpc:`
  # scope (or a full password session), never for an app password.
  @agent_methods ~w(createAgent enrollKey revokeSessions setStatus deleteAgent listAgents)

  @doc """
  The OAuth scope at_mcp asks for when an account's key logs it in, no more
  than the account needs:

  - `transition:generic`, for the app's public tools;
  - its personal space (any collection, and creating it), every group feed
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
      %{personal: personal, feed: feed, agent: agent} ->
        base = [
          "atproto",
          "transition:generic",
          "space:#{personal}?collection=*&manage=create",
          "space:#{feed}?authority=*",
          "space:org.atgrp.inbox?action=read_self&manage=create&manage=update"
        ]

        rpc =
          with true <- is_binary(did) and principal?(did),
               {:ok, pds} <- service_did(service, did) do
            aud = URI.encode_www_form(pds <> "#atproto_pds")
            for m <- @agent_methods, do: "rpc:#{agent}.#{m}?aud=#{aud}"
          else
            _ -> []
          end

        Enum.join(base ++ rpc, " ")

      nil ->
        "atproto transition:generic"
    end
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
  that has town spaces, unless `AT_MCP_TOWN_INBOX_READER=false`. Off, an inbox
  has no members, as the group host's design has it, and invites are seen
  with `get_group_invites` only. A reader added can be removed again.
  """
  def inbox_readers do
    if AtMcp.Network.spaces() && Application.get_env(:at_mcp, :town_inbox_reader, true) do
      [AtMcp.Network.appview_service() |> String.split("#") |> hd()]
    else
      []
    end
  end

  # --- personal notes ---

  @note_fields ~w(text title tags)
  # The note lexicon's text limits (`town.delve.notes.note`): 10 bytes a
  # grapheme, as the town's lexicon style has it.
  @note_graphemes 30_000
  @note_bytes 300_000

  def create_note(session, fields) do
    with {:ok, names} <- names(),
         {:ok, record} <- note_record(fields, nil) do
      in_personal(session, fn space ->
        helper(session, "space.records.create", %{
          space: space,
          collection: names.note,
          record: record
        })
      end)
      |> note_written(record)
    end
  end

  def get_note(session, rkey) do
    with {:ok, names} <- names(),
         :ok <- rkey_arg(rkey),
         {:ok, got} <-
           helper(session, "space.records.get", %{
             space: personal(session, names),
             collection: names.note,
             rkey: rkey
           }) do
      {:ok,
       note_summary(note_uri(session, names, got["uri"], rkey), got["cid"], got["value"] || %{})}
    end
  end

  def list_notes(session, limit, cursor) do
    with {:ok, names} <- names(),
         {:ok, page} <-
           helper(session, "space.records.list", %{
             space: personal(session, names),
             collection: names.note,
             limit: limit || AtMcp.Effects.page_limits().default,
             cursor: cursor
           }) do
      {:ok,
       %{
         notes:
           for r <- page["records"] || [] do
             note_summary(
               note_uri(session, names, r["uri"], r["rkey"]),
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
         {:ok, got} <-
           helper(session, "space.records.get", %{
             space: personal(session, names),
             collection: names.note,
             rkey: rkey
           }),
         {:ok, record} <- note_record(fields, got["value"] || %{}) do
      helper(session, "space.records.put", %{
        space: personal(session, names),
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
         {:ok, _} <-
           helper(session, "space.records.delete", %{
             space: personal(session, names),
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

      record["title"] && String.length(record["title"]) > 300 ->
        invalid("title", "may be at most 300 characters")

      record["tags"] && (not is_list(record["tags"]) or length(record["tags"]) > 16) ->
        invalid("tags", "may hold at most 16 tags")

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
  defp note_uri(_session, _names, uri, _rkey) when is_binary(uri), do: uri
  defp note_uri(_session, _names, nil, nil), do: nil

  defp note_uri(session, names, nil, rkey),
    do: "#{personal(session, names)}/#{Session.did(session)}/#{names.note}/#{rkey}"

  defp personal(session, names),
    do: "at:space/#{Session.did(session)}/#{names.personal}/self"

  # Runs `fun` on the personal space, creating it first when it does not
  # exist yet.
  defp in_personal(session, fun) do
    with {:ok, names} <- names() do
      space = personal(session, names)

      case fun.(space) do
        {:error, %Failure{detail: "SpaceNotFound"}} ->
          with {:ok, _} <-
                 helper(session, "space.create", %{
                   type: names.personal,
                   skey: "self",
                   policy: "personal"
                 }),
               do: fun.(space)

        result ->
          result
      end
    end
  end

  # --- groups ---

  @doc """
  The invites waiting for this account, from the group host's own list. Makes
  the account's inbox first if it has none, so groups can invite it there
  (with the town AppView as a read-only member, to raise notifications).
  """
  def list_group_invites(session) do
    with {:ok, inbox, notifications, notice} <- ensure_inbox(session),
         {:ok, body} <- group_host_get(session, "org.atgrp.internal.getActorInvites", %{}) do
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

      result = %{
        invites: invites,
        inbox: inbox,
        notifications: notifications
      }

      {:ok, if(notice, do: Map.put(result, :notice, notice), else: result)}
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
        case inbox["readers"] do
          [_ | _] ->
            # Said once, when the inbox is made with the reader, or when the
            # reader is first added to an inbox that had none.
            {register_inbox(session, space),
             if(inbox["added"] not in [nil, []], do: @reader_notice)}

          _ ->
            {"off", nil}
        end

      {:ok, space, notifications, notice}
    end
  end

  defp register_inbox(session, space) do
    case AtMcp.ATProto.register_space(session, %{space: space}) do
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
          "admitted" -> {:ok, Map.put(joined, "group", group_view(session, group))}
          _ -> {:ok, joined}
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
      {:ok, %{groups: Enum.map(body["groups"] || [], &group_view(session, &1["did"], &1))}}
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
      feeds: for(%{type: ^feed_type, uri: uri} <- spaces, do: uri)
    }
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
      {:ok, %{did: did}} -> {:ok, did}
      {:ok, %{"did" => did}} -> {:ok, did}
      _ -> invalid("group", "must be a group's DID or handle; #{handle} does not resolve")
    end
  end

  defp group_arg(_session, _), do: invalid("group", "must be a group's DID or handle")

  def leave_group(session, group) do
    with {:ok, group} <- group_arg(session, group),
         {:ok, _} <- group_host_post(session, "org.atgrp.leaveGroup", %{"group" => group}) do
      {:ok, %{left: true, group: group}}
    end
  end

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
    with {:space, _} <- space_uri(space) || :error,
         :ok <- post_text(text),
         :ok <- space_post_options(opts) do
      :ok
    else
      :error -> invalid("space", "must be an at:space/<authority>/<type>/<key> URI")
      error -> error
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
      :persistent_term.put(
        {__MODULE__, :previewed, Session.did(session), request_uri},
        {facts.group, System.monotonic_time(:second)}
      )

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
  @preview_seconds 600

  defp previewed(session, request_uri) do
    case :persistent_term.get({__MODULE__, :previewed, Session.did(session), request_uri}, nil) do
      {shown, at} ->
        if System.monotonic_time(:second) - at <= @preview_seconds,
          do: {:ok, shown},
          else: not_previewed("The preview is too old: preview the request again first.")

      _ ->
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
      :persistent_term.erase({__MODULE__, :previewed, Session.did(session), request_uri})
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
             "The app's request can sign in as any of #{Enum.map_join(groups, ", ", &"#{&1["handle"]} (#{&1["did"]})")}: give group; nothing was approved."
         )}

      nil ->
        {:error,
         Failure.new(:refused,
           detail: :group_not_offered,
           message:
             "The app's request does not offer #{wanted} to this account (it offers #{Enum.map_join(groups, ", ", &"#{&1["handle"]} (#{&1["did"]})")}); nothing was approved."
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
            with {:ok, %{"did" => did}} <-
                   http(:get, url <> "/xrpc/com.atproto.server.describeServer", nil, %{}) do
              :persistent_term.put({__MODULE__, :group_host, url}, {url, did})
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
         :ok <- text_arg(handle, "handle"),
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
             sub: String.downcase(handle),
             aud: pds_did,
             lxm: "#{names.agent}.createAgent"
           }) do
      case agent_call(session, names, "createAgent", %{
             "handle" => handle,
             "inviteCode" => invite_code,
             "loginKey" => login["didKey"],
             "loginKeyProof" => proof,
             "rotationKey" => rotation_key
           }) do
        {:ok, %{"did" => did} = created} ->
          File.rename!(pending, key_path(did))

          endorsement =
            case endorse_agent(session, did) do
              {:ok, written} -> written
              {:error, failure} -> %{error: failure.message}
            end

          {:ok,
           %{
             did: did,
             handle: created["handle"] || handle,
             login_key: login["didKey"],
             rotation_key: rotation_key,
             endorsement: endorsement
           }}

        error ->
          File.rm(pending)
          error
      end
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
        current = key_path(agent)

        if File.exists?(current),
          do: File.rename!(current, current <> ".replaced-#{System.system_time(:second)}")

        File.rename!(next, current)
        {:ok, %{did: agent, login_key: login["didKey"], enrolled: true}}
      else
        error ->
          File.rm(next)
          error
      end
    end
  end

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

  def revoke_agent_sessions(session, agent) do
    with {:ok, names} <- names(),
         {:ok, agent} <- did_arg(agent, "agent"),
         {:ok, _} <- agent_call(session, names, "revokeSessions", %{"did" => agent}) do
      {:ok, %{did: agent, revoked: true}}
    end
  end

  def set_agent_status(session, agent, status) when status in ["active", "deactivated"] do
    with {:ok, names} <- names(),
         {:ok, agent} <- did_arg(agent, "agent"),
         {:ok, _} <-
           agent_call(session, names, "setStatus", %{"did" => agent, "status" => status}) do
      {:ok, %{did: agent, status: status}}
    end
  end

  def set_agent_status(_session, _agent, _status),
    do: invalid("status", "must be active or deactivated")

  def list_my_agents(session) do
    with {:ok, names} <- names(),
         {:ok, body} <- agent_call(session, names, "listAgents", nil) do
      {:ok, %{agents: Map.get(body, "agents", [])}}
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
         {:ok, minting} <- privileged_session(session),
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
  defp privileged_session(%ProtoRune.Atproto.OAuth.Session{} = session), do: {:ok, session}

  defp privileged_session(session) do
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
          confirmed =
            case AtMcp.ATProto.get_record_as_stored(session, %{
                   repo: principal,
                   collection: "link.ident.endorsement",
                   rkey: did
                 }) do
              {:ok, %{"value" => %{"agent" => ^did}}} -> true
              _ -> false
            end

          %{did: principal, confirmed: confirmed}
        end

      {:ok, %{did: did, principals: principals}}
    end
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
            %{personal: personal} ->
              "at:space/#{did}/#{personal}/self (personal notes: the note tools)"

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
