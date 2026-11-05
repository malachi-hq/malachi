defmodule CheckNoPipeToShellTest do
  # The guard that keeps issue #69 from coming back. A grep-based check that is never exercised is
  # indistinguishable from a broken one: it stays green because it matches nothing. So both halves are
  # pinned here, the shapes it must reject and the near-misses it must not, plus a run over the real
  # repository so a future script that reintroduces the pattern fails this test and not only CI.
  use ExUnit.Case, async: true

  alias Malachi.Test.TmpDir

  @guard Path.expand("../../scripts/check-no-pipe-to-shell.sh", __DIR__)
  @repo_root Path.expand("../..", __DIR__)

  setup do
    dir = TmpDir.path("pipe-guard")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "rejects" do
    test "a download piped into sudo bash, the exact shape issue #69 removed", ctx do
      file = fixture(ctx, "curl -1sLf 'https://example.com/setup.sh' | sudo -E bash")

      assert {output, status} = run([file])
      assert status == 1
      assert output =~ "reaches a shell interpreter"
      assert output =~ Path.basename(file)
    end

    test "wget piped into sh with no spaces around the pipe", ctx do
      file = fixture(ctx, "wget -qO- https://example.com/install.sh|sh")

      assert {_output, 1} = run([file])
    end

    test "an environment-prefixed interpreter", ctx do
      file = fixture(ctx, "curl -sL https://example.com/i | env FOO=1 bash -s -- --yes")

      assert {_output, 1} = run([file])
    end

    test "an interpreter written with an absolute path", ctx do
      # This one escaped the first version of the pattern, which required the command name to start
      # immediately after the pipe. Caught by review on PR #132.
      file = fixture(ctx, "curl -fsSL https://example.com/install | /bin/bash")

      assert {_output, 1} = run([file])
    end

    test "env with flags, and env itself written with a path", ctx do
      with_flags = fixture(ctx, "curl -sL https://example.com/i | env -i bash")
      with_path = fixture(ctx, "curl -sL https://example.com/i | /usr/bin/env sh")

      assert {_output, 1} = run([with_flags])
      assert {_output, 1} = run([with_path])
    end

    test "sudo in front of an absolute interpreter", ctx do
      file = fixture(ctx, "curl -sL https://example.com/i | sudo /bin/sh")

      assert {_output, 1} = run([file])
    end

    test "process substitution feeding the interpreter, attached or through stdin", ctx do
      # `< <(...)` was the second half of the PR #132 review follow-up: the pattern required the
      # substitution to sit directly against the interpreter.
      attached = fixture(ctx, "bash <(curl -sL https://example.com/install)")
      redirected = fixture(ctx, "bash < <(curl -sL https://example.com/install)")

      assert {_output, 1} = run([attached])
      assert {_output, 1} = run([redirected])
    end

    test "env with the bare -- terminator", ctx do
      file = fixture(ctx, "curl -fsSL https://example.com/i | env -- bash")

      assert {_output, 1} = run([file])
    end

    test "the download sourced into the current shell", ctx do
      with_source = fixture(ctx, "source <(curl -sL https://example.com/i)")
      with_dot = fixture(ctx, ". <(curl -sL https://example.com/i)")

      assert {_output, 1} = run([with_source])
      assert {_output, 1} = run([with_dot])
    end

    test "the download taken as a command substitution argument", ctx do
      # `sh -c "$(curl ...)"` and `eval "$(curl ...)"` are the two spellings that show up in real install
      # instructions, and neither is a pipe.
      evaled = fixture(ctx, ~S|eval "$(curl -sL https://example.com/i)"|)
      dash_c = fixture(ctx, ~S|bash -c "$(curl -fsSL https://example.com/i)"|)
      backticked = fixture(ctx, "eval `curl -sL https://example.com/i`")

      assert {_output, 1} = run([evaled])
      assert {_output, 1} = run([dash_c])
      assert {_output, 1} = run([backticked])
    end

    test "an intermediate stage in the pipeline", ctx do
      file = fixture(ctx, "curl -sL https://example.com/i | tac | bash")

      assert {_output, 1} = run([file])
    end
  end

  describe "accepts" do
    test "pipes that only look like the pattern", ctx do
      file =
        fixture(ctx, """
        curl -fsSL https://example.com/list -o out.txt | grep sh
        curl -s https://example.com/conf | sudo tee /etc/example.conf
        curl -fsSL "$url" -o "$dest" || die "download failed: $url"
        curl -s https://example.com/x | /usr/local/bin/fish
        curl -s https://example.com/x | tee /tmp/notes.sh
        sh script.sh; echo "$(curl -s https://example.com/x)"
        version="$(curl -s https://example.com/v)"
        diff <(curl -s https://example.com/a) <(curl -s https://example.com/b)
        """)

      assert {output, 0} = run([file])
      assert output =~ "no download reaches"
    end

    test "the repository's own scripts, Makefile and Dockerfile" do
      assert {output, 0} = run([])
      assert output =~ "files scanned"
    end
  end

  test "fails loudly rather than scanning nothing when a target does not exist" do
    assert {output, 1} = run([TmpDir.path("no-such-script") <> ".sh"])
    assert output =~ "not a file"
  end

  describe "the Terraform example's scripts and templates" do
    # The guard finds the repository from its own location, so a copy under a temporary root scans that root.
    setup ctx do
      root = Path.join(ctx.dir, "root")
      File.mkdir_p!(Path.join(root, "scripts"))
      File.cp!(@guard, Path.join(root, "scripts/check-no-pipe-to-shell.sh"))
      %{root: root}
    end

    defp write_tree(root, rel, body) do
      path = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, body)
      path
    end

    defp guard_in(root) do
      System.cmd("bash", [Path.join(root, "scripts/check-no-pipe-to-shell.sh")],
        cd: root,
        stderr_to_stdout: true
      )
    end

    test "rejects a download piped into a shell inside a cloud-init template", %{root: root} do
      write_tree(root, "deploy/terraform/x/node.cloud-init.yaml.tftpl", "runcmd:\n  - curl -fsSL https://example.com/i | sh\n")

      assert {output, 1} = guard_in(root)
      assert output =~ "node.cloud-init.yaml.tftpl"
    end

    test "rejects the same shape in a shell script of the example", %{root: root} do
      write_tree(root, "deploy/terraform/x/files/run.sh", "#!/bin/bash\ncurl -fsSL https://example.com/i | bash\n")

      assert {output, 1} = guard_in(root)
      assert output =~ "run.sh"
    end

    test "accepts a download saved to a file and checked, the form the daily run uses", %{root: root} do
      write_tree(root, "deploy/terraform/x/files/run.sh", "#!/bin/bash\ncurl -fsSL -o src.tgz https://example.com/i\necho \"$SHA  src.tgz\" | sha256sum -c\n")

      assert {_output, 0} = guard_in(root)
    end

    test "skips provider caches, which are not the repository's code", %{root: root} do
      # A clean file beside the cache: an empty scope is a failure by design, so the test needs something to scan.
      write_tree(root, "deploy/terraform/x/files/clean.sh", "#!/bin/bash\necho ok\n")
      write_tree(root, "deploy/terraform/x/.terraform/providers/evil.sh", "curl -fsSL https://example.com/i | sh\n")

      assert {output, 0} = guard_in(root)
      refute output =~ "evil.sh"
    end
  end

  defp fixture(ctx, body) do
    path = Path.join(ctx.dir, "fixture-#{System.unique_integer([:positive])}.sh")
    File.write!(path, "#!/bin/bash\n" <> body <> "\n")
    path
  end

  defp run(args) do
    System.cmd("bash", [@guard | args], cd: @repo_root, stderr_to_stdout: true)
  end
end
