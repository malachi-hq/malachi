defmodule Malachi.Release.Post do
  @moduledoc """
  Builds the draft of a release's blog post from the release's data (issue #373). `mix malachi.release.post`
  writes it to `site/blog/`.

  The draft holds data and placeholders, never prose: the maintainer writes every public text (NLnet's
  generative AI policy, #303). What it holds:

    * front matter: the title (`Malachi vX.Y.Z`), the date of the release's tag, the versions, the author, and a
      `<!-- narrative -->` placeholder for the summary;
    * `<!-- narrative -->` placeholders where the maintainer writes, and the release highlights from the
      changelog as a `malachi-seed` block to draw on; `Malachi.Site.Blog` refuses to publish either;
    * the measurements: each published load test and certification of the release's code
      (`Malachi.Release.Measurements`) beside the previous release's, with the hardware and commit of each, the
      run's own noise estimate, and the change between the two only when both runs recorded the same CPU model
      and core count. The Elixir load test records the architecture rather than the CPU model, so it never shows
      a change. No change is called a gain or a regression: runs on shared CI runners differ by more than that;
    * for a minor or major release, charts of the two produce rates over the last 8 releases;
    * the upgrade notes and the changes, read from `CHANGELOG.md`, which holds what the release notes held.

  A patch release, or consecutive patch releases of one minor version given as a range (`v0.28.1..v0.28.2`),
  takes the short form: the numbers, the changes and one placeholder.
  """

  alias Malachi.Release.Measurements
  alias Malachi.ResultsText

  @tag ~r/\Av(\d+)\.(\d+)\.(\d+)\z/
  @chart_releases 8

  # The measurements a post reports, in the order of its table. `kind` decides what is read from the file.
  # `cpu_model` says whether the run's meta.hardware.cpu names the CPU model: the Elixir generator records the
  # architecture there (`x86_64-pc-linux-gnu`, Malachi.Loadtest), the same on every runner, so two of its runs
  # cannot be told apart by hardware and are never compared.
  @measured [
    %{
      file: "loadtest-node.json",
      kind: :rate,
      label: "Produce rate, Node.js load test",
      chart: "node-produce-rate",
      cpu_model: true
    },
    %{
      file: "loadtest-elixir.json",
      kind: :rate,
      label: "Produce rate, Elixir load test",
      chart: "elixir-produce-rate",
      cpu_model: false
    },
    %{file: "chaos-node.json", kind: :chaos, label: "Chaos certification, node faults"},
    %{file: "chaos-upgrade.json", kind: :chaos, label: "Chaos certification, rolling upgrade"}
  ]

  @typedoc "A draft: its file name under site/blog and its Markdown."
  @type draft :: %{file: String.t(), versions: [String.t()], markdown: String.t()}

  @doc """
  The release tags a post covers, oldest first, from `vX.Y.Z` or `vA..vB`. A range holds consecutive patch
  releases of one minor version, so a minor release always has a post of its own.
  """
  @spec releases(String.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, String.t()}
  def releases(spec, tags) do
    with {:ok, first, last} <- parse_spec(spec),
         :ok <- known(first, tags),
         :ok <- known(last, tags) do
      covered = tags |> Enum.drop_while(&(&1 != first)) |> Enum.take_while(&(&1 != last))
      covered = covered ++ [last]
      range_rule(first, last, covered)
    end
  end

  defp parse_spec(spec) do
    case String.split(spec, "..") do
      [one] -> if Regex.match?(@tag, one), do: {:ok, one, one}, else: spec_error(spec)
      [a, b] -> if Regex.match?(@tag, a) and Regex.match?(@tag, b), do: {:ok, a, b}, else: spec_error(spec)
      _ -> spec_error(spec)
    end
  end

  defp spec_error(spec), do: {:error, "#{inspect(spec)} is not a release (vX.Y.Z) or a range of them (vA..vB)"}

  defp known(tag, tags) do
    if tag in tags, do: :ok, else: {:error, "#{tag} is not a release tag here"}
  end

  defp range_rule(tag, tag, [tag]), do: {:ok, [tag]}

  defp range_rule(first, last, covered) do
    {fa, fb, _} = parts(first)

    cond do
      parts(last) <= parts(first) ->
        {:error, "#{first}..#{last} runs backwards; give the older release first"}

      Enum.any?(covered, fn tag ->
        {a, b, _} = parts(tag)
        {a, b} != {fa, fb}
      end) ->
        {:error, "#{first}..#{last} spans more than one minor version; a range holds patch releases of one"}

      Enum.any?(covered, fn tag -> elem(parts(tag), 2) == 0 end) ->
        {:error, "#{first}..#{last} holds a minor release, which has a post of its own"}

      true ->
        {:ok, covered}
    end
  end

  defp parts(tag) do
    [_, a, b, c] = Regex.run(@tag, tag)
    {String.to_integer(a), String.to_integer(b), String.to_integer(c)}
  end

  @doc """
  Builds the draft for `releases` (from `releases/2`) in the repository at `repo`, reading `CHANGELOG.md` from
  its working tree. Fails when the changelog has no section for one of them.
  """
  @spec build(Path.t(), [String.t()], [String.t()], keyword()) :: {:ok, draft()} | {:error, String.t()}
  def build(repo, releases, tags, opts) do
    newest = List.last(releases)
    previous = tags |> Enum.take_while(&(&1 != hd(releases))) |> List.last()
    date = Measurements.tag_date(repo, newest)

    with {:ok, sections} <- changelog_sections(repo, releases) do
      short? = Enum.all?(releases, &(elem(parts(&1), 2) > 0))
      versions = Enum.map(releases, &String.trim_leading(&1, "v"))

      body =
        [
          front_matter(releases, versions, date, opts[:author]),
          "<!-- narrative -->\n",
          seed(sections),
          measurements(repo, newest, previous, short?),
          if(short?, do: "", else: charts(repo, newest, tags)),
          upgrading(sections),
          changes(sections)
        ]
        |> Enum.reject(&(&1 == ""))
        |> Enum.map_join("\n", &String.trim_trailing/1)
        |> Kernel.<>("\n")

      {:ok, %{file: "#{date}-#{slug(releases)}.md", versions: versions, markdown: body}}
    end
  end

  defp slug([one]), do: String.replace(one, ".", "-")
  defp slug(releases), do: "#{slug([hd(releases)])}-to-#{slug([List.last(releases)])}"

  defp front_matter(releases, versions, date, author) do
    title =
      case releases do
        [one] -> "Malachi #{one}"
        _ -> "Malachi #{hd(releases)} to #{List.last(releases)}"
      end

    """
    ---
    title: #{title}
    date: #{date}
    versions: [#{Enum.join(versions, ", ")}]
    author: #{author}
    summary: <!-- narrative: one sentence for the index and the link previews -->
    ---
    """
  end

  # The headings release-notes.sh writes in a release's section. Only these split it: a `### ` line inside a
  # pull request's highlights or upgrade notes is part of that text.
  @changelog_parts ~w(Highlights Upgrading Features Fixes Performance Dependencies Documentation Other)

  # The release's section of the changelog, split into its parts: {heading, text}.
  defp changelog_sections(repo, releases) do
    case File.read(Path.join(repo, "CHANGELOG.md")) do
      {:ok, text} ->
        releases
        |> Enum.reverse()
        |> Enum.reduce_while({:ok, []}, fn tag, {:ok, acc} ->
          case section(text, tag) do
            nil -> {:halt, {:error, "CHANGELOG.md has no section for #{tag}; the release's bump commit writes it"}}
            parts -> {:cont, {:ok, acc ++ [{tag, parts}]}}
          end
        end)

      {:error, reason} ->
        {:error, "CHANGELOG.md cannot be read (#{:file.format_error(reason)})"}
    end
  end

  defp section(text, tag) do
    heading = ~r/^## #{Regex.escape(tag)} \(/m

    case Regex.split(heading, text, parts: 2) do
      [_, rest] ->
        rest |> String.split(~r/^## v/m, parts: 2) |> hd() |> changelog_parts()

      [_] ->
        nil
    end
  end

  defp changelog_parts(body) do
    {parts, current} =
      body
      |> String.split("\n")
      |> Enum.reduce({[], nil}, fn line, {parts, current} ->
        case Regex.run(~r/\A### (\w+)\s*\z/, line) do
          [_, name] when name in @changelog_parts -> {push_part(parts, current), {name, []}}
          _ when current == nil -> {parts, nil}
          _ -> {parts, {elem(current, 0), [line | elem(current, 1)]}}
        end
      end)

    parts |> push_part(current) |> Enum.reverse()
  end

  defp push_part(parts, nil), do: parts

  defp push_part(parts, {name, lines}),
    do: [{name, lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()} | parts]

  defp seed(sections) do
    case for({_tag, parts} <- sections, {"Highlights", text} <- parts, do: text) do
      [] ->
        ""

      texts ->
        text = Enum.join(texts, "\n\n")
        fence = seed_fence(text)
        "#{fence}malachi-seed\n#{text}\n#{fence}\n"
    end
  end

  # A fence longer than any run of backticks in the highlights, so a code example a pull request put there
  # stays inside the seed instead of closing it.
  defp seed_fence(text) do
    longest = ~r/`+/ |> Regex.scan(text) |> List.flatten() |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end)
    String.duplicate("`", max(3, longest + 1))
  end

  defp upgrading(sections) do
    case for({tag, parts} <- sections, {"Upgrading", text} <- parts, do: {tag, text}) do
      [] -> ""
      [{_tag, text}] -> "## Upgrading\n\n#{text}\n"
      many -> "## Upgrading\n\n" <> Enum.map_join(many, "\n", fn {tag, text} -> "### #{tag}\n\n#{text}\n" end)
    end
  end

  defp changes([{_tag, parts}]), do: "## Changes\n\n" <> change_parts(parts, "###")

  defp changes(sections) do
    "## Changes\n\n" <>
      Enum.map_join(sections, "\n", fn {tag, parts} -> "### #{tag}\n\n" <> change_parts(parts, "####") end)
  end

  defp change_parts(parts, level) do
    case for {name, text} <- parts, name not in ["Highlights", "Upgrading"], do: "#{level} #{name}\n\n#{text}\n" do
      [] -> "No user-facing changes.\n"
      listed -> Enum.join(listed, "\n")
    end
  end

  defp measurements(repo, newest, previous, short?) do
    found =
      for m <- @measured do
        current = Measurements.find(repo, m.file, newest)
        before = if previous, do: Measurements.find(repo, m.file, previous), else: :none
        {m, current, before}
      end

    rows = Enum.map(found, &row(&1, newest, previous))
    prev_label = previous || "previous"

    table =
      "| Measurement | #{prev_label} | #{newest} | Change |\n|---|--:|--:|---|\n" <> Enum.join(rows, "\n") <> "\n"

    narrative = if short?, do: "", else: "<!-- narrative: what the numbers below say -->\n\n"

    "## Measurements\n\n" <>
      narrative <>
      table <>
      "\n" <>
      provenance(found, newest, previous) <>
      "\n" <> noise(found) <> "\n"
  end

  defp row({%{kind: :rate, label: label} = m, current, before}, _newest, _previous) do
    "| #{label} (records/s) | #{rate_cell(before)} | #{rate_cell(current)} | #{change(m, current, before)} |"
  end

  defp row({%{kind: :chaos, label: label}, current, before}, _newest, _previous) do
    "| #{label} | #{chaos_cell(before)} | #{chaos_cell(current)} | n/a |"
  end

  defp rate_cell(:none), do: "not measured"

  defp rate_cell({:ok, %{data: data}}) do
    case data["records_per_s"] do
      rate when is_number(rate) -> ResultsText.group_digits(round(rate)) <> lower_bound(data)
      _ -> "no clean peak"
    end
  end

  defp lower_bound(%{"lower_bound_reasons" => [_ | _]}), do: " (lower bound)"
  defp lower_bound(%{"peak_at_ladder_limit" => true}), do: " (lower bound)"
  defp lower_bound(_data), do: ""

  defp chaos_cell(:none), do: "not measured"

  defp chaos_cell({:ok, %{data: data}}) do
    verdict = cell(data["verdict"] || "not recorded")

    case get_in(data, ["invariants", "acked_writes"]) do
      writes when is_integer(writes) -> "#{verdict}, #{ResultsText.group_digits(writes)} acked writes checked"
      _ -> verdict
    end
  end

  # The change between two runs, only when both measured a clean peak on a CPU model and core count both
  # recorded and the same: a number from another machine says nothing about the code. Never called a gain or a
  # regression (see the moduledoc).
  defp change(%{cpu_model: false}, {:ok, _}, {:ok, _}), do: "n/a: the run records no CPU model"

  defp change(_m, {:ok, %{data: new}}, {:ok, %{data: old}}) do
    cond do
      not (is_number(new["records_per_s"]) and is_number(old["records_per_s"]) and old["records_per_s"] > 0) ->
        "n/a"

      nil in Tuple.to_list(hardware_key(new)) or nil in Tuple.to_list(hardware_key(old)) ->
        "not comparable: hardware not recorded"

      hardware_key(new) != hardware_key(old) ->
        "not comparable: different hardware"

      true ->
        pct = (new["records_per_s"] - old["records_per_s"]) / old["records_per_s"] * 100
        sign = if pct >= 0, do: "+", else: ""
        "#{sign}#{:erlang.float_to_binary(pct, decimals: 1)}%"
    end
  end

  defp change(_m, _current, _before), do: "n/a"

  defp hardware_key(data) do
    hw = get_in(data, ["meta", "hardware"]) || %{}
    {hw["cpu"], hw["cores"]}
  end

  defp provenance(found, newest, previous) do
    lines =
      for {m, current, before} <- found,
          {tag, result} <- [{newest, current}, {previous, before}],
          tag != nil,
          {:ok, %{data: data, git_ref: ref}} <- [result] do
        "- #{m.label}, #{tag}: commit `#{cell(ref)}`, #{hardware_text(data)}."
      end

    case lines do
      [] -> "No published run measured the code of #{newest}#{if previous, do: " or #{previous}", else: ""}.\n"
      _ -> "Measured on:\n\n" <> Enum.join(lines, "\n") <> "\n"
    end
  end

  defp hardware_text(data) do
    hw = get_in(data, ["meta", "hardware"]) || %{}

    cores =
      case hw["cores"] do
        1 -> "1 core"
        nil -> nil
        n -> "#{n} cores"
      end

    [hw["cpu"], cores, hw["os"]]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&cell(to_string(&1)))
    |> case do
      [] -> "hardware not recorded"
      parts -> Enum.join(parts, ", ")
    end
  end

  defp noise(found) do
    aa =
      case Enum.find(found, fn {m, current, _} -> m.kind == :rate and match?({:ok, _}, current) end) do
        {m, {:ok, %{data: data}}, _} -> "#{m.label}: #{ResultsText.aa_sentence(data["sweep"], "releases")} "
        nil -> ""
      end

    aa <>
      ResultsText.cross_run_sentence() <>
      " A change between releases is shown only for runs that recorded the same CPU model and core count.\n"
  end

  # A text from a published file, made safe for a Markdown table cell: one line, no column separator.
  defp cell(text), do: text |> to_string() |> String.replace(~r/[\r\n]+/, " ") |> String.replace("|", "\\|")

  defp charts(repo, newest, tags) do
    window = tags |> Enum.take_while(&(&1 != newest)) |> Enum.concat([newest]) |> Enum.take(-@chart_releases)

    rates =
      for m <- @measured, m.kind == :rate do
        points =
          Enum.map(window, fn tag ->
            value =
              case Measurements.find(repo, m.file, tag) do
                {:ok, %{data: %{"records_per_s" => rate}}} when is_number(rate) -> round(rate)
                _ -> nil
              end

            {tag, value}
          end)

        "```malachi-chart\n#{chart_json(m.chart, m.label, "records/s", points)}\n```\n"
      end

    Enum.join(rates, "\n")
  end

  @doc "A chart block's JSON, keys in a fixed order so the text (and the image's hash) is stable."
  @spec chart_json(String.t(), String.t(), String.t(), [{String.t(), number() | nil}]) :: String.t()
  def chart_json(name, title, unit, points) do
    encoded =
      Enum.map_join(points, ", ", fn {label, value} ->
        ~s({"label": #{JSON.encode!(label)}, "value": #{JSON.encode!(value)}})
      end)

    ~s({"name": #{JSON.encode!(name)}, "title": #{JSON.encode!(title)}, "unit": #{JSON.encode!(unit)}, "points": [#{encoded}]})
  end
end
