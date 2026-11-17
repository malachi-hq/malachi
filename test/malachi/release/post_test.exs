defmodule Malachi.Release.PostTest do
  # The release post generator (#373) against a git history built per test, shaped as main's is: a merge, the
  # release's bump commit and tag, then the results commit that Publish results pushes after them, whose
  # measurement names the merge it measured (meta.git_ref) and still carries the previous version.
  use ExUnit.Case, async: true

  alias Malachi.Release.Measurements
  alias Malachi.Release.Post
  alias Malachi.Site.Blog
  alias Malachi.Site.Chart
  alias Malachi.Test.TmpDir

  @moduletag :tmp_dir

  @hw_a %{"cpu" => "AMD EPYC 9V74", "cores" => 4, "os" => "linux 7.0.0"}
  @hw_b %{"cpu" => "Intel Xeon 8370C", "cores" => 4, "os" => "linux 7.0.0"}

  setup %{tmp_dir: repo} do
    git!(repo, ["init", "-q", "-b", "main"])
    write(repo, "mix.exs", mix_exs("0.1.0", "~> 1.0"))
    write(repo, "lib.txt", "v1\n")
    commit!(repo, "chore: bump version to 0.1.0")
    git!(repo, ["tag", "-a", "v0.1.0", "-m", "v0.1.0"])
    %{repo: repo}
  end

  defp git!(repo, args) do
    {out, 0} =
      System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@example.com" | args],
        cd: repo,
        stderr_to_stdout: true,
        env: [{"GIT_COMMITTER_DATE", "2026-11-16T12:00:00Z"}, {"GIT_AUTHOR_DATE", "2026-11-16T12:00:00Z"}]
      )

    String.trim(out)
  end

  defp write(repo, path, content) do
    full = Path.join(repo, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  defp commit!(repo, subject) do
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "--allow-empty", "-m", subject])
    git!(repo, ["rev-parse", "--short=7", "HEAD"])
  end

  defp mix_exs(version, dep), do: ~s(defmodule X do\n  @version "#{version}"\n  def deps, do: [{:a, "#{dep}"}]\nend\n)

  # A merge that changes the code, then the release of it: the bump commit and its tag. Returns the merge.
  defp release!(repo, version, opts \\ []) do
    write(repo, "lib.txt", File.read!(Path.join(repo, "lib.txt")) <> "#{version}\n")
    merge = commit!(repo, "fix: change for #{version} (#1)")
    write(repo, "mix.exs", mix_exs(version, Keyword.get(opts, :dep, "~> 1.0")))
    commit!(repo, "chore: bump version to #{version}")
    git!(repo, ["tag", "-a", "v#{version}", "-m", "v#{version}"])
    merge
  end

  # The results commit Publish results pushes: one file of benchmark/published, measuring `ref`.
  defp publish!(repo, file, ref, fields) do
    meta = %{"git_ref" => ref, "malachi_version" => "x", "hardware" => Map.get(fields, :hardware, @hw_a)}
    data = fields |> Map.delete(:hardware) |> Map.put("meta", meta)
    write(repo, "benchmark/published/#{file}", JSON.encode!(data))
    commit!(repo, "chore(results): refresh published benchmark and chaos results from CI")
  end

  defp rate(rps, extra \\ %{}), do: Map.merge(%{"records_per_s" => rps, "sweep" => %{}}, extra)

  defp changelog!(repo, sections) do
    write(repo, "CHANGELOG.md", "# Changelog\n\n" <> Enum.map_join(sections, "\n", &section/1))
  end

  defp section({version, parts}) do
    "## v#{version} (2026-11-16)\n\n" <> Enum.map_join(parts, "\n", fn {name, text} -> "### #{name}\n\n#{text}\n" end)
  end

  defp build!(repo, spec, opts \\ [author: "A"]) do
    tags = Measurements.tags(repo)
    {:ok, releases} = Post.releases(spec, tags)
    {:ok, draft} = Post.build(repo, releases, tags, opts)
    draft
  end

  describe "Measurements.find/3" do
    test "finds the run of the release's code at tag^, published after the tag with the previous version",
         %{repo: repo} do
      merge = release!(repo, "0.1.1")
      publish!(repo, "loadtest-node.json", merge, rate(100))

      assert {:ok, %{git_ref: ^merge, data: %{"records_per_s" => 100}}} =
               Measurements.find(repo, "loadtest-node.json", "v0.1.1")
    end

    test "finds it when it lands after the next release's tag, as two releases close together do",
         %{repo: repo} do
      first = release!(repo, "0.1.1")
      second = release!(repo, "0.1.2")
      publish!(repo, "loadtest-node.json", first, rate(100))
      publish!(repo, "loadtest-node.json", second, rate(200))

      assert {:ok, %{git_ref: ^first}} = Measurements.find(repo, "loadtest-node.json", "v0.1.1")
      assert {:ok, %{git_ref: ^second}} = Measurements.find(repo, "loadtest-node.json", "v0.1.2")
    end

    test "of two runs of the release's code, the oldest is taken: the one that measured the merge itself",
         %{repo: repo} do
      merge = release!(repo, "0.1.1")
      publish!(repo, "loadtest-node.json", merge, rate(100))
      write(repo, "CHANGELOG.md", "later")
      later = commit!(repo, "docs: changelog only (#2)")
      publish!(repo, "loadtest-node.json", later, rate(200))

      assert {:ok, %{git_ref: ^merge, data: %{"records_per_s" => 100}}} =
               Measurements.find(repo, "loadtest-node.json", "v0.1.1")
    end

    test "a run of a later commit with the same code counts: results, changelog and blog do not change code",
         %{repo: repo} do
      release!(repo, "0.1.1")
      write(repo, "CHANGELOG.md", "x")
      write(repo, "site/blog/2026-11-16-x.md", "x")
      later = commit!(repo, "docs: a post (#2)")
      publish!(repo, "chaos-upgrade.json", later, %{"verdict" => "passed"})
      assert {:ok, %{git_ref: ^later}} = Measurements.find(repo, "chaos-upgrade.json", "v0.1.1")
    end

    test "a run of other code is not the release's: another file, or a mix.exs that changed more than its version",
         %{repo: repo} do
      release!(repo, "0.1.1")
      write(repo, "docs.md", "changed")
      other = commit!(repo, "docs: something (#2)")
      publish!(repo, "loadtest-node.json", other, rate(100))
      assert Measurements.find(repo, "loadtest-node.json", "v0.1.1") == :none

      merge = release!(repo, "0.1.2", dep: "~> 2.0")
      assert Measurements.same_code?(repo, merge, "v0.1.2") == false
      write(repo, "mix.exs", mix_exs("0.1.2", "~> 1.0"))
      deps_only = commit!(repo, "chore(deps): back (#3)")
      refute Measurements.same_code?(repo, deps_only, "v0.1.2")
    end

    test "a git_ref that names no commit, a file that is not JSON, or no run at all is :none", %{repo: repo} do
      release!(repo, "0.1.1")
      publish!(repo, "loadtest-node.json", "deadbee", rate(1))
      write(repo, "benchmark/published/chaos-node.json", "not json")
      commit!(repo, "chore(results): x")
      assert Measurements.find(repo, "loadtest-node.json", "v0.1.1") == :none
      assert Measurements.find(repo, "chaos-node.json", "v0.1.1") == :none
      assert Measurements.find(repo, "loadtest-elixir.json", "v0.1.1") == :none
      refute Measurements.same_code?(repo, "--output=/tmp/x", "v0.1.1")
    end

    test "a results commit that deletes the file is passed over", %{repo: repo} do
      merge = release!(repo, "0.1.1")
      publish!(repo, "loadtest-node.json", "0000000", rate(1))
      File.rm!(Path.join(repo, "benchmark/published/loadtest-node.json"))
      commit!(repo, "chore(results): drop it")
      publish!(repo, "loadtest-node.json", merge, rate(2))

      assert {:ok, %{git_ref: ^merge, data: %{"records_per_s" => 2}}} =
               Measurements.find(repo, "loadtest-node.json", "v0.1.1")
    end

    test "a folder that is not a repository is an error that says what git said" do
      # Outside the project: a folder under its tmp/ would find the project's own repository.
      outside = TmpDir.path("not_a_repo")
      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf!(outside) end)
      error = assert_raise Mix.Error, fn -> Measurements.tags(outside) end
      assert error.message =~ "git tag --list v* --sort=v:refname failed"
    end

    test "tag_date/2 is the UTC day even for a tag committed late at night west of UTC", %{repo: repo} do
      write(repo, "lib.txt", "late\n")
      git!(repo, ["add", "-A"])

      {_, 0} =
        System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "late"],
          cd: repo,
          env: [{"GIT_COMMITTER_DATE", "2026-11-16T23:30:00-03:00"}, {"GIT_AUTHOR_DATE", "2026-11-16T23:30:00-03:00"}]
        )

      git!(repo, ["tag", "-a", "v0.9.0", "-m", "v0.9.0"])
      assert Measurements.tag_date(repo, "v0.9.0") == ~D[2026-11-17]
    end

    test "tags/1 sorts by version and tag_date/2 is the tag commit's day in UTC", %{repo: repo} do
      release!(repo, "0.1.10")
      release!(repo, "0.1.9")
      git!(repo, ["tag", "-a", "not-a-release", "-m", "x"])
      assert Measurements.tags(repo) == ["v0.1.0", "v0.1.9", "v0.1.10"]
      assert Measurements.tag_date(repo, "v0.1.9") == ~D[2026-11-16]
    end
  end

  describe "releases/2" do
    setup %{repo: repo} do
      for v <- ["0.1.1", "0.1.2", "0.2.0", "0.2.1", "0.2.2"], do: release!(repo, v)
      %{tags: Measurements.tags(repo)}
    end

    test "one release, or consecutive patch releases of one minor", %{tags: tags} do
      assert Post.releases("v0.2.0", tags) == {:ok, ["v0.2.0"]}
      assert Post.releases("v0.2.1..v0.2.2", tags) == {:ok, ["v0.2.1", "v0.2.2"]}
      assert Post.releases("v0.1.1..v0.1.2", tags) == {:ok, ["v0.1.1", "v0.1.2"]}
    end

    for {spec, reason} <- [
          {"0.2.0", "is not a release"},
          {"v0.2", "is not a release"},
          {"v0.2.1..", "is not a release"},
          {"v0.2.1..v0.2.2..v0.2.3", "is not a release"},
          {"v9.9.9", "v9.9.9 is not a release tag here"},
          {"v0.2.2..v0.2.1", "runs backwards"},
          {"v0.1.2..v0.2.1", "spans more than one minor"},
          {"v0.2.0..v0.2.2", "holds a minor release"}
        ] do
      test "refuses #{spec}", %{tags: tags} do
        assert {:error, message} = Post.releases(unquote(spec), tags)
        assert message =~ unquote(reason)
      end
    end
  end

  describe "build/4, the measurements" do
    test "sets each run of the release's code beside the previous release's, with its commit and hardware",
         %{repo: repo} do
      before = release!(repo, "0.1.1")
      publish!(repo, "loadtest-node.json", before, rate(1000))
      publish!(repo, "chaos-node.json", before, %{"verdict" => "passed", "invariants" => %{"acked_writes" => 2617}})
      now = release!(repo, "0.1.2")

      publish!(
        repo,
        "loadtest-node.json",
        now,
        rate(1250, %{
          "sweep" => %{
            "aa_control" => %{"delta_pct" => -0.8, "first_records_per_s" => 1250, "repeat_records_per_s" => 1240}
          }
        })
      )

      publish!(repo, "chaos-node.json", now, %{"verdict" => "failed"})
      changelog!(repo, [{"0.1.2", [{"Fixes", "- a fix (#1)"}]}])
      draft = build!(repo, "v0.1.2")

      assert draft.file == "2026-11-16-v0-1-2.md"
      md = draft.markdown
      assert md =~ "| Measurement | v0.1.1 | v0.1.2 | Change |"
      assert md =~ "| Produce rate, Node.js load test (records/s) | 1,000 | 1,250 | +25.0% |"
      assert md =~ "| Chaos certification, node faults | passed, 2,617 acked writes checked | failed | n/a |"
      assert md =~ "| Produce rate, Elixir load test (records/s) | not measured | not measured | n/a |"
      assert md =~ "- Produce rate, Node.js load test, v0.1.2: commit `#{now}`, AMD EPYC 9V74, 4 cores, linux 7.0.0."
      assert md =~ "moved it -0.8% (1,250 then 1,240 records per second), so a difference between releases smaller"
      refute md =~ "batch sizes"
      assert md =~ "more than 30% between runs of unchanged code"
      refute md =~ ~r/gain|regression|improve|faster|slower/i
    end

    test "runs on different hardware are not compared, and a lower bound or no clean peak says so",
         %{repo: repo} do
      before = release!(repo, "0.1.1")
      publish!(repo, "loadtest-node.json", before, rate(1000, %{hardware: @hw_b}))
      publish!(repo, "loadtest-elixir.json", before, %{"records_per_s" => nil, "meta" => %{}})
      now = release!(repo, "0.1.2")
      publish!(repo, "loadtest-node.json", now, rate(900, %{"lower_bound_reasons" => ["ladder_limit"]}))
      publish!(repo, "loadtest-elixir.json", now, rate(5, %{"peak_at_ladder_limit" => true, hardware: %{"cores" => 1}}))
      changelog!(repo, [{"0.1.2", []}])
      md = build!(repo, "v0.1.2").markdown

      assert md =~ "| 1,000 | 900 (lower bound) | not comparable: different hardware |"
      assert md =~ "| no clean peak | 5 (lower bound) | n/a: the run records no CPU model |"
      assert md =~ "shown only for runs that recorded the same CPU model and core count"
      assert md =~ "commit `#{now}`, 1 core."
      assert md =~ "carries no noise estimate"
    end

    test "the Elixir load test, which records the architecture and not the CPU model, is never compared",
         %{repo: repo} do
      arch = %{"cpu" => "x86_64-pc-linux-gnu", "cores" => 1, "os" => "linux 7.0.0"}
      before = release!(repo, "0.1.1")
      publish!(repo, "loadtest-elixir.json", before, rate(32_121, %{hardware: arch}))
      now = release!(repo, "0.1.2")
      publish!(repo, "loadtest-elixir.json", now, rate(54_509, %{hardware: arch}))
      changelog!(repo, [{"0.1.2", []}])
      md = build!(repo, "v0.1.2").markdown

      assert md =~
               "| Produce rate, Elixir load test (records/s) | 32,121 | 54,509 | n/a: the run records no CPU model |"

      refute md =~ "%|"
    end

    test "a run that recorded no CPU model or no core count is not compared", %{repo: repo} do
      before = release!(repo, "0.1.1")
      publish!(repo, "loadtest-node.json", before, rate(100, %{hardware: %{"cores" => 4}}))
      now = release!(repo, "0.1.2")
      publish!(repo, "loadtest-node.json", now, rate(120, %{hardware: %{"cores" => 4}}))
      changelog!(repo, [{"0.1.2", []}])

      assert build!(repo, "v0.1.2").markdown =~
               "| Produce rate, Node.js load test (records/s) | 100 | 120 | not comparable: hardware not recorded |"
    end

    test "a Node.js run with no clean peak, or a previous rate of zero, shows no change", %{repo: repo} do
      before = release!(repo, "0.1.1")
      publish!(repo, "loadtest-node.json", before, rate(nil))
      now = release!(repo, "0.1.2")
      publish!(repo, "loadtest-node.json", now, rate(120))
      changelog!(repo, [{"0.1.2", []}, {"0.1.3", []}])

      assert build!(repo, "v0.1.2").markdown =~
               "| Produce rate, Node.js load test (records/s) | no clean peak | 120 | n/a |"

      later = release!(repo, "0.1.3")
      publish!(repo, "loadtest-node.json", later, rate(0))
      changelog!(repo, [{"0.1.4", []}])
      next = release!(repo, "0.1.4")
      publish!(repo, "loadtest-node.json", next, rate(50))
      assert build!(repo, "v0.1.4").markdown =~ "| Produce rate, Node.js load test (records/s) | 0 | 50 | n/a |"
    end

    test "a release with no published run, and no previous release, says so", %{repo: repo} do
      changelog!(repo, [{"0.1.0", [{"Features", "- first (#1)"}]}])
      md = build!(repo, "v0.1.0").markdown
      assert md =~ "| Measurement | previous | v0.1.0 | Change |"
      assert md =~ "No published run measured the code of v0.1.0."
    end

    test "a run that recorded no hardware says so", %{repo: repo} do
      now = release!(repo, "0.1.1")
      publish!(repo, "loadtest-node.json", now, rate(1, %{hardware: %{}}))
      changelog!(repo, [{"0.1.1", []}])
      assert build!(repo, "v0.1.1").markdown =~ "commit `#{now}`, hardware not recorded."
    end

    test "a text from a published file cannot break the table", %{repo: repo} do
      now = release!(repo, "0.1.1")
      publish!(repo, "loadtest-node.json", now, rate(1, %{hardware: %{"cpu" => "a|b\nc", "cores" => 2}}))
      changelog!(repo, [{"0.1.1", []}])
      assert build!(repo, "v0.1.1").markdown =~ "commit `#{now}`, a\\|b c, 2 cores."
    end
  end

  describe "build/4, the shape of the draft" do
    test "a patch takes the short form: one placeholder, no chart", %{repo: repo} do
      release!(repo, "0.1.1")
      changelog!(repo, [{"0.1.1", [{"Fixes", "- a fix (#1)"}]}])
      md = build!(repo, "v0.1.1").markdown

      assert md =~ ~r/\A---\ntitle: Malachi v0\.1\.1\ndate: 2026-11-16\nversions: \[0\.1\.1\]\nauthor: A\n/
      assert md =~ "summary: <!-- narrative: one sentence for the index and the link previews -->"
      assert length(Regex.scan(~r/<!-- narrative/, md)) == 2
      refute md =~ "malachi-chart"
      assert md =~ "## Changes\n\n### Fixes\n\n- a fix (#1)\n"
    end

    test "a minor release adds a placeholder for the numbers and charts of the last 8 releases",
         %{repo: repo} do
      for v <- ~w(0.1.1 0.1.2 0.1.3 0.1.4 0.1.5 0.1.6 0.1.7 0.1.8), do: release!(repo, v)
      merge = release!(repo, "0.2.0")
      publish!(repo, "loadtest-node.json", merge, rate(4242))
      changelog!(repo, [{"0.2.0", [{"Features", "- big (#9)"}]}])
      md = build!(repo, "v0.2.0").markdown

      assert md =~ "<!-- narrative: what the numbers below say -->"
      [node, elixir] = Regex.scan(~r/```malachi-chart\n(.*)\n```/, md, capture: :all_but_first) |> List.flatten()
      {:ok, chart} = Chart.parse(node)
      assert Enum.map(chart.points, & &1.label) == ~w(v0.1.2 v0.1.3 v0.1.4 v0.1.5 v0.1.6 v0.1.7 v0.1.8 v0.2.0)
      assert List.last(chart.points).value == 4242
      assert Enum.all?(Enum.drop(chart.points, -1), &is_nil(&1.value))
      assert {:ok, %{name: "elixir-produce-rate"}} = Chart.parse(elixir)
    end

    test "the highlights become the seed block, and the upgrade notes their own section", %{repo: repo} do
      release!(repo, "0.1.1")

      changelog!(repo, [
        {"0.1.1",
         [{"Highlights", "Range reads.\n\n(#1)"}, {"Upgrading", "Set X.\n\n(#1)"}, {"Features", "- reads (#1)"}]}
      ])

      md = build!(repo, "v0.1.1").markdown
      assert md =~ "```malachi-seed\nRange reads.\n\n(#1)\n```\n"
      assert md =~ "## Upgrading\n\nSet X.\n\n(#1)\n"
      assert md =~ "## Changes\n\n### Features\n\n- reads (#1)\n"
      refute md =~ "### Highlights"
    end

    test "a subheading inside the highlights or the upgrade notes stays in that text", %{repo: repo} do
      release!(repo, "0.1.1")

      changelog!(repo, [
        {"0.1.1",
         [
           {"Highlights", "### Range reads\n\nReplay any window.\n\n(#1)"},
           {"Upgrading", "### Before the rolling restart\n\nSet X on every node.\n\n(#1)"},
           {"Fixes", "- a fix (#2)"}
         ]}
      ])

      md = build!(repo, "v0.1.1").markdown
      assert md =~ "```malachi-seed\n### Range reads\n\nReplay any window.\n\n(#1)\n```\n"
      assert md =~ "## Upgrading\n\n### Before the rolling restart\n\nSet X on every node.\n\n(#1)\n"
      assert md =~ "## Changes\n\n### Fixes\n\n- a fix (#2)\n"
      refute md =~ "## Changes\n\n### Range reads"
    end

    test "a code example in the highlights stays inside the seed block", %{repo: repo} do
      release!(repo, "0.1.1")

      changelog!(repo, [
        {"0.1.1", [{"Highlights", "Try it:\n\n```elixir\nMalachi.put(1)\n```\n\nDone. (#5)"}, {"Fixes", "- x (#5)"}]}
      ])

      draft = build!(repo, "v0.1.1")
      assert draft.markdown =~ "````malachi-seed\nTry it:\n\n```elixir\nMalachi.put(1)\n```\n\nDone. (#5)\n````\n"
      write(repo, "site/blog/#{draft.file}", draft.markdown)
      assert [{:ok, post}] = Blog.read_all(repo)
      assert post.seeds == 1
      assert post.html =~ ~r{<pre class="seed"><code>Try it:.*Malachi\.put\(1\).*Done\. \(#5\)</code></pre>}s
    end

    test "a range lists each release's changes and upgrade notes, newest first", %{repo: repo} do
      release!(repo, "0.1.1")
      release!(repo, "0.1.2")

      changelog!(repo, [
        {"0.1.2", [{"Upgrading", "Second."}, {"Fixes", "- two (#2)"}]},
        {"0.1.1", [{"Upgrading", "First."}]}
      ])

      draft = build!(repo, "v0.1.1..v0.1.2")
      assert draft.file == "2026-11-16-v0-1-1-to-v0-1-2.md"
      assert draft.versions == ["0.1.1", "0.1.2"]
      md = draft.markdown
      assert md =~ "title: Malachi v0.1.1 to v0.1.2"
      assert md =~ "## Upgrading\n\n### v0.1.2\n\nSecond.\n\n### v0.1.1\n\nFirst.\n"
      assert md =~ "### v0.1.2\n\n#### Fixes\n\n- two (#2)\n\n### v0.1.1\n\nNo user-facing changes.\n"
      assert md =~ "| Measurement | v0.1.0 | v0.1.2 | Change |"
    end

    test "fails without the changelog, or without the release's section", %{repo: repo} do
      release!(repo, "0.1.1")
      tags = Measurements.tags(repo)
      assert {:error, message} = Post.build(repo, ["v0.1.1"], tags, author: "A")
      assert message =~ "CHANGELOG.md cannot be read"
      changelog!(repo, [{"0.1.0", []}])
      assert {:error, message} = Post.build(repo, ["v0.1.1"], tags, author: "A")
      assert message =~ "CHANGELOG.md has no section for v0.1.1"
    end

    test "the draft is a post the blog reads, refused for publishing until its narrative is written",
         %{repo: repo} do
      release!(repo, "0.1.1")
      changelog!(repo, [{"0.1.1", [{"Highlights", "Seed."}]}])
      draft = build!(repo, "v0.1.1")
      write(repo, "site/blog/#{draft.file}", draft.markdown)

      assert [{:ok, post}] = Blog.read_all(repo)
      assert post.versions == ["0.1.1"]
      assert post.narratives == 1
      assert post.seeds == 1
    end
  end

  test "chart_json/4 writes its keys in a fixed order, so the image's hash is stable" do
    json = Post.chart_json("n", "T \"q\"", "u", [{"v1.0.0", 1}, {"v1.0.1", nil}])

    assert json ==
             ~s({"name": "n", "title": "T \\"q\\"", "unit": "u", "points": [{"label": "v1.0.0", "value": 1}, {"label": "v1.0.1", "value": null}]})

    assert {:ok, _} = Chart.parse(json)
  end
end
