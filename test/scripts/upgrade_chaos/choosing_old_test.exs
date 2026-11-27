defmodule UpgradeChaos.ChoosingOldTest do
  # scripts/docker-upgrade-chaos.sh (issue #196): Which release the drill takes as OLD, and the releases and trees it refuses before building anything.
  # The repository, stubs and helpers are Malachi.Test.UpgradeChaosCase's.
  use Malachi.Test.UpgradeChaosCase, async: true

  describe "choosing OLD" do
    # A release cut without the stream keys, newer than every other and at machine version 2, and the tree past
    # it again, at 3.
    defp release_without_stream_keys(ctx) do
      # the keys named and gated, but not answered: no fetch_range in the wire protocol
      write!(ctx.root, "lib/malachi/tcp_protocol.ex", "defmodule T do\nend\n")
      write!(ctx.root, "lib/malachi/cluster/machine_version.ex", "defmodule M do\n  @code_version 2\nend\n")
      write!(ctx.root, "lib/malachi/routing.ex", "defmodule R do\n  @flag :producer_streams\nend\n")
      git!(ctx.root, ["add", "lib/malachi/routing.ex"])
      write!(ctx.root, "lib/malachi/wire.ex", "defmodule W do\n  def cluster_state_key, do: 24\nend\n")
      git!(ctx.root, ["add", "lib/malachi/wire.ex"])
      write!(ctx.root, "mix.exs", ~s(defmodule P do\n  @version "0.18.0"\nend\n))
      git!(ctx.root, ["commit", "-q", "-am", "a release without the stream keys"])
      git!(ctx.root, ["tag", "v0.18.0"])
      write!(ctx.root, "lib/malachi/tcp_protocol.ex", "defmodule T do\n  # api_key == Wire.fetch_range_key() ->\nend\n")
      write!(ctx.root, "lib/malachi/cluster/machine_version.ex", "defmodule M do\n  @code_version 3\nend\n")
      git!(ctx.root, ["commit", "-q", "-am", "the stream keys"])
    end

    test "a newest release that predates the stream keys has its data carried over, and the tree is rolled from",
         ctx do
      release_without_stream_keys(ctx)
      assert {output, 0} = run_drill(ctx)

      assert output =~
               "DATA is v0.18.0 (release 0.18.0, machine version 2: the newest release, whose code this tree " <>
                 "changes), carried over in phase 0"

      assert output =~
               "OLD is working tree (release 0.18.0, machine version 3: the working tree: v0.18.0, the newest " <>
                 "release, whose code this tree changes, predates the stream keys, so its data is carried over in phase 0)"

      assert output =~ "v0.18.0's checker acked 1 writes"
      assert output =~ "the control plane moved from machine version 2 to 3"
      assert output =~ "UPGRADE AND ROLLBACK CERTIFICATION PASSED"
      refute output =~ "the stream keys are on"

      assert %{
               "verdict" => "passed",
               "invariants" => %{"acked_writes" => acked},
               "details" => %{
                 "old_ref" => "working tree",
                 "old_version" => "0.18.0",
                 "old_machine_version" => 3,
                 "data_ref" => "v0.18.0",
                 "data_version" => "0.18.0",
                 "data_machine_version" => 2,
                 "acked_writes_by_phase" => %{"phase0" => 1, "phase1" => p1, "phase2" => p2, "phase3" => p3}
               }
             } = result(ctx)

      assert acked == 1 + p1 + p2 + p3
    end

    test "phase 0 starts on the release, writes with its own checker, and moves every node and the pin", ctx do
      release_without_stream_keys(ctx)
      assert {_output, 0} = run_drill(ctx)
      calls = docker_calls(ctx)

      builds = Enum.filter(calls, &String.starts_with?(&1, "build "))
      assert Enum.any?(builds, &(&1 =~ "-t repo-upgrade:data" and &1 =~ "ctx=ctx-data canary=released version=0.18.0"))
      assert Enum.any?(builds, &(&1 =~ "-t repo-upgrade:old" and &1 =~ "ctx=ctx-old canary=released version=0.18.0"))
      assert "image rm repo-upgrade:data repo-upgrade:old repo-upgrade:new" in calls

      ups = Enum.filter(calls, &String.starts_with?(&1, "up -d"))

      assert Enum.take(ups, 7) == [
               "up -d --force-recreate malachi1 malachi2 malachi3 | pin=2 images=data,data,data restart=on-failure",
               "up -d malachi3 | pin=2 images=data,data,old restart=on-failure",
               "up -d malachi2 | pin=2 images=data,old,old restart=on-failure",
               "up -d malachi1 | pin=2 images=old,old,old restart=on-failure",
               "up -d malachi3 | pin=3 images=old,old,old restart=on-failure",
               "up -d malachi2 | pin=3 images=old,old,old restart=on-failure",
               "up -d malachi1 | pin=3 images=old,old,old restart=on-failure"
             ]

      # the release's checker writes, from its own tree, and this tree's checker reads it back after the moves
      at = fn pattern -> Enum.find_index(calls, &(&1 =~ pattern)) end
      data_produce = at.(~r/^run .*repo-upgrade:data .*chaos_checker\.exs produce \S+ chaos_upgrade_p0 /)
      assert data_produce, "the release's checker did not write phase 0"
      assert Enum.at(calls, data_produce) =~ ~r{ctx-data/scripts:/chaos_scripts}
      verify = at.(~r/chaos_checker\.exs verify \S+ chaos_upgrade_p0 /)
      assert verify, "this tree's checker did not read phase 0 back"
      last_move = Enum.find_index(calls, &(&1 == "up -d malachi1 | pin=3 images=old,old,old restart=on-failure"))
      assert data_produce < at.("up -d malachi3 | pin=2 images=data,data,old") and last_move < verify
    end

    test "phase 0 fails when the release's checker acknowledged nothing", ctx do
      release_without_stream_keys(ctx)
      assert {output, 1} = run_drill(ctx, [{"STUB_DATA_ACKS", "0"}])
      assert output =~ "v0.18.0's checker acked nothing"
      assert %{"verdict" => "failed"} = result(ctx)
    end

    test "phase 0 fails when the control plane does not follow the pin to the tree's machine version", ctx do
      release_without_stream_keys(ctx)
      assert {output, 1} = run_drill(ctx, [{"STUB_STUCK_VERSION", "2"}])
      assert output =~ "the control plane did not move to machine version 3 (at '2')"
    end

    test "a release's known crash in a DATA log is shown, not failed", ctx do
      release_without_stream_keys(ctx)
      assert {output, 0} = run_drill(ctx, [{"STUB_CRASH", "data_timeout"}])
      assert output =~ "(DATA, a crash it is known to have, listed in OLD_KNOWN_CRASHES; not failed)"
    end

    test "the working tree as OLD has no known crash excused", ctx do
      release_without_stream_keys(ctx)
      assert {output, 1} = run_drill(ctx, [{"STUB_CRASH", "old_timeout"}])
      assert output =~ "a process crashed during the upgrade"
    end

    test "an OLD_REF that predates the stream keys is a usage error, not a skip", ctx do
      release_without_stream_keys(ctx)
      assert {output, 2} = run_drill(ctx, [{"OLD_REF", "v0.18.0"}])
      assert output =~ "usage error: OLD_REF=v0.18.0 predates the stream keys"
      assert %{"verdict" => "failed"} = result(ctx)
    end

    test "on a tree whose code is the newest release, OLD is the release before it", ctx do
      # What main looks like right after a release: the newest tag holds this very code, and rolling from
      # it would certify a release against itself.
      git!(ctx.root, ["reset", "-q", "--hard", "v0.16.4"])
      assert {output, 0} = run_drill(ctx)

      assert output =~
               "OLD is v0.16.2 (release 0.16.2, machine version 3: the newest release whose code differs from this " <>
                 "tree, which is release v0.16.4's)"

      assert %{"details" => %{"old_ref" => "v0.16.2"}} = result(ctx)
    end

    test "skips a release that only changed the docs, whose code is this tree's too", ctx do
      git!(ctx.root, ["reset", "-q", "--hard", "v0.16.4"])
      File.write!(Path.join(ctx.root, "README.md"), "docs only\n")
      git!(ctx.root, ["add", "README.md"])
      git!(ctx.root, ["commit", "-q", "-m", "docs"])
      git!(ctx.root, ["tag", "v0.16.5"])

      assert {output, 0} = run_drill(ctx)
      assert output =~ "OLD is v0.16.2 (release 0.16.2, machine version 3: the newest release whose code differs"
      assert output =~ "which is release v0.16.5's)"
    end

    test "a new file git does not track yet counts as code, since the NEW image is built with it", ctx do
      git!(ctx.root, ["reset", "-q", "--hard", "v0.16.4"])
      File.write!(Path.join(ctx.root, "lib/brand_new.ex"), "defmodule BrandNew do\nend\n")
      assert {output, 0} = run_drill(ctx)

      assert output =~
               "OLD is v0.16.4 (release 0.16.4, machine version 3: the newest release, whose code this tree changes)"
    end

    test "an uncommitted change counts as a tree ahead of the newest release", ctx do
      git!(ctx.root, ["reset", "-q", "--hard", "v0.16.4"])
      File.write!(Path.join(ctx.root, "lib/feature.txt"), "work in progress\n")
      assert {output, 0} = run_drill(ctx)

      assert output =~
               "OLD is v0.16.4 (release 0.16.4, machine version 3: the newest release, whose code this tree changes)"
    end

    test "refuses a release below the unsharded floor, before building anything, and records why", ctx do
      assert {output, 2} = run_drill(ctx, [{"OLD_REF", "v0.13.0"}])

      assert output =~
               "OLD_REF=v0.13.0 is release 0.13.0; an unsharded run needs 0.14.2 or later, the first release with " <>
                 "every gate the canary exercises and every control-plane group NEW starts"

      refute Enum.any?(docker_calls(ctx), &String.starts_with?(&1, "build"))
      assert %{"verdict" => "failed", "failures" => [failure]} = result(ctx)
      assert failure =~ "usage error: OLD_REF=v0.13.0 is release 0.13.0"
    end

    test "refuses a release that would run sharded below the sharded floor", ctx do
      # An old release that already resumed its vnode members would be taken sharded, and phase 2 then needs
      # it to bring up a vnode a split created (#242), which only 0.16.1 and later do.
      git!(ctx.root, ["checkout", "-q", "v0.13.0"])
      File.write!(Path.join(ctx.root, "mix.exs"), ~s(defmodule P do\n  @version "0.15.0"\nend\n))

      File.write!(
        Path.join(ctx.root, "lib/malachi/application.ex"),
        "defmodule A do\n  def resume_local_vnodes(_v), do: []\nend\n"
      )

      git!(ctx.root, ["add", "."])
      git!(ctx.root, ["commit", "-q", "-m", "0.15.0"])
      git!(ctx.root, ["tag", "v0.15.0"])
      git!(ctx.root, ["checkout", "-q", "-"])

      assert {output, 2} = run_drill(ctx, [{"OLD_REF", "v0.15.0"}])
      assert output =~ "OLD_REF=v0.15.0 is release 0.15.0; a sharded run needs 0.16.1 or later"
    end

    test "refuses 0.14.1, which lacks a control-plane group NEW starts", ctx do
      git!(ctx.root, ["checkout", "-q", "v0.13.0"])
      File.write!(Path.join(ctx.root, "mix.exs"), ~s(defmodule P do\n  @version "0.14.1"\nend\n))
      git!(ctx.root, ["commit", "-q", "-am", "0.14.1"])
      git!(ctx.root, ["tag", "v0.14.1"])
      git!(ctx.root, ["checkout", "-q", "-"])

      assert {output, 2} = run_drill(ctx, [{"OLD_REF", "v0.14.1"}])
      assert output =~ "OLD_REF=v0.14.1 is release 0.14.1; an unsharded run needs 0.14.2 or later"
    end

    test "refuses an OLD whose machine version it cannot read", ctx do
      git!(ctx.root, ["checkout", "-q", "v0.13.0"])
      File.write!(Path.join(ctx.root, "mix.exs"), ~s(defmodule P do\n  @version "0.16.3"\nend\n))
      File.write!(Path.join(ctx.root, "lib/malachi/cluster/machine_version.ex"), "defmodule M do\nend\n")
      git!(ctx.root, ["commit", "-q", "-am", "0.16.3"])
      git!(ctx.root, ["tag", "v0.16.3"])
      git!(ctx.root, ["checkout", "-q", "-"])

      assert {output, 2} = run_drill(ctx, [{"OLD_REF", "v0.16.3"}])
      assert output =~ "cannot read the machine version of v0.16.3"
    end

    test "refuses a canary tree whose machine version it cannot read", ctx do
      # A patch that computes the version rather than stating it: the drill cannot know what the control
      # plane should reach, so it stops rather than certify against an empty number.
      File.write!(
        Path.join(ctx.root, "test/support/canary.patch"),
        patch("lib/canary.txt", "released", "canary") <> version_patch("Version.current()")
      )

      assert {output, 2} = run_drill(ctx)
      assert output =~ "cannot read the machine version of the canary tree"
    end

    test "accepts an unsharded release between the two floors", ctx do
      git!(ctx.root, ["checkout", "-q", "v0.13.0"])
      File.write!(Path.join(ctx.root, "mix.exs"), ~s(defmodule P do\n  @version "0.14.2"\nend\n))
      git!(ctx.root, ["commit", "-q", "-am", "0.14.2"])
      git!(ctx.root, ["tag", "v0.14.2"])
      git!(ctx.root, ["checkout", "-q", "-"])

      assert {output, 0} = run_drill(ctx, [{"OLD_REF", "v0.14.2"}])
      assert output =~ "control plane: 1 vnodes (unsharded, no split: v0.14.2"
    end

    test "an image that does not build ends the run through finish: recorded, and its images removed", ctx do
      assert {output, 1} = run_drill(ctx, [{"STUB_BUILD_FAILS", "new"}])
      assert output =~ "FAIL: the NEW image did not build"
      assert output =~ "UPGRADE AND ROLLBACK CERTIFICATION FAILED"
      assert "image rm repo-upgrade:old" in docker_calls(ctx)
      refute Enum.any?(docker_calls(ctx), &String.starts_with?(&1, "up "))
      # No cluster was started, so none is torn down: another run of this compose project may be using it.
      refute "down" in docker_calls(ctx)

      # The record still says which release the run was rolling from.
      assert %{
               "verdict" => "failed",
               "failures" => ["the NEW image did not build"],
               "details" => %{"old_ref" => "v0.16.4", "old_machine_version" => 3}
             } = result(ctx)
    end

    test "names every node's image before its first compose command", ctx do
      # Compose reads the whole override, which requires an image for every node, whatever service a command
      # names: building the load generator before the images are placed fails the run on a real host.
      assert {_output, 0} = run_drill(ctx)
      refute Enum.any?(docker_calls(ctx), &(&1 =~ "UPGRADE_IMAGE_1 is missing"))
      assert Enum.any?(docker_calls(ctx), &(&1 =~ ~r/^build loadtest/))
    end

    test "refuses a ref that names nothing", ctx do
      assert {output, 2} = run_drill(ctx, [{"OLD_REF", "v9.9.9"}])
      assert output =~ "OLD_REF=v9.9.9 names no commit here; fetch the tags (fetch-depth: 0)"
    end

    test "says what to do when no release tag is reachable", ctx do
      git!(ctx.root, ["tag", "-d", "v0.13.0", "v0.16.2", "v0.16.4"])
      assert {output, 2} = run_drill(ctx)
      assert output =~ "no release tag is reachable from HEAD; fetch the tags (fetch-depth: 0) or set OLD_REF"
    end

    test "fails loudly when the canary no longer applies", ctx do
      File.write!(Path.join(ctx.root, "lib/canary.txt"), "drifted\n")
      assert {output, 1} = run_drill(ctx)
      assert output =~ "FAIL: the upgrade canary patch (test/support/canary.patch) does not apply to the NEW tree"

      # OLD was resolved before the patch step, and the record says so.
      assert %{"verdict" => "failed", "details" => %{"old_ref" => "v0.16.4", "old_machine_version" => 3}} =
               result(ctx)
    end

    test "records a run with an extra patch as a negative control", ctx do
      old_patch = Path.join(ctx.root, "old.patch")
      File.write!(old_patch, patch("lib/canary.txt", "released", "reverted"))
      assert {_output, 0} = run_drill(ctx, [{"OLD_PATCH", old_patch}])

      assert %{"details" => %{"negative_control" => true, "old_patch" => ^old_patch, "new_patch" => nil}} = result(ctx)
      assert Enum.any?(docker_calls(ctx), &(&1 =~ "ctx=ctx-old canary=reverted"))
    end
  end
end
