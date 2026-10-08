defmodule AtMcp.PostImages do
  @moduledoc """
  The pictures on one post, as MCP image content, for a client whose model
  reads images.

  A post read carries each image as metadata: alt text and the AppView's
  `thumb` and `fullsize` URLs (`AtMcp.Post`). This fetches the `fullsize` copy
  of each image the AppView returned for that one post, and nothing else:

  - only the URLs in the post's hydrated view, never a URL built from a CID and
    never one the caller supplies;
  - with no account credential and no redirect followed, so the request goes
    exactly where the AppView pointed and carries nothing of the account;
  - only an `image/*` answer, at most `max_bytes/0` bytes each, and every image
    within `fetch_ms/0` of the first request.

  An image that cannot be shown keeps its place by index, with the reason, so
  an agent is never handed fewer pictures than the post has without being told.
  Indexes count from 1, in the post's order.
  """

  @default_max_bytes 2_000_000
  @default_fetch_ms 10_000

  @doc """
  The most bytes one image may have, from `AT_MCP_IMAGE_MAX_BYTES`
  (`post_images: [max_bytes: ...]`); #{@default_max_bytes} by default.
  """
  def max_bytes, do: setting(:max_bytes, @default_max_bytes)

  @doc """
  How long, in milliseconds, all of one post's images may take together, from
  `AT_MCP_IMAGE_FETCH_SECONDS` (`post_images: [fetch_ms: ...]`);
  #{@default_fetch_ms} by default.
  """
  def fetch_ms, do: setting(:fetch_ms, @default_fetch_ms)

  defp setting(key, default),
    do: :at_mcp |> Application.get_env(:post_images, []) |> Keyword.get(key, default)

  @doc """
  The tool result for the post at `uri` whose summary is `post`: one text block
  listing each image, then one image block for each image that could be
  fetched, in the post's order. The text block is also the structured content.
  """
  def result(uri, post) do
    images = List.wrap(Map.get(post, :images))
    fetched = fetch(images)

    listed =
      images
      |> Enum.zip(fetched)
      |> Enum.with_index(1)
      |> Enum.map(fn {{image, outcome}, index} -> entry(index, image, outcome) end)

    data = %{uri: uri, count: length(images), images: listed}
    json = Jason.encode!(data)

    blocks =
      for {:ok, mime_type, bytes} <- fetched,
          do: %{type: "image", data: Base.encode64(bytes), mimeType: mime_type}

    %{
      content: [%{type: "text", text: json} | blocks],
      structuredContent: Jason.decode!(json)
    }
  end

  defp entry(index, image, {:ok, mime_type, bytes}),
    do: %{
      index: index,
      alt: alt(image),
      status: "attached",
      mime_type: mime_type,
      bytes: byte_size(bytes)
    }

  defp entry(index, image, {:error, reason}),
    do: %{index: index, alt: alt(image), status: "unavailable", reason: reason(reason)}

  defp alt(image), do: Map.get(image, :alt) || ""

  defp reason(:no_url),
    do: "the post's view carried no full-size URL for this image, so it was not fetched"

  defp reason(:timeout),
    do: "the image host did not answer within #{div(fetch_ms() + 999, 1000)} seconds"

  defp reason(:too_large), do: "the image is larger than #{max_bytes()} bytes"
  defp reason({:not_image, ""}), do: "the image host's answer did not say it was an image"
  defp reason({:not_image, type}), do: "the image host answered with #{type}, not an image"
  defp reason({:status, status}), do: "the image host answered HTTP #{status}"
  defp reason(:unreachable), do: "the image host could not be reached"

  # Each image is its own request, all at once, and the whole set is bounded by
  # one deadline: whatever has not answered by then is stopped and reported.
  defp fetch(images) do
    budget = fetch_ms()
    limit = max_bytes()

    tasks =
      Enum.map(images, fn image ->
        case url(image) do
          nil -> {:error, :no_url}
          url -> Task.async(fn -> get(url, limit, budget) end)
        end
      end)

    running = for %Task{} = task <- tasks, do: task
    answers = running |> Task.yield_many(timeout: budget, on_timeout: :kill_task) |> Map.new()

    Enum.map(tasks, fn
      %Task{} = task ->
        case Map.fetch!(answers, task) do
          {:ok, outcome} -> outcome
          _ -> {:error, :timeout}
        end

      refused ->
        refused
    end)
  end

  defp url(image) do
    with url when is_binary(url) <- Map.get(image, :fullsize),
         %URI{scheme: scheme, host: host}
         when scheme in ["http", "https"] and host not in [nil, ""] <-
           URI.parse(url) do
      url
    else
      _ -> nil
    end
  end

  # No headers of the account's, no redirect, no retry, no decompression: the
  # bytes as the host served them, or a reason they are not here.
  defp get(url, limit, budget) do
    response =
      Req.get(url,
        redirect: false,
        retry: false,
        compressed: false,
        decode_body: false,
        receive_timeout: budget,
        into: fn {:data, data}, {request, response} -> collect(data, request, response, limit) end
      )

    case response do
      {:ok, %Req.Response{private: %{at_mcp_refused: reason}}} ->
        {:error, reason}

      {:ok, %Req.Response{status: 200} = response} ->
        case image_type(response) do
          {:ok, type} -> {:ok, type, IO.iodata_to_binary(response.body)}
          {:error, _} = refused -> refused
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:status, status}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, _} ->
        {:error, :unreachable}
    end
  end

  # Called once the headers are in, for each part of the body: the type and
  # the size are judged before more of it is read.
  defp collect(data, request, response, limit) do
    body = if is_list(response.body), do: response.body, else: []
    size = IO.iodata_length(body) + byte_size(data)

    cond do
      response.status != 200 ->
        {:cont, {request, response}}

      match?({:error, _}, image_type(response)) ->
        {:error, reason} = image_type(response)
        {:halt, {request, Req.Response.put_private(response, :at_mcp_refused, reason)}}

      size > limit or declared_length(response) > limit ->
        {:halt, {request, Req.Response.put_private(response, :at_mcp_refused, :too_large)}}

      true ->
        {:cont, {request, %{response | body: [body | data]}}}
    end
  end

  defp image_type(response) do
    type =
      case Req.Response.get_header(response, "content-type") do
        [value | _] -> value |> String.split(";") |> hd() |> String.trim() |> String.downcase()
        [] -> ""
      end

    if String.starts_with?(type, "image/"), do: {:ok, type}, else: {:error, {:not_image, type}}
  end

  defp declared_length(response) do
    with [value | _] <- Req.Response.get_header(response, "content-length"),
         {length, ""} <- Integer.parse(value) do
      length
    else
      _ -> 0
    end
  end
end
