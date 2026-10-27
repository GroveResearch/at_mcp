defmodule AtMcp.PolicyPage do
  @moduledoc """
  One of a network's published policy pages, such as delve.town's Community
  Rules or AI Agent Policy, read as text (`get_policy`).

  delve.town publishes no API or JSON for these pages. Each page is the app's
  HTML shell with the page's text in one `<main id="public-reading">` element,
  for a reader without JavaScript, in a few plain tags: headings, paragraphs,
  lists and links (checked 2026-10-27). This reads that element and nothing
  else of the page: `#` before the title, `##` before a section heading, `-`
  before a list item, a blank line between blocks, and each link's address,
  made absolute, in angle brackets after its words unless the words are the
  address. The site's navigation and its note for readers without
  JavaScript are left out.

  The limit is the page's shape. A page without that element is `:unreadable`,
  and a tag this does not know keeps its text and loses its markup, so a change
  to the page shows as a failure or as plainer text, never as different words.

  The request carries nothing of the account, follows no redirect, and reads
  at most `@max_bytes` bytes within `@timeout_ms`.
  """

  alias AtMcp.Effects.Failure

  @max_bytes 1_000_000
  @timeout_ms 10_000

  @doc "The page at `url`, as `%{title: title, text: text}`, or the failure."
  def read(url) when is_binary(url) do
    response =
      Req.get(url,
        redirect: false,
        retry: false,
        decode_body: false,
        receive_timeout: @timeout_ms,
        into: fn {:data, data}, {request, response} -> collect(data, request, response) end
      )

    # Each failure names the page in its detail, so it is reported as the
    # site's answer (`AtMcp.MCP.Tools.respond/2`).
    page = {:web_page, url}

    case response do
      {:ok, %Req.Response{private: %{at_mcp_too_large: true}}} ->
        {:error, Failure.new(:unreadable, detail: page)}

      {:ok, %Req.Response{status: 200, body: body}} ->
        case parse(IO.iodata_to_binary(body), url) do
          {:ok, read} -> {:ok, read}
          :error -> {:error, Failure.new(:unreadable, detail: page)}
        end

      {:ok, %Req.Response{status: status}} when status >= 500 ->
        {:error, Failure.new(:indeterminate, status: status, detail: page)}

      {:ok, %Req.Response{status: status}} ->
        {:error, Failure.new(:refused, status: status, detail: page)}

      {:error, _reason} ->
        {:error, Failure.new(:indeterminate, detail: page)}
    end
  end

  defp collect(data, request, response) do
    body = if is_list(response.body), do: response.body, else: []

    if IO.iodata_length(body) + byte_size(data) > @max_bytes,
      do: {:halt, {request, Req.Response.put_private(response, :at_mcp_too_large, true)}},
      else: {:cont, {request, %{response | body: [body | data]}}}
  end

  @main ~r{<main\b[^>]*\bid="public-reading"[^>]*>(.*?)</main>}is

  @doc """
  The title and text of a page's `<main id="public-reading">` element, links
  made absolute against `url`; `:error` when it has none.
  """
  def parse(html, url) when is_binary(html) do
    with [_, main] <- Regex.run(@main, html),
         text when text != "" <- text(main, url) do
      title =
        case Regex.run(~r{\A# (.*)$}m, text) do
          [_, title] -> title
          nil -> nil
        end

      {:ok, %{title: title, text: text}}
    else
      _ -> :error
    end
  end

  # A link's address is held between two private-use characters until every
  # tag is gone, so its angle brackets are not taken for a tag.
  @open "\u{E000}"
  @close "\u{E001}"

  defp text(main, url) do
    main
    |> String.replace([@open, @close], "")
    |> String.replace(~r{<(nav|noscript|script|style)\b.*?</\1>}is, "")
    |> String.replace(~r/\s+/u, " ")
    |> then(
      &Regex.replace(~r{<a\b[^>]*?\bhref="([^"]*)"[^>]*>(.*?)</a>}is, &1, fn _, href, words ->
        link(decode(href), words, url)
      end)
    )
    |> then(
      &Regex.replace(~r{<h([1-6])\b[^>]*>}i, &1, fn _, level ->
        "\n\n" <> String.duplicate("#", String.to_integer(level)) <> " "
      end)
    )
    |> String.replace(~r{<li\b[^>]*>}i, "\n- ")
    |> String.replace(~r{<br\b[^>]*>}i, "\n")
    |> String.replace(~r{</?(p|div|section|ul|ol|blockquote|table|tr)\b[^>]*>}i, "\n\n")
    |> String.replace(~r{<[^>]*>}, "")
    |> decode()
    |> String.replace(@open, "<")
    |> String.replace(@close, ">")
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.join("\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  # A link's words, then its address unless the words already are it.
  defp link(href, words, base) do
    address = base |> URI.merge(href) |> URI.to_string()
    plain = words |> String.replace(~r{<[^>]*>}, "") |> decode() |> String.trim()

    if plain in [address, href, String.replace_prefix(href, "mailto:", "")],
      do: words,
      else: words <> " " <> @open <> address <> @close
  end

  @entities %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "nbsp" => " "
  }

  defp decode(text) do
    Regex.replace(~r/&(#x[0-9a-f]+|#[0-9]+|[a-z]+);/i, text, fn whole, entity ->
      case entity do
        "#x" <> hex -> codepoint(Integer.parse(hex, 16), whole)
        "#X" <> hex -> codepoint(Integer.parse(hex, 16), whole)
        "#" <> dec -> codepoint(Integer.parse(dec), whole)
        name -> Map.get(@entities, name, whole)
      end
    end)
  end

  defp codepoint({n, ""}, whole) do
    <<n::utf8>>
  rescue
    ArgumentError -> whole
  end

  defp codepoint(_other, whole), do: whole
end
