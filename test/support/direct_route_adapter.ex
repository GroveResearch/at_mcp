defmodule AtMcp.TestDirectRouteAdapter do
  @moduledoc false
  # Only compiled in tests. Production Network URLs remain fixed HTTPS origins.
  def run(request) do
    request =
      if request.url.host == "api.delve.town" do
        origin = URI.parse(System.fetch_env!("TEST_APPVIEW_ORIGIN"))

        %{
          request
          | url: %{request.url | scheme: origin.scheme, host: origin.host, port: origin.port}
        }
      else
        request
      end

    Req.Finch.run(request)
  end
end
