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

  # Each field path of each recording, and whether a summary reads it, worked
  # out once: a field reaches the summary when changing its value changes the
  # summary.
  setup_all do
    fields =
      for {kind, file} <- @fixtures,
          response = read(file),
          dropped = MapSet.new(dropped(kind, response)),
          path <- paths(response),
          do: %{kind: kind, path: path, read: path not in dropped}

    %{fields: fields}
  end

  test "every field the AppView returns reaches the summary or is listed as left out",
       %{fields: fields} do
    unlisted =
      for %{read: false, path: path, kind: kind} <- fields,
          not AtMcp.LeftOut.listed?(path),
          do: "#{kind}: #{path}"

    assert unlisted == [], """
    These fields of a recorded AppView response reach no summary, and AtMcp.LeftOut
    does not say why. Pass each one on, or list it there with its reason:

      #{Enum.join(Enum.uniq(unlisted), "\n  ")}
    """
  end

  # A TODO entry promises its whole subtree is waiting on an issue, so a field
  # under it that is read means the fix landed, or landed in part, and the
  # entry has to narrow. A reason entry may cover a subtree some of whose
  # fields are read (a raw record's embed, say, of which one uri is read); it
  # is stale only when everything it covers is read. An entry that covers
  # nothing recorded still documents a field these responses do not carry.
  test "no entry in AtMcp.LeftOut covers a field a summary reads, beyond what its kind allows",
       %{fields: fields} do
    covered =
      Enum.group_by(
        for(field <- fields, pattern = AtMcp.LeftOut.entry(field.path), do: {pattern, field}),
        &elem(&1, 0),
        &elem(&1, 1)
      )

    reasons = Map.new(AtMcp.LeftOut.entries())

    wrong =
      for {pattern, fields} <- covered,
          message = misfit(pattern, reasons[pattern], fields),
          do: message

    assert wrong == [], """
    Narrow or remove these AtMcp.LeftOut entries:

      #{Enum.join(wrong, "\n  ")}
    """
  end

  # Entries may nest, and the outer one decides (`AtMcp.LeftOut.entry/1`). Two
  # entries at the same depth would leave which reason applies to list order,
  # and an entry that every recorded field it covers takes from an outer one
  # says nothing.
  test "each recorded field has one deciding entry, and no entry is wholly shadowed",
       %{fields: fields} do
    matches = for %{path: path} <- fields, uniq: true, do: AtMcp.LeftOut.entries_for(path)

    ties =
      for [{a, depth}, {b, depth} | _] <- matches, uniq: true, do: "#{a} and #{b}"

    deciding = for [{pattern, _} | _] <- matches, into: MapSet.new(), do: pattern
    covering = for match <- matches, {pattern, _} <- match, into: MapSet.new(), do: pattern
    shadowed = MapSet.difference(covering, deciding) |> Enum.sort()

    assert ties == [], "These entries cover the same fields at the same depth: #{inspect(ties)}"

    assert shadowed == [],
           "These entries decide no recorded field; an outer entry always does: #{inspect(shadowed)}"
  end

  test "every entry in AtMcp.LeftOut gives a reason or the issue that will pass it on" do
    for {pattern, reason} <- AtMcp.LeftOut.entries() do
      assert (is_binary(reason) and reason != "") or match?({:todo, n} when is_integer(n), reason),
             "#{pattern} has no reason"
    end
  end

  # What is wrong with an entry, given the recorded fields it covers, or nil.
  defp misfit(pattern, reason, fields) do
    read = for %{read: true} = field <- fields, uniq: true, do: "#{field.kind}: #{field.path}"

    case {reason, read} do
      {_reason, []} ->
        nil

      {{:todo, issue}, read} ->
        "#{pattern} ({:todo, #{issue}}) covers fields that are read: #{Enum.join(read, ", ")}"

      {_reason, _read} ->
        if Enum.all?(fields, & &1.read), do: "#{pattern} covers only fields that are read"
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
