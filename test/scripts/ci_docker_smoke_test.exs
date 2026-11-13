defmodule CiDockerSmokeTest do
  # The `🧪 Test Docker image` step of .github/workflows/ci.yml boots the image with generated passwords and
  # logs in to its dashboard, on a runner where every process can read every other's /proc/<pid>/cmdline.
  # #180: the passwords reach the container by name (`-e MALACHI_DEFAULT_USERS`), and the login and the
  # bearer go through the harnesses' shared transport (scripts/lib/dashboard_curl.sh), which hands them to
  # curl on stdin. The job only proves the step works, not where the secrets travel, so the step's text is
  # pinned here.
  #
  # The guard is a list of the lines allowed to mention a secret, not a list of forbidden spellings: a
  # secret can come back on a command line in more ways than any pattern names (`-e "NAME=$PASS"`,
  # `--env`, `--oauth2-bearer`, `-u user:$PASS`, a `-d` on a continuation line), and every one of them is
  # a line that mentions the variable without being one of these.
  use ExUnit.Case, async: true

  alias Malachi.Test.WorkflowText

  # The variables holding a password or the session token, as `$NAME` or `${NAME}`.
  @secret ~r/\$\{?(ADMIN_PASS|PRODUCER_PASS|CONSUMER_PASS|APP_PASS|TOKEN)\b/

  # What a line mentioning one may be: an assignment (generating a password, building the users), the
  # shared transport's login and scrape, or an echo, a shell builtin that starts no process.
  @allowed [
    ~r/^\s*(ADMIN|PRODUCER|CONSUMER|APP)_PASS="[a-z_]+\$\(openssl rand -hex \d+\)"$/,
    ~r/^\s*MALACHI_DEFAULT_USERS="[^"]*"$/,
    ~r/^\s*if ! TOKEN="\$\(ms_login admin "\$ADMIN_PASS"\)"; then$/,
    ~r/^\s*if ! METRICS_RESPONSE="\$\(ms_http_get \/metrics "\$TOKEN" '\*\/\*'\)"; then$/,
    ~r/^\s*echo "[^"]*"$/
  ]

  defp step(ci \\ File.read!(WorkflowText.path("ci.yml"))) do
    [_, from_step] = String.split(ci, "- name: 🧪 Test Docker image\n", parts: 2)
    [step | _] = String.split(from_step, ~r/\n      - name: /, parts: 2)
    step
  end

  # Every line of the step that mentions a secret and is none of the allowed kinds.
  defp stray_secret_lines(step) do
    step
    |> String.split("\n")
    |> Enum.filter(&(&1 =~ @secret))
    |> Enum.reject(fn line -> Enum.any?(@allowed, &(line =~ &1)) end)
  end

  test "no line of the step puts a password or the session token anywhere but an allowed kind of line" do
    assert stray_secret_lines(step()) == []
  end

  test "hands the users to the container by name, and logs in and scrapes through the shared transport" do
    step = step()
    assert step =~ "export MALACHI_DEFAULT_USERS\n"
    assert step =~ ~r/^\s+-e MALACHI_DEFAULT_USERS \\$/m
    assert step =~ "source scripts/metrics_scrape_lib.sh"
    assert step =~ "source scripts/lib/dashboard_curl.sh"
    assert step =~ ~s|TOKEN="$(ms_login admin "$ADMIN_PASS")"|
    assert step =~ ~s|ms_http_get /metrics "$TOKEN"|
  end

  # The guard against the ways a secret could come back that the first version of this test let through,
  # each added to the real step: every one is caught.
  for {name, line} <- [
        {"a quoted -e with the value", ~S(            -e "MALACHI_ADMIN_PASS=$ADMIN_PASS" \\)},
        {"--env with the value", ~S(            --env MALACHI_DEFAULT_USERS="admin:${ADMIN_PASS}:admin" \\)},
        {"curl --oauth2-bearer", ~S(          curl -sf --oauth2-bearer "$TOKEN" http://localhost:4041/metrics)},
        {"a lowercase authorization header",
         ~S(          curl -sf -H "authorization: bearer $TOKEN" http://localhost:4041/)},
        {"curl -u", ~S(          curl -sf -u "admin:$ADMIN_PASS" http://localhost:4041/login)},
        {"a form body on a continuation line", ~S(            -d "username=admin&password=$ADMIN_PASS" \\)}
      ] do
    test "catches #{name}" do
      ci = File.read!(WorkflowText.path("ci.yml"))
      anchor = "          echo \"🚀 Starting container...\"\n"
      assert ci =~ anchor
      tampered = String.replace(ci, anchor, anchor <> unquote(line) <> "\n", global: false)
      assert stray_secret_lines(step(tampered)) == [unquote(line)]
    end
  end
end
