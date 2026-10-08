defmodule AtMcp.Identity do
  @moduledoc """
  One AT Protocol identity on this BEAM: Effects + Notifications, with opt-in stream registration.

  Started under `AtMcp.Identities`. Credentials stay in this identity's Effects
  process — never shared with siblings. Inbound tracking is per session DID.

  An identity owns no listener. The MCP endpoint is one shared listener started
  by the application supervisor, and which identity a request reaches is decided by the
  grant it presents — see `AtMcp.MCP.HTTP`.
  """

  use Supervisor

  def start_link(opts) do
    id = opts |> Keyword.fetch!(:id) |> normalize_id()
    effects_name = Keyword.get(opts, :effects_name) || effects_atom(id)

    opts =
      opts
      |> Keyword.put(:id, id)
      |> Keyword.put(:effects_name, effects_name)

    Supervisor.start_link(__MODULE__, opts, name: via(id, %{effects: effects_name}))
  end

  def child_spec(opts) do
    id = opts |> Keyword.fetch!(:id) |> normalize_id()

    %{
      id: {:at_mcp_identity, id},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent
    }
  end

  def via(id, meta \\ %{}) do
    {:via, Registry, {AtMcp.Identity.Registry, normalize_id(id), meta}}
  end

  def whereis(id) do
    case Registry.lookup(AtMcp.Identity.Registry, normalize_id(id)) do
      [{pid, _}] -> if Process.alive?(pid), do: pid, else: nil
      _ -> nil
    end
  end

  @doc "Effects server name for this identity id, or nil."
  def effects_name(id) do
    case Registry.lookup(AtMcp.Identity.Registry, normalize_id(id)) do
      [{_pid, %{effects: effects}}] -> effects
      _ -> nil
    end
  end

  @impl true
  def init(opts) do
    if Process.whereis(AtMcp.Accounts) &&
         AtMcp.Inbound.Store.account({:can_start, to_string(opts[:id])}) do
      # Automatic child restarts bypass Accounts.start_identity. Notify its
      # owner asynchronously; readiness belongs to this runtime generation.
      send(AtMcp.Accounts, {:identity_started, to_string(opts[:id]), self()})
      init_children(opts)
    else
      :ignore
    end
  end

  defp init_children(opts) do
    id = Keyword.fetch!(opts, :id)
    effects_name = Keyword.fetch!(opts, :effects_name)
    listen_name = Keyword.get(opts, :listen_name) || listen_atom(id)
    notif_name = Keyword.get(opts, :notifications_name) || notifications_atom(id)

    notifications_enabled? =
      Keyword.get(
        opts,
        :notifications_enabled,
        Application.get_env(:at_mcp, :notifications_enabled, true)
      )

    effects_opts =
      [
        name: effects_name,
        identity_id: to_string(id),
        backend: Keyword.get(opts, :backend, AtMcp.Effects.ProtoRune),
        write_quota: Keyword.get(opts, :write_quota, AtMcp.WriteQuota)
      ]
      |> maybe_put(:handle, Keyword.get(opts, :handle))
      |> maybe_put(:password, Keyword.get(opts, :password))
      |> maybe_put(:service, Keyword.get(opts, :service))
      |> maybe_put(:expected_did, Keyword.get(opts, :expected_did))
      |> maybe_put(:backend_state, Keyword.get(opts, :backend_state))

    children =
      [
        {AtMcp.Effects, effects_opts},
        %{
          id: listen_name,
          start:
            {AtMcp.Listen, :start_link,
             [
               [
                 name: listen_name,
                 effects: effects_name,
                 inbound: Keyword.get(opts, :inbound, AtMcp.Inbound),
                 enabled:
                   Keyword.get(
                     opts,
                     :listen_enabled,
                     Application.get_env(:at_mcp, :jetstream_enabled, false)
                   )
               ]
               |> maybe_put(:did_poll_ms, Keyword.get(opts, :did_poll_ms))
             ]},
          type: :worker,
          restart: :permanent
        },
        %{
          id: notif_name,
          start:
            {AtMcp.Notifications, :start_link,
             [
               [
                 name: notif_name,
                 effects: effects_name,
                 enabled: notifications_enabled?
               ]
             ]},
          type: :worker,
          restart: :permanent
        }
      ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp normalize_id(id) when is_atom(id), do: Atom.to_string(id)
  defp normalize_id(id) when is_binary(id), do: id

  defp effects_atom(id), do: role_name(:effects, id)
  defp listen_atom(id), do: role_name(:listen, id)
  defp notifications_atom(id), do: role_name(:notifications, id)
  defp role_name(role, id), do: {:via, Registry, {AtMcp.Identity.Registry, {role, id}}}

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
