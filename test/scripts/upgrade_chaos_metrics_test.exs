defmodule UpgradeChaosMetricsTest do
  # The one place scripts/docker-upgrade-chaos.sh talks to a dashboard: `unexpected_casts` hands a node's
  # shell a script on stdin that logs in and reads /metrics. #180: neither the password nor the session
  # token may be a process argument there, since the host sees the container's processes too. The script
  # is taken out of the drill and run under sh with busybox-like `wget` and `nc` stubs that record their
  # argv and their stdin apart. UpgradeChaosTest covers the drill around it.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @drill Path.expand("../../scripts/docker-upgrade-chaos.sh", __DIR__)

  setup_all do
    # Missing tools fail loudly instead of skipping: a skipped harness test reads as a passing one.
    System.find_executable("sh") || flunk("sh is required to test #{@drill}")
    :ok
  end

  setup %{tmp_dir: dir} do
    stubs = Path.join(dir, "stubs")
    File.mkdir_p!(stubs)
    stub!(Path.join(stubs, "wget"), wget_stub())
    stub!(Path.join(stubs, "nc"), nc_stub())
    %{stubs: stubs, argv: Path.join(dir, "argv.log"), stdin: Path.join(dir, "stdin.log")}
  end

  test "logs in and scrapes with the password and the token on stdin only", ctx do
    assert {output, 0} = run_in_node_script(ctx, "tok_EN-123")
    assert output =~ ~s(malachi_unexpected_messages_total{server="replication",kind="cast"} 7)

    argv = File.read!(ctx.argv)
    assert argv =~ "wget -qO- -T 5 --header Content-Type: application/json --post-file /dev/stdin"
    assert argv =~ "nc -w 5 127.0.0.1 4041"
    refute argv =~ "admin123"
    refute argv =~ "tok_EN-123"

    stdin = File.read!(ctx.stdin)
    assert stdin =~ ~s(wget:{"username":"admin","password":"admin123"})
    assert stdin =~ "Authorization: Bearer tok_EN-123\r\n"
  end

  test "a login that answers no token scrapes nothing and fails", ctx do
    assert {_output, 1} = run_in_node_script(ctx, "")
    refute File.read!(ctx.argv) =~ "nc "
  end

  # As they appear inside the JSON string the node answers with, escapes included.
  for token <- [~S(a\"b), "a b", ~S(a\nb)] do
    test "a token outside base64url (#{token}) is not sent", ctx do
      assert {_output, 1} = run_in_node_script(ctx, unquote(token))
      refute File.read!(ctx.argv) =~ "nc "
    end
  end

  # The heredoc `unexpected_casts` sends to `docker exec -i ... sh -s`, run under sh as the node would.
  defp run_in_node_script(ctx, token) do
    [_, after_start] = @drill |> File.read!() |> String.split("sh -s 2>/dev/null <<'EOF'", parts: 2)
    [_line_rest, body] = String.split(after_start, "\n", parts: 2)
    [script, _] = String.split(body, "\nEOF\n", parts: 2)

    System.cmd("sh", ["-c", script],
      env: [
        {"PATH", ctx.stubs <> ":" <> System.get_env("PATH", "")},
        {"STUB_ARGV_LOG", ctx.argv},
        {"STUB_STDIN_LOG", ctx.stdin},
        {"STUB_TOKEN", token}
      ],
      stderr_to_stdout: true
    )
  end

  defp stub!(path, body) do
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  defp wget_stub do
    ~S"""
    #!/bin/sh
    printf 'wget %s\n' "$*" >> "$STUB_ARGV_LOG"
    { printf 'wget:'; cat; printf '\n'; } >> "$STUB_STDIN_LOG"
    printf '{"s":"ok","token":"%s"}' "$STUB_TOKEN"
    """
  end

  defp nc_stub do
    ~S"""
    #!/bin/sh
    printf 'nc %s\n' "$*" >> "$STUB_ARGV_LOG"
    { printf 'nc:'; cat; } >> "$STUB_STDIN_LOG"
    printf 'HTTP/1.1 200 OK\r\nContent-Length: 70\r\n\r\n'
    printf 'malachi_unexpected_messages_total{server="replication",kind="cast"} 7\n'
    """
  end
end
