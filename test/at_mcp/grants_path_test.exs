defmodule AtMcp.GrantsPathTest do
  # The service authorizes requests from `AtMcp.Grants.path/0`; `at_mcp-accounts`
  # issues grants into `AtMcp.Grants.path_for/1` of the accounts file. A variable
  # that moved only one of them would leave every issued grant unknown to the
  # service, so there is no such variable.
  use ExUnit.Case, async: false

  setup do
    previous = Enum.map(~w(AT_MCP_ACCOUNTS_FILE AT_MCP_GRANTS_FILE), &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "the grants file is the accounts file's, and nothing in the environment moves it" do
    accounts =
      Path.join(
        System.tmp_dir!(),
        "at_mcp-grants-path-#{System.unique_integer([:positive])}.json"
      )

    System.put_env("AT_MCP_ACCOUNTS_FILE", accounts)
    System.put_env("AT_MCP_GRANTS_FILE", Path.join(System.tmp_dir!(), "elsewhere.grants.json"))

    assert AtMcp.Grants.path() == AtMcp.Grants.path_for(accounts)
    assert AtMcp.Grants.path() == Path.rootname(accounts) <> ".grants.json"
  end
end
