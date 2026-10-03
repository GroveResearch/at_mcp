# Live read-only account/PDS probe. No AtMcp application, inbound delivery, or
# public writes are started. Supply authorized credentials in the environment,
# plus BLUESKY_SERVICE and AT_MCP_EXPECTED_DID (optional second set with _2).
# Run with MIX_ENV=test mix run --no-start scripts/pds_read_probe.exs.
{:ok, _} = Application.ensure_all_started(:proto_rune)

accounts =
  for {id, suffix} <- [{"default", ""}, {"second", "_2"}],
      suffix == "" or not is_nil(System.get_env("BLUESKY_HANDLE" <> suffix)) do
    {id, suffix, System.fetch_env!("AT_MCP_EXPECTED_DID" <> suffix),
     System.fetch_env!("BLUESKY_SERVICE" <> suffix)}
  end

results =
  for {id, suffix, expected_did, service} <- accounts do
    {:ok, effects} =
      AtMcp.Effects.start_link(
        handle: System.fetch_env!("BLUESKY_HANDLE" <> suffix),
        password: System.fetch_env!("BLUESKY_APP_PASSWORD" <> suffix),
        service: service,
        credential_mode: :explicit,
        write_quota: :read_probe_no_write_quota
      )

    result =
      case AtMcp.Effects.login(effects) do
        {:ok, _} ->
          actual = AtMcp.Effects.session_did(effects)
          if actual != expected_did, do: raise("Account DID mismatch")

          case AtMcp.Effects.get_profile(effects, actual) do
            {:ok, profile} ->
              if profile.did != expected_did, do: raise("Profile DID mismatch")

              %{
                id: id,
                did: actual,
                service: service,
                login: true,
                profile_read: true
              }

            {:error, _} ->
              %{id: id, service: service, login: true, profile_read: false}
          end

        {:error, _} ->
          %{id: id, service: service, login: false}
      end

    Agent.stop(effects)
    result
  end

IO.puts(Jason.encode!(%{results: results, public_writes: false}))
if Enum.any?(results, &(!Map.get(&1, :profile_read, false))), do: System.halt(1)
