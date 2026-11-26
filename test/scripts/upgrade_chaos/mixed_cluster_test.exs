defmodule UpgradeChaos.MixedClusterTest do
  # scripts/docker-upgrade-chaos.sh (issue #196): The mixed cluster of OLD and NEW nodes, and the rollback the format marker refuses.
  # The repository, stubs and helpers are Malachi.Test.UpgradeChaosCase's.
  use Malachi.Test.UpgradeChaosCase, async: true

  describe "the mixed cluster" do
    test "fails when the flag is accepted while OLD nodes remain", ctx do
      assert {output, 1} = run_drill(ctx, [{"STUB_MIXED_FLAG", "accepted"}])
      assert output =~ "FAIL: the canary flag was not refused while nodes 1 and 2 run OLD"
    end

    test "accepts the refusal of an OLD leader, which does not know the command at all", ctx do
      assert {output, 0} = run_drill(ctx, [{"STUB_MIXED_CANARY", "old_leader"}])
      assert output =~ "the canary command is refused at machine version 3"
    end

    test "fails when node 3's own metadata cache took the refused command", ctx do
      assert {output, 1} = run_drill(ctx, [{"STUB_CACHE_NOTE", "1"}])
      assert output =~ "FAIL: node 3's metadata cache took the command every replica refused (canary_note=1)"
    end

    test "reads node 3's cache in the same VM that sends the command, before a reconcile can re-seed it", ctx do
      assert {_output, 0} = run_drill(ctx)

      assert [call] =
               Enum.filter(docker_calls(ctx), &(&1 =~ "exec malachi-cluster-3" and &1 =~ "{:canary_note, ~s("))

      assert call =~ ":sys, :get_state, [Malachi.LogBroker]"
    end

    test "fails when the canary command is not refused at the pinned version", ctx do
      assert {output, 1} = run_drill(ctx, [{"STUB_MIXED_CANARY", "applied"}])
      assert output =~ "FAIL: the canary command was not refused at machine version 3"
    end

    test "fails when no OLD node ever counted the unknown cast", ctx do
      assert {output, 1} = run_drill(ctx, [{"STUB_UNKNOWN_CASTS", "0"}])
      assert output =~ "FAIL: OLD node 1 counted no unknown replication cast"
    end

    test "reads the unknown casts from an OLD node, not the NEW one that sends them", ctx do
      assert {_output, 0} = run_drill(ctx)
      metrics = Enum.filter(docker_calls(ctx), &(&1 =~ ~r/^exec -i \S+ sh -s$/))
      assert metrics != [] and Enum.all?(metrics, &(&1 == "exec -i malachi-cluster-1 sh -s"))
    end

    test "fails when the topic metadata diverged", ctx do
      assert {output, 1} = run_drill(ctx, [{"STUB_CONTROL_PLANE", "diverged"}])
      assert output =~ "FAIL: the control plane diverged"
    end
  end

  describe "the refused rollback" do
    test "fails when OLD starts on the format 3 directory", ctx do
      assert {output, 1} = run_drill(ctx, [{"STUB_REFUSAL", "healthy"}])
      assert output =~ "FAIL: node 3 on OLD did not exit 78 on a format 3 directory (last state: running 0 healthy)"
    end

    test "fails when OLD exits 78 for another reason than the format marker", ctx do
      assert {output, 1} = run_drill(ctx, [{"STUB_REFUSAL", "flag"}])
      assert output =~ "FAIL: node 3 on OLD exited 78 without the format marker's refusal"
    end

    test "fails when the refused start changed a byte of the data directory", ctx do
      assert {output, 1} = run_drill(ctx, [{"STUB_MD5_CHANGES", "1"}])
      assert output =~ "FAIL: node 3's data directory changed across the refused start"
    end

    test "takes the canary's machine version from NEW's own tree, not a number of its own", ctx do
      # The next release that raises the machine version moves the canary with it: only the patch changes.
      File.write!(
        Path.join(ctx.root, "test/support/canary.patch"),
        patch("lib/canary.txt", "released", "canary") <> version_patch(7)
      )

      assert {output, 0} = run_drill(ctx, [{"STUB_EFFECTIVE", "7"}])
      assert output =~ "the canary command is refused at machine version 3"
      assert output =~ "the control plane moved to machine version 7"
      assert output =~ "the canary command applies at machine version 7"
    end

    test "fails when the finalized control plane stays below version 4", ctx do
      assert {output, 1} = run_drill(ctx, [{"STUB_EFFECTIVE", "3"}])
      assert output =~ "FAIL: the control plane did not move to machine version 4 after the pin was removed (at '3')"
    end

    test "fails when a data directory never reaches format 3 after the flip", ctx do
      assert {output, 1} = run_drill(ctx, [{"STUB_FORMAT", "1"}])
      assert output =~ "FAIL: node 1's data directory did not reach format 3 after the flip (at '1')"
    end
  end
end
