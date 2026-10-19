defmodule AtMcp.FieldCoverageTest do
  use ExUnit.Case, async: true

  # Recorded AppView responses, with identities, text and URLs replaced and
  # every key and value type kept (see test/fixtures/appview/README.md). Each
  # is read the way the backend reads it: decoded, then snakelized by the XRPC
  # client, then summarized.
  @fixtures [
    feed: "feed.json",
    thread: "thread.json",
    profile: "profile.json",
    likes: "likes.json",
    feeds: "feeds.json"
  ]

  @dir Path.expand("../fixtures/appview", __DIR__)

  # A field reaches the summary when changing its value changes the summary.
  # Every field of every recorded response either does, or is listed in
  # `AtMcp.LeftOut` with the reason it is not passed on.
  test "every field the AppView returns reaches the summary or is listed as left out" do
    unlisted =
      for {kind, file} <- @fixtures,
          response = read(file),
          path <- dropped(kind, response),
          not AtMcp.LeftOut.listed?(path),
          do: "#{kind}: #{path}"

    assert unlisted == [], """
    These fields of a recorded AppView response reach no summary, and AtMcp.LeftOut
    does not say why. Pass each one on, or list it there with its reason:

      #{Enum.join(Enum.uniq(unlisted), "\n  ")}
    """
  end

  # An entry is stale when every field it covers in the recorded responses is
  # read after all. An entry that covers nothing recorded still documents a
  # field the lexicon defines and these responses happen not to carry.
  test "no entry in AtMcp.LeftOut covers only fields a summary reads" do
    covered =
      for {kind, file} <- @fixtures,
          response = read(file),
          dropped = MapSet.new(dropped(kind, response)),
          path <- paths(response),
          pattern = AtMcp.LeftOut.entry(path),
          reduce: %{} do
        acc -> Map.update(acc, pattern, [path in dropped], &[path in dropped | &1])
      end

    stale = for {pattern, flags} <- covered, not Enum.any?(flags), do: pattern

    assert stale == [], """
    Every field these AtMcp.LeftOut entries cover is read by a summary. Remove them:

      #{Enum.join(stale, "\n  ")}
    """
  end

  test "every entry in AtMcp.LeftOut gives a reason or the issue that will pass it on" do
    for {pattern, reason} <- AtMcp.LeftOut.entries() do
      assert (is_binary(reason) and reason != "") or match?({:todo, n} when is_integer(n), reason),
             "#{pattern} has no reason"
    end
  end

  defp read(file), do: @dir |> Path.join(file) |> File.read!() |> Jason.decode!()

  defp summarize(kind, response) do
    {:ok, summary} =
      AtMcp.Effects.ProtoRune.summarize(kind, ProtoRune.Case.snakelize_enum(response))

    summary
  end

  # The scalar fields whose value the summary does not depend on. Every value
  # at one path is changed at once, so a path read anywhere counts as read.
  defp dropped(kind, response) do
    baseline = summarize(kind, response)

    for path <- paths(response),
        summarize(kind, perturb(response, String.split(path, "."))) == baseline,
        do: path
  end

  # Every path to a string, number or boolean, as the lexicon names it, with
  # `[]` for a list element.
  defp paths(response), do: response |> walk("") |> Enum.uniq() |> Enum.sort()

  defp walk(map, prefix) when is_map(map),
    do: Enum.flat_map(map, fn {key, value} -> walk(value, join(prefix, key)) end)

  defp walk(list, prefix) when is_list(list),
    do: Enum.flat_map(list, &walk(&1, prefix <> "[]"))

  defp walk(value, prefix) when is_binary(value) or is_number(value) or is_boolean(value),
    do: [prefix]

  defp walk(_null, _prefix), do: []

  defp join("", key), do: key
  defp join(prefix, key), do: prefix <> "." <> key

  defp perturb(value, []), do: change(value)

  defp perturb(map, [segment | rest]) when is_map(map) do
    key = String.replace(segment, "[]", "")
    depth = segment |> String.split("[]") |> length() |> Kernel.-(1)

    case Map.fetch(map, key) do
      {:ok, value} -> Map.put(map, key, each(value, depth, rest))
      :error -> map
    end
  end

  defp perturb(other, _path), do: other

  # `depth` is how many `[]` the segment carried: one per list to descend.
  defp each(value, 0, rest), do: perturb(value, rest)
  defp each(list, n, rest) when is_list(list), do: Enum.map(list, &each(&1, n - 1, rest))
  defp each(other, _n, _rest), do: other

  defp change(value) when is_binary(value), do: value <> "~"
  defp change(value) when is_boolean(value), do: not value
  defp change(value) when is_integer(value), do: value + 1
  defp change(value) when is_float(value), do: value + 1.0
  defp change(value), do: value
end
