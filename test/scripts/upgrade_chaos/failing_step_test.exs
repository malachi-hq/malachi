defmodule UpgradeChaos.FailingStepTest do
  # scripts/docker-upgrade-chaos.sh (issue #196): Every other step that can fail, each failing the run.
  # The repository, stubs and helpers are Malachi.Test.UpgradeChaosCase's.
  use Malachi.Test.UpgradeChaosCase, async: true

  describe "every other step that can fail" do
    test "fails when the split does not complete", ctx do
      assert {output, 1} = run_drill(ctx, [{"STUB_SPLIT", "refused"}])
      assert output =~ "FAIL: the split did not complete"
    end

    test "fails when no produce is acknowledged once node 3 stops for the refused rollback", ctx do
      # Counted from before the stop, the acks that arrive while node 3 still runs would pass the step
      # without nodes 1 and 2 ever acknowledging a write on their own.
      assert {output, 1} = run_drill(ctx, [{"STUB_STALL_ON_REFUSED_ROLLBACK", "1"}, {"PROGRESS_TIMEOUT_S", "2"}])
      assert output =~ "FAIL: no produce was acknowledged through the refused rollback of node 3 (quorum on 2/3)"
    end

    test "fails when no produce is acknowledged through the split", ctx do
      assert {output, 1} = run_drill(ctx, [{"STUB_STALL_ON_SPLIT", "1"}, {"PROGRESS_TIMEOUT_S", "4"}])
      assert output =~ "FAIL: no produce was acknowledged through the split"
    end

    test "fails when the rollback to OLD loses a vnode the split created", ctx do
      assert {output, 1} = run_drill(ctx, [{"STUB_RING_AFTER_ROLLBACK", "4"}])
      assert output =~ "FAIL: expected a 5-vnode ring, got '4'"
    end

    test "fails when compose cannot start node 3 on OLD after the flip", ctx do
      assert {output, 1} = run_drill(ctx, [{"STUB_UP_REFUSED_NODE", "fail"}])
      assert output =~ "FAIL: compose could not start node 3 on OLD"
    end

    test "fails when nodes 1 and 2 do not serve while node 3 is refused", ctx do
      assert {output, 1} = run_drill(ctx, [{"STUB_PRODUCE_FAILS_ON", "malachi1,malachi2"}, {"PROGRESS_TIMEOUT_S", "2"}])
      assert output =~ "FAIL: nodes 1 and 2 did not serve a clean produce while node 3 was down"
    end

    test "fails when the canary command does not apply once the pin is removed", ctx do
      assert {output, 1} = run_drill(ctx, [{"STUB_FINAL_CANARY", "refused"}])
      assert output =~ "FAIL: the canary command did not apply at machine version 4"
    end

    test "fails when the flag is refused with every node on NEW", ctx do
      assert {output, 1} = run_drill(ctx, [{"STUB_FINAL_FLAG", "refused"}])
      assert output =~ "FAIL: the canary flag was refused with every node on NEW"
    end
  end
end
