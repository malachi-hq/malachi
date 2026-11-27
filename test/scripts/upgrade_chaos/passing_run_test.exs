defmodule UpgradeChaos.PassingRunTest do
  # scripts/docker-upgrade-chaos.sh (issue #196): A run that passes: what it runs, in which order, and the shape of the control plane it rolls through.
  # The repository, stubs and helpers are Malachi.Test.UpgradeChaosCase's.
  use Malachi.Test.UpgradeChaosCase, async: true

  describe "a passing run" do
    test "rolls forward, back, forward again and records what it ran", ctx do
      assert {output, 0} = run_drill(ctx)

      assert output =~
               "OLD is v0.16.4 (release 0.16.4, machine version 3: the newest release, whose code this tree changes); " <>
                 "NEW is the working tree with the canary"

      assert output =~ "the canary flag is refused while nodes 1 and 2 run OLD"
      assert output =~ "the canary command is refused at machine version 3"
      assert output =~ "OLD node 1 dropped 7 unknown replication casts and kept serving"
      assert output =~ "the ring has 5 vnodes"
      assert output =~ "the control plane moved to machine version 4"
      assert output =~ "the canary command applies at machine version 4"
      assert output =~ "node 3 on OLD refused the format 3 directory with exit 78"
      assert output =~ "node 3's data directory is byte for byte what it was (2 files)"
      assert output =~ "UPGRADE AND ROLLBACK CERTIFICATION PASSED"

      assert %{
               "verdict" => "passed",
               "invariants" => %{"acked_writes" => acked},
               "details" => %{
                 "old_ref" => "v0.16.4",
                 "old_rule" => "the newest release, whose code this tree changes",
                 "old_version" => "0.16.4",
                 "old_machine_version" => 3,
                 "old_patch" => nil,
                 "new_patch" => nil,
                 "negative_control" => false,
                 "vnodes_after_split" => 5,
                 "acked_writes_by_phase" => %{"phase1" => p1, "phase2" => p2, "phase3" => p3}
               }
             } = result(ctx)

      assert acked == p1 + p2 + p3 and p1 > 0 and p2 > 0 and p3 > 0
    end

    test "copies both trees through files, so a tar that stops reading at the end marker cannot fail it", ctx do
      # bsdtar exits as soon as it reads the end-of-archive marker; a writer (`git archive`, or a creating tar)
      # still writing its padding into a pipe then dies of SIGPIPE. This tar, extracting from stdin however it
      # is spelled, reads one block and leaves, every time; anything else is the real tar (early_tar()).
      real_tar = System.find_executable("tar")

      write!(ctx.stubs, "tar", String.replace(early_tar(), "REAL_TAR", real_tar))

      File.chmod!(Path.join(ctx.stubs, "tar"), 0o755)
      assert {output, 0} = run_drill(ctx)
      refute output =~ "could not export"
    end

    test "builds OLD from the release's own tree and NEW from the working tree with the canary", ctx do
      File.write!(Path.join(ctx.root, "lib/canary.txt"), "released\n")
      assert {_output, 0} = run_drill(ctx)

      builds = Enum.filter(docker_calls(ctx), &String.starts_with?(&1, "build "))
      assert Enum.any?(builds, &(&1 =~ "-t repo-upgrade:old" and &1 =~ "ctx=ctx-old canary=released version=0.16.4"))
      assert Enum.any?(builds, &(&1 =~ "-t repo-upgrade:new" and &1 =~ "ctx=ctx-new canary=canary version=0.17.0"))
      assert "image rm repo-upgrade:old repo-upgrade:new" in docker_calls(ctx)
    end

    test "runs every node on the image and pin each step calls for", ctx do
      assert {_output, 0} = run_drill(ctx)
      ups = Enum.filter(docker_calls(ctx), &String.starts_with?(&1, "up -d"))

      assert ups == [
               "up -d --force-recreate malachi1 malachi2 malachi3 | pin=3 images=old,old,old restart=on-failure",
               # phase 1, under the pin
               "up -d malachi3 | pin=3 images=old,old,new restart=on-failure",
               "up -d malachi2 | pin=3 images=old,new,new restart=on-failure",
               "up -d malachi1 | pin=3 images=new,new,new restart=on-failure",
               # phase 2, back to OLD, still under the pin
               "up -d malachi3 | pin=3 images=new,new,old restart=on-failure",
               "up -d malachi2 | pin=3 images=new,old,old restart=on-failure",
               "up -d malachi1 | pin=3 images=old,old,old restart=on-failure",
               # phase 3, forward under the pin, then finalized node by node
               "up -d malachi3 | pin=3 images=old,old,new restart=on-failure",
               "up -d malachi2 | pin=3 images=old,new,new restart=on-failure",
               "up -d malachi1 | pin=3 images=new,new,new restart=on-failure",
               "up -d malachi3 | pin= images=new,new,new restart=on-failure",
               "up -d malachi2 | pin= images=new,new,new restart=on-failure",
               "up -d malachi1 | pin= images=new,new,new restart=on-failure",
               # the refused rollback, with its restarts bounded, and the way back
               "up -d malachi3 | pin= images=new,new,old restart=on-failure:3",
               "up -d malachi3 | pin= images=new,new,new restart=on-failure"
             ]
    end

    # OLD serves the stream keys only behind the producer_streams flag, which this build keeps as a retired
    # no-op: the drill turns it on once, as soon as the OLD cluster is up, before anything is swapped.
    test "switches the stream keys on once, after the OLD cluster is up and before the first swap", ctx do
      assert {output, 0} = run_drill(ctx)
      assert output =~ "the stream keys are on"
      calls = docker_calls(ctx)
      at = fn pattern -> for {call, i} <- Enum.with_index(calls), call =~ pattern, do: i end

      assert [flag] = at.(~r/^exec malachi-cluster-1 .*malachi\.flag enable producer_streams --node malachi@malachi1$/)
      assert [start] = at.("up -d --force-recreate malachi1 malachi2 malachi3")
      assert [first_swap | _later] = at.("up -d malachi3 |")
      assert start < flag and flag < first_swap
    end

    test "keeps the log of every container before replacing it", ctx do
      assert {_output, 0} = run_drill(ctx)

      # Between two recreates, the node about to be recreated had its log read.
      Enum.reduce(docker_calls(ctx), MapSet.new(), fn call, logged ->
        case Regex.run(~r/^up -d malachi(\d) /, call) do
          [_, n] ->
            assert "malachi-cluster-#{n}" in logged, "no log saved before #{call}"
            MapSet.new()

          nil ->
            case Regex.run(~r/^logs (malachi-cluster-\d)$/, call) do
              [_, container] -> MapSet.put(logged, container)
              nil -> logged
            end
        end
      end)
    end

    test "splits the ring on the lease holder while every node runs NEW", ctx do
      assert {_output, 0} = run_drill(ctx)
      calls = docker_calls(ctx)
      split_at = Enum.find_index(calls, &(&1 =~ "malachi.reshard --to 5"))
      last_p1_swap = Enum.find_index(calls, &(&1 == "up -d malachi1 | pin=3 images=new,new,new restart=on-failure"))
      first_p2_swap = Enum.find_index(calls, &(&1 == "up -d malachi3 | pin=3 images=new,new,old restart=on-failure"))
      assert last_p1_swap < split_at and split_at < first_p2_swap
    end
  end

  describe "the shape of the control plane" do
    test "runs four vnodes and splits the ring when OLD resumes its vnode members after a restart", ctx do
      assert {output, 0} = run_drill(ctx)
      assert output =~ "control plane: 4 vnodes (sharded: v0.16.4 resumes its vnode members after a restart)"
      assert Enum.any?(docker_calls(ctx), &(&1 =~ "malachi.reshard --to 5"))
      assert %{"details" => %{"vnodes" => 4, "vnodes_after_split" => 5}} = result(ctx)
    end

    test "runs unsharded and splits nothing when OLD cannot bring its vnode members back", ctx do
      assert {output, 0} = run_drill(ctx, [{"OLD_REF", "v0.16.2"}])
      assert output =~ "control plane: 1 vnodes (unsharded, no split: v0.16.2 does not resume its vnode members"
      refute Enum.any?(docker_calls(ctx), &(&1 =~ "malachi.reshard"))
      refute Enum.any?(docker_calls(ctx), &(&1 =~ "malachi.ring --show"))
      assert %{"details" => %{"vnodes" => 1, "vnodes_after_split" => nil}} = result(ctx)
    end
  end
end
