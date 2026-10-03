# Invoked by a separate Mix consumer after its dependency applications start.
[] = AtMcp.Identities.env_identity_specs()
[] = AtMcp.Identities.list_ids()
{:ok, []} = AtMcp.Accounts.status()
nil = AtMcp.Deliver.callback()
0 = map_size(:ranch.info())
:ok = AtMcp.CLI.service_status()

defmodule ExplicitEmbeddingBackend do
  def login(opts) do
    "explicit" = Keyword.fetch!(opts, :handle)
    "fixture" = Keyword.fetch!(opts, :password)
    {:ok, %{did: "did:plc:explicit", handle: "explicit"}}
  end

  def get_profile(%{did: did}, actor), do: {:ok, %{did: did, actor: actor}}
end

{:ok, _} =
  AtMcp.Identities.start_identity(
    id: "explicit",
    backend: ExplicitEmbeddingBackend,
    handle: "explicit",
    password: "fixture",
    listen_enabled: false
  )

effects = AtMcp.Identity.effects_name("explicit")
{:ok, %{did: "did:plc:explicit"}} = AtMcp.Effects.get_profile(effects, "explicit")
AtMcp.WriteQuota = AtMcp.Effects.write_quota(effects)
0 = map_size(:ranch.info())
nil = AtMcp.Deliver.callback()
:ok = AtMcp.CLI.service_status()
:ok = AtMcp.Accounts.disconnect("explicit")
{:ok, _} = AtMcp.Accounts.reconnect("explicit")
["explicit"] = AtMcp.Identities.list_ids()
IO.puts("embedding-consumer-passed")
