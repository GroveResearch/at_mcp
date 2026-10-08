defmodule AtMcp.Test.Settings do
  @moduledoc """
  Application settings for one test. A release takes them from the environment
  through config/runtime.exs; a test sets the application environment that file
  would have written, and gets the previous values back when it exits.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  @doc """
  Code that has a VM started with `elixir -e` read config/runtime.exs from its
  environment, as a release does before it runs a command.
  """
  def from_environment do
    """
    Application.load(:at_mcp)
    Config.Reader.read!(#{inspect(@runtime)}, env: :prod) |> Application.put_all_env()
    """
  end

  def put(settings) do
    for {key, value} <- settings do
      previous = Application.fetch_env(:at_mcp, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:at_mcp, key, value)
          :error -> Application.delete_env(:at_mcp, key)
        end
      end)

      Application.put_env(:at_mcp, key, value)
    end

    :ok
  end
end
