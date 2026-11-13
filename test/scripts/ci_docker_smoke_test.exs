defmodule CiDockerSmokeTest do
  # The `🧪 Test Docker image` step of .github/workflows/ci.yml boots the image with generated passwords and
  # logs in to its dashboard, on a runner where every process can read every other's /proc/<pid>/cmdline.
  # #180: the passwords reach the container by name (`-e MALACHI_DEFAULT_USERS`), and the login and the
  # bearer go through the harnesses' shared transport (scripts/lib/dashboard_curl.sh), which hands them to
  # curl on stdin. The job only proves the step works, not where the secrets travel, so the step's text is
  # pinned here.
  use ExUnit.Case, async: true

  alias Malachi.Test.WorkflowText

  defp step do
    ci = File.read!(WorkflowText.path("ci.yml"))
    [_, from_step] = String.split(ci, "- name: 🧪 Test Docker image\n", parts: 2)
    [step | _] = String.split(from_step, ~r/\n      - name: /, parts: 2)
    step
  end

  test "hands the users to the container by name, never as a value on the docker command line" do
    assert step() =~ "export MALACHI_DEFAULT_USERS\n"
    assert step() =~ ~r/^\s+-e MALACHI_DEFAULT_USERS \\$/m
    refute step() =~ ~r/-e MALACHI_\w*(PASS|USERS)=/
  end

  test "logs in and scrapes through the shared transport, the secrets on curl's stdin" do
    assert step() =~ "source scripts/metrics_scrape_lib.sh"
    assert step() =~ "source scripts/lib/dashboard_curl.sh"
    assert step() =~ ~s|TOKEN="$(ms_login admin "$ADMIN_PASS")"|
    assert step() =~ ~s|ms_http_get /metrics "$TOKEN"|
  end

  test "puts no password and no session token on a curl argument" do
    refute step() =~ ~r/curl[^\n]*(\s-d\s|--data)/
    refute step() =~ "Authorization: Bearer"
    refute step() =~ ~r/"password\\?":/
  end
end
