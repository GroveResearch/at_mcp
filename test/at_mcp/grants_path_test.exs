defmodule AtMcp.GrantsPathTest do
  # The service authorizes requests from `AtMcp.Grants.path/0`; `at_mcp-accounts`
  # issues grants into `AtMcp.Grants.path_for/1` of the accounts file. A setting
  # that moved only one of them would leave every issued grant unknown to the
  # service, so there is no such setting: the accounts file decides both.
  use ExUnit.Case, async: false

  test "the grants file is the accounts file's" do
    accounts =
      Path.join(
        System.tmp_dir!(),
        "at_mcp-grants-path-#{System.unique_integer([:positive])}.json"
      )

    AtMcp.Test.Settings.put(accounts_file: accounts)

    assert AtMcp.Grants.path() == AtMcp.Grants.path_for(accounts)
    assert AtMcp.Grants.path() == Path.rootname(accounts) <> ".grants.json"
  end
end
