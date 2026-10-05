# Adapted from proto_rune 0.5.3 under MIT; original copyright and permission
# notice, source and modifications are retained in licenses/proto_rune/.
defmodule AtMcp.ATProto.DSL do
  @moduledoc """
  `defread` and `defwrite`: proto_rune's XRPC DSL with the namespace left out.

  A macro takes the suffix within the application namespace —
  `"feed.getPostThread"` — and resolves `AtMcp.Network.nsid/1` when the generated
  function is called rather than when it compiles, so one release serves
  whichever network an installation configures. Everything else is proto_rune's:
  the same `param` declarations, the same `Query`, `Procedure`, `Session` and
  `Client`, the same authenticated request.

  A parameter's declared name goes on the wire verbatim; see `AtMcp.ATProto` for
  what that implies.
  """

  alias ProtoRune.Session
  alias ProtoRune.XRPC.Client
  alias ProtoRune.XRPC.Config
  alias ProtoRune.XRPC.Procedure
  alias ProtoRune.XRPC.Query

  @doc """
  An authenticated GET, named by its suffix within the configured namespace.

      defread "feed.getLikes" do
        param(:uri, {:required, :string})
      end
  """
  defmacro defread(suffix, do: block) do
    fun = function_name(suffix)

    quote do
      Module.register_attribute(__MODULE__, :param, accumulate: true)

      unquote(block)

      def unquote(fun)(session, params) do
        AtMcp.ATProto.DSL.authenticated_query(
          session,
          AtMcp.Network.nsid(unquote(suffix)),
          Map.new(@param),
          params
        )
      end

      Module.delete_attribute(__MODULE__, :param)
    end
  end

  @doc """
  An authenticated POST, named by its suffix within the configured namespace.
  """
  defmacro defwrite(suffix, do: block) do
    fun = function_name(suffix)

    quote do
      Module.register_attribute(__MODULE__, :param, accumulate: true)

      unquote(block)

      def unquote(fun)(session, params) do
        AtMcp.ATProto.DSL.authenticated_procedure(
          session,
          AtMcp.Network.nsid(unquote(suffix)),
          Map.new(@param),
          params
        )
      end

      Module.delete_attribute(__MODULE__, :param)
    end
  end

  @doc "Declare a parameter, as proto_rune's own DSL does."
  defmacro param(key, type) do
    quote do
      @param {unquote(key), unquote(type)}
    end
  end

  @doc false
  def authenticated_query(session, method, schema, params) do
    if AtMcp.Network.direct_read?(method, session) do
      AtMcp.ATProto.ServiceAuth.query(session, method, schema, params)
    else
      proxied_query(session, method, schema, params)
    end
  end

  defp proxied_query(session, method, schema, params) do
    base_url = base_url(session)
    url = Path.join(base_url, method)
    query = Query.new(method, from: schema, base_url: base_url)

    with {:ok, query} <- Query.add_params(query, params),
         {:ok, headers, session} <- Session.authorization_headers(session, "GET", url) do
      Client.execute(
        %{
          query
          | headers:
              query.headers
              |> Map.merge(headers)
              |> Map.merge(AtMcp.Network.request_headers(method, session))
        },
        session: session
      )
    end
  end

  @doc false
  def authenticated_procedure(session, method, schema, params) do
    base_url = base_url(session)
    url = Path.join(base_url, method)
    proc = Procedure.new(method, from: schema, base_url: base_url)

    with {:ok, proc} <- Procedure.put_body(proc, params),
         {:ok, headers, session} <- Session.authorization_headers(session, "POST", url) do
      Client.execute(
        %{
          proc
          | headers:
              proc.headers
              |> Map.merge(headers)
              |> Map.merge(AtMcp.Network.request_headers(method, session))
        },
        session: session
      )
    end
  end

  @doc false
  # The account's own service, or the library's default. A session always
  # carries one in AtMcp, because every configured account names a service.
  def base_url(session), do: Session.service_url(session) || Config.default_base_url()

  # proto_rune derives a function name from the last segment of the NSID; same
  # rule, so a suffix produces the name the full NSID would have.
  defp function_name(suffix) do
    {_method, fun} = ProtoRune.XRPC.DSL.encode_method_name(suffix)
    fun
  end
end
