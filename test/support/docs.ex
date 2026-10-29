defmodule AtMcp.Test.Docs do
  @moduledoc "Reading the examples a documentation page gives, to run them as written."

  @doc "The fenced blocks of `language` in a page, in order."
  def blocks(page, language) do
    ~r/^```#{language}\n(.*?)^```$/ms
    |> Regex.scan(File.read!(page), capture: :all_but_first)
    |> Enum.map(&hd/1)
  end
end
