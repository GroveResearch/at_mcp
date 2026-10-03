defmodule AtMcp.Test.TokenEchoPlug do
  @moduledoc """
  Reports the `authorization` header of each request to a waiting test process.

  A delivery's credential is only observable on the wire, so a test that wants
  to know which token a callback used has to receive the request.
  """

  @behaviour Plug

  @impl true
  def init({parent, ref}), do: {parent, ref}

  @impl true
  def call(conn, {parent, ref}) do
    authorization =
      case Plug.Conn.get_req_header(conn, "authorization") do
        [value | _] -> value
        [] -> nil
      end

    send(parent, {ref, authorization})
    Plug.Conn.send_resp(conn, 200, "{}")
  end
end
