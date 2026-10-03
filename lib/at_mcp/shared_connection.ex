defmodule AtMcp.SharedConnection do
  @moduledoc false

  def main(args) do
    case OptionParser.parse(args, strict: [url: :string, did: :string]) do
      {opts, [], []} when length(opts) == 2 ->
        # The grant arrives in the environment, never in argv: a command line is
        # readable by every process on the machine.
        case {opts[:url], opts[:did], System.get_env("AT_MCP_GRANT")} do
          {url, did, grant}
          when is_binary(url) and is_binary(did) and is_binary(grant) and grant != "" ->
            AtMcp.MCP.SharedStdio.run(url, did, grant)

          _ ->
            usage()
        end

      _ ->
        usage()
    end
  end

  defp usage do
    IO.puts(
      :stderr,
      "Usage: AT_MCP_GRANT=<grant> at_mcp-connect --url http://127.0.0.1:PORT/mcp --did ACCOUNT_DID"
    )

    System.halt(1)
  end
end
