defmodule AtMcp.Test.QuotaFixture do
  @moduledoc false
  # Every backend test gets the real persistent quota, isolated from other cases.
  # Tests of shared ownership pass the same explicit server to both clients.
  def start_effects(opts) do
    {limit, opts} = Keyword.pop(opts, :quota_limit, 100)
    opts = Keyword.put_new_lazy(opts, :write_quota, fn -> quota(limit) end)
    AtMcp.Effects.start_link(opts)
  end

  def quota(limit) do
    directory =
      Path.join(System.tmp_dir!(), "at_mcp-effects-quota-#{System.unique_integer([:positive])}")

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(directory) end)

    ExUnit.Callbacks.start_supervised!(
      {AtMcp.WriteQuota, name: nil, state_dir: directory, limit: limit},
      id: make_ref()
    )
  end
end
