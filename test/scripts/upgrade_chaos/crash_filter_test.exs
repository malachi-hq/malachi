defmodule UpgradeChaos.CrashFilterTest do
  # scripts/docker-upgrade-chaos.sh (issue #196): The filter of known OLD crashes, and the invariants the drill checks when it closes.
  # The repository, stubs and helpers are Malachi.Test.UpgradeChaosCase's.
  use Malachi.Test.UpgradeChaosCase, async: true

  describe "the known OLD crash filter" do
    # Run as the drill defines it: its list and function, lifted from the script, over a log written here.
    @known_then_unknown """
    13:40:11.858 [error] GenServer Malachi.LogHealer terminating
    ** (stop) exited in: GenServer.call(Malachi.LogBroker, :metadata, 5000)
        ** (EXIT) time out
        (elixir 1.19.6) lib/gen_server.ex:1142: GenServer.call/3
    13:40:12.000 [error] GenServer Malachi.LogReplication terminating
    ** (FunctionClauseError) no function clause matching in Malachi.Cluster.ReplicationServer.handle_cast/2
    13:40:13.000 [info] done
    """

    defp filter(ctx, override) do
      log = Path.join(ctx.tmp_dir, "old.log")
      File.write!(log, @known_then_unknown)

      script = """
      eval "$(sed -n '/^OLD_KNOWN_CRASHES=(/,/^}/p' "$DRILL")"
      #{override}
      without_known_crashes "$LOG"
      echo "status=$?"
      """

      System.cmd("bash", ["-c", script],
        env: [{"DRILL", Path.join(scripts_dir(), "docker-upgrade-chaos.sh")}, {"LOG", log}],
        stderr_to_stdout: true
      )
    end

    test "drops a known crash and keeps the one after it, which fails the run", ctx do
      {output, 0} = filter(ctx, "")
      refute output =~ "LogHealer terminating"
      assert output =~ "LogReplication terminating"
      assert output =~ "** (FunctionClauseError)"
      assert output =~ "status=0"
    end

    test "with no known crash listed, removes nothing", ctx do
      {output, 0} = filter(ctx, "OLD_KNOWN_CRASHES=()")
      assert output =~ "LogHealer terminating"
      assert output =~ "LogReplication terminating"
    end

    test "an entry that is not a regular expression fails, rather than hide what it did not read", ctx do
      {output, 0} = filter(ctx, "OLD_KNOWN_CRASHES=('GenServer.call(Malachi.LogBroker')")
      refute output =~ "status=0"
    end

    test "one entry that matches an empty line fails the list, even beside a valid one", ctx do
      # Entries are joined with |, so a single match-anything entry would excuse every crash.
      for entry <- ["'()'", "'.*'", "'x*'"] do
        {output, 0} = filter(ctx, "OLD_KNOWN_CRASHES=('GenServer\\.call\\(Malachi\\.LogBroker' #{entry})")
        assert output =~ "status=2", entry
        refute output =~ "terminating", entry
      end
    end
  end

  describe "the closing invariants" do
    test "fails on a crash report in the saved log of a container that was since replaced", ctx do
      # The crash is only in the log node 2's OLD container had when phase 1 replaced it: the live
      # containers' logs at the end are clean, so only the saved copy can show it.
      assert {output, 1} = run_drill(ctx, [{"STUB_CRASH", "1"}])
      assert output =~ "--- 02-malachi-cluster-2.log"
      assert output =~ "** (FunctionClauseError) no function clause matching"
      assert output =~ "FAIL: a process crashed during the upgrade"
    end

    test "an OLD build's crash that is listed as known is shown, not failed: it is that release's own", ctx do
      # What the drill met on Linux: v0.17.0's heal coordinator died on a broker call timing out, the bug
      # this branch fixes. A released build cannot be fixed by certifying the next one.
      assert {output, 0} = run_drill(ctx, [{"STUB_CRASH", "old_timeout"}])
      assert output =~ "(OLD, a crash it is known to have, listed in OLD_KNOWN_CRASHES; not failed)"
      assert output =~ "GenServer Malachi.LogHealer terminating"
      refute output =~ "FAIL: a process crashed"
    end

    test "an OLD build's heal coordinator dying on its apply_heal call is known too", ctx do
      # What the drill met on Linux with v0.18.0: the same bug, the call that timed out handing the heal
      # commands to the broker rather than reading its metadata.
      assert {output, 0} = run_drill(ctx, [{"STUB_CRASH", "old_apply_heal_timeout"}])
      assert output =~ "(OLD, a crash it is known to have, listed in OLD_KNOWN_CRASHES; not failed)"
      assert output =~ "{:apply_heal,"
      refute output =~ "FAIL: a process crashed"
    end

    # The list is the drill's own, so these edit the copy of the drill this test runs.
    defp known_crashes!(ctx, entry) do
      drill = Path.join([ctx.root, "scripts", "docker-upgrade-chaos.sh"])
      text = File.read!(drill)
      [known] = Regex.run(~r/^  'GenServer.*:metadata'$/m, text)
      File.write!(drill, String.replace(text, known, "  " <> entry))
    end

    test "an entry awk cannot read as a regular expression fails the run instead of hiding the log", ctx do
      known_crashes!(ctx, "'GenServer.call(Malachi.LogBroker'")
      assert {output, 1} = run_drill(ctx, [{"STUB_CRASH", "old_timeout"}])

      assert output =~
               "FAIL: OLD_KNOWN_CRASHES holds an entry that matches an empty line or one awk cannot read as a regular expression"

      assert output =~ "FAIL: a process crashed during the upgrade"
    end

    test "an empty entry fails the run: an empty regular expression would excuse every crash", ctx do
      known_crashes!(ctx, "''")
      assert {output, 1} = run_drill(ctx, [{"STUB_CRASH", "old_timeout"}])
      assert output =~ "FAIL: OLD_KNOWN_CRASHES holds an entry that matches an empty line"
    end

    test "an entry that matches every line fails the run like an empty one", ctx do
      known_crashes!(ctx, "'.*'")
      assert {output, 1} = run_drill(ctx, [{"STUB_CRASH", "old_timeout"}])
      assert output =~ "FAIL: OLD_KNOWN_CRASHES holds an entry that matches an empty line"
      assert output =~ "FAIL: a process crashed during the upgrade"
    end

    test "any other OLD crash fails, including a known message in a shape it cannot read", ctx do
      # Not a FunctionClauseError: the tag matched a clause and the payload did not fit it.
      assert {output, 1} = run_drill(ctx, [{"STUB_CRASH", "old_keyerror"}])
      assert output =~ "repo-upgrade:old)"
      assert output =~ "** (KeyError) key :records not found"
      assert output =~ "FAIL: a process crashed during the upgrade"
    end

    test "any crash in a NEW build's log fails, whatever it was over", ctx do
      assert {output, 1} = run_drill(ctx, [{"STUB_CRASH", "new_timeout"}])
      assert output =~ "repo-upgrade:new)"
      assert output =~ "GenServer Malachi.LogHealer terminating"
      assert output =~ "FAIL: a process crashed during the upgrade"
    end

    test "fails a phase whose steps outlast its checker window", ctx do
      assert {output, 1} = run_drill(ctx, [{"PHASE2_WINDOW_S", "0"}])
      assert output =~ "FAIL: phase 2 took"
      assert output =~ "raise PHASE2_WINDOW_S"
    end

    test "refuses to start while another cluster runs", ctx do
      assert {output, 1} = run_drill(ctx, [{"STUB_RUNNING", "malachi-cluster-2"}])
      assert output =~ "refusing to start: another cluster is already running (malachi-cluster-2)."
      refute Enum.any?(docker_calls(ctx), &String.starts_with?(&1, "up "))
      # Refused before building: the images are tagged per checkout, so building first would re-tag, and the
      # way out remove, the images the running cluster uses. Still a result, published as failed.
      refute Enum.any?(docker_calls(ctx), &String.starts_with?(&1, "build "))
      refute Enum.any?(docker_calls(ctx), &String.starts_with?(&1, "image rm"))
      refute Enum.any?(docker_calls(ctx), &String.starts_with?(&1, "down"))
      assert %{"verdict" => "failed", "failures" => failures} = result(ctx)
      assert "another cluster is already running (malachi-cluster-2)" in failures
      # Nor are that cluster's logs printed as this run's postmortem.
      refute output =~ "postmortem"
      refute Enum.any?(docker_calls(ctx), &String.starts_with?(&1, "logs "))
    end
  end
end
