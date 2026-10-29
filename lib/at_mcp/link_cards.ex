defmodule AtMcp.LinkCards do
  @moduledoc """
  A link card's title, description and thumbnail, looked up as the app's
  composer looks them up (social-app 62b95002, `src/lib/link-meta/link-meta.ts`
  and `src/lib/api/resolve.ts`). The network's card service
  (`AtMcp.Network.card_service/0`) reads the page and answers its title, its
  description and an image it serves itself; that image becomes the card's
  thumbnail. at_mcp never fetches the page, nor any host but the card service.

  - A network with no card service looks nothing up.
  - A link into the network's own app, other than a starter pack, and a link
    whose path names an image are not looked up, as the app does not.
  - Requests carry no account credential and follow no redirect. The whole
    lookup has its own wall-clock budget, `lookup_ms/0` (#{3_000} ms): a card
    is optional, so a slow card service never holds a post past it.
  - A lookup that fails or runs out of time leaves the card as the app writes
    it then: the url, with no title or description.
  - A title is cut at #{300} characters and a description at #{1_000}. The
    lexicon sets no limit; the page's author would otherwise choose how much
    text goes into a record under the account.
  - A thumbnail is an `image/*` answer of at most #{1_000_000} bytes, the
    lexicon's `maxSize` for an external embed's `thumb`. The app resizes a
    larger one; at_mcp leaves it off.

  Each outcome other than a full card comes with a note saying what is
  missing and why.
  """

  # `app.bsky.embed.external#external`'s `thumb.maxSize`, the same on both
  # networks' lexicons.
  @thumb_max_bytes 1_000_000
  @lookup_ms 3_000
  @title_chars 300
  @description_chars 1_000

  @doc "How long one card's lookup may take in all, in milliseconds."
  def lookup_ms, do: @lookup_ms

  @image_path ~r/\.(?:apng|avif|bmp|gif|heic|heif|ico|jpe?g|jxl|png|svgz?|tiff?|webp)$/i

  @doc """
  Whether a card for `url` is looked up on this network: a card service is
  configured, and the url is neither the network's own app (bar a starter
  pack) nor an image.
  """
  def looked_up?(url) do
    is_binary(AtMcp.Network.card_service()) and not own_app?(url) and not image?(url)
  end

  @doc """
  The card for `url`: `%{url, title, description, thumb, note}`, where `thumb`
  is `%{data, mime_type}` or nil and `note` says what is missing and why, or
  is nil for a card with all three.
  """
  def lookup(url, budget_ms \\ @lookup_ms) do
    card = %{url: url, title: "", description: "", thumb: nil, note: nil}

    # Req's timeouts bound each read, not the whole answer: a service that
    # sends a byte at a time would hold the lookup as long as it liked. The
    # task is stopped at the budget, whatever it is waiting for.
    task = Task.async(fn -> look_up(card, System.monotonic_time(:millisecond) + budget_ms) end)

    case Task.yield(task, budget_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, card} ->
        card

      _ ->
        %{
          card
          | note:
              "The card shows only the link: the card service did not answer within #{budget_ms} ms."
        }
    end
  end

  defp look_up(card, deadline) do
    case extract(card.url, deadline) do
      {:ok, meta} ->
        card = %{
          card
          | title: meta["title"] |> string() |> String.slice(0, @title_chars),
            description: meta["description"] |> string() |> String.slice(0, @description_chars)
        }

        case string(meta["image"]) do
          "" ->
            card

          image ->
            case thumb(image, deadline) do
              {:ok, thumb} -> %{card | thumb: thumb}
              {:error, reason} -> %{card | note: "The card has no image: #{reason}."}
            end
        end

      {:error, reason} ->
        %{card | note: "The card shows only the link: #{reason}."}
    end
  end

  defp extract(url, deadline) do
    service = AtMcp.Network.card_service()

    case get(service <> "?url=" <> URI.encode_www_form(url), deadline, 200_000) do
      {:ok, _type, body} ->
        case Jason.decode(body) do
          {:ok, %{"error" => ""} = meta} ->
            {:ok, meta}

          {:ok, %{"error" => error}} when is_binary(error) ->
            {:error, "the card service could not read the page (#{error})"}

          _ ->
            {:error, "the card service's answer could not be read"}
        end

      {:error, reason} ->
        {:error, "the card service #{reason}"}
    end
  end

  # The image the card service names, which it serves through itself.
  defp thumb(image, deadline) do
    if same_origin?(image, AtMcp.Network.card_service()) do
      case get(image, deadline, @thumb_max_bytes) do
        {:ok, "image/" <> _ = type, data} -> {:ok, %{data: data, mime_type: type}}
        {:ok, type, _} -> {:error, "the card service's image is #{type}, not an image"}
        {:error, :too_large} -> {:error, "the page's image is over #{@thumb_max_bytes} bytes"}
        {:error, reason} -> {:error, "its image #{reason}"}
      end
    else
      {:error, "the card service named an image it does not serve"}
    end
  end

  # No account header, no redirect, no retry, no decompression, at most
  # `limit` bytes, and what is left of the time.
  defp get(url, deadline, limit) do
    budget = max(deadline - System.monotonic_time(:millisecond), 0)

    response =
      Req.get(url,
        redirect: false,
        retry: false,
        compressed: false,
        decode_body: false,
        receive_timeout: budget,
        connect_options: [timeout: budget],
        into: fn {:data, data}, {request, response} -> collect(data, request, response, limit) end
      )

    case response do
      {:ok, %Req.Response{private: %{at_mcp_too_large: true}}} ->
        {:error, :too_large}

      {:ok, %Req.Response{status: 200} = response} ->
        {:ok, content_type(response), IO.iodata_to_binary(response.body)}

      {:ok, %Req.Response{status: status}} ->
        {:error, "answered HTTP #{status}"}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, "did not answer in time"}

      {:error, _} ->
        {:error, "could not be reached"}
    end
  end

  defp collect(data, request, response, limit) do
    body = if is_list(response.body), do: response.body, else: []

    if IO.iodata_length(body) + byte_size(data) > limit,
      do: {:halt, {request, Req.Response.put_private(response, :at_mcp_too_large, true)}},
      else: {:cont, {request, %{response | body: [body | data]}}}
  end

  defp content_type(response) do
    case Req.Response.get_header(response, "content-type") do
      [value | _] -> value |> String.split(";") |> hd() |> String.trim() |> String.downcase()
      [] -> ""
    end
  end

  defp string(value) when is_binary(value), do: value
  defp string(_), do: ""

  defp own_app?(url) do
    %URI{host: host, path: path} = URI.parse(url)
    %URI{host: app} = URI.parse(AtMcp.Network.web_origin())

    host in [app, "www." <> app] and
      not String.starts_with?(path || "", ["/starter-pack/", "/start/"])
  end

  defp image?(url), do: Regex.match?(@image_path, URI.parse(url).path || "")

  # Scheme, host and port, so the service cannot send the fetch to plain HTTP
  # or to another port of its host.
  defp same_origin?(a, b), do: origin(a) == origin(b)

  defp origin(url) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(url)
    {scheme, host, port}
  end
end
