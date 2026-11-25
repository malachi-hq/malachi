defmodule SecurityImageGateTest do
  # The image scan in security.yml (#385): the SARIF run records every finding for the Security tab and never fails,
  # and a second Trivy run after the upload fails the docker-scan job on a fixable HIGH or CRITICAL finding. Without
  # that gate a CVE already on main is invisible in every pull request, since code scanning reports only the alerts a
  # pull request introduces. Read as text, as the other workflow tests are.
  use ExUnit.Case, async: true

  alias Malachi.Test.WorkflowText

  @trivy ~r/^\s+uses: aquasecurity\/trivy-action@[0-9a-f]{40} # v\d+\.\d+\.\d+$/m

  setup_all do
    job = "security.yml" |> WorkflowText.path() |> File.read!() |> WorkflowText.jobs() |> Map.fetch!("docker-scan")
    steps = job |> String.split(~r/^      - /m) |> tl()
    {:ok, steps: steps}
  end

  defp step(steps, name), do: Enum.find(steps, &String.starts_with?(&1, "name: #{name}\n"))
  defp index(steps, name), do: Enum.find_index(steps, &String.starts_with?(&1, "name: #{name}\n"))

  test "the gate scans the built image and fails on a fixable HIGH or CRITICAL finding", %{steps: steps} do
    gate = step(steps, "Fail on fixable HIGH or CRITICAL image findings")
    assert gate, "docker-scan has no gate step"

    assert gate =~ @trivy, "the gate is not Trivy pinned by a full commit SHA"
    assert gate =~ ~r/^\s+scan-type: 'image'$/m
    assert gate =~ ~r/^\s+image-ref: 'malachi:security-test'$/m
    assert gate =~ ~r/^\s+format: 'table'$/m
    assert gate =~ ~r/^\s+severity: 'CRITICAL,HIGH'$/m
    assert gate =~ ~r/^\s+ignore-unfixed: true$/m
    assert gate =~ ~r/^\s+exit-code: '1'$/m
    refute gate =~ ~r/^\s+if:/m, "the gate must not be skipped by a condition"
    refute gate =~ ~r/continue-on-error/, "the gate must fail the job"
  end

  test "the gate runs after the SARIF upload, so the Security tab is fed even when it fails", %{steps: steps} do
    assert index(steps, "Upload Docker scan results") < index(steps, "Fail on fixable HIGH or CRITICAL image findings")
    assert step(steps, "Upload Docker scan results") =~ ~r/^\s+if: always\(\)$/m
  end

  test "the SARIF run still records every finding and never fails the job", %{steps: steps} do
    sarif = step(steps, "Run Trivy on Docker image")
    assert sarif =~ @trivy
    assert sarif =~ ~r/^\s+format: 'sarif'$/m
    assert sarif =~ ~r/^\s+output: 'trivy-docker-results.sarif'$/m
    refute sarif =~ "exit-code"
    refute sarif =~ "ignore-unfixed"
  end

  test "both Trivy runs use the same pinned release", %{steps: steps} do
    pins =
      for name <- ["Run Trivy on Docker image", "Fail on fixable HIGH or CRITICAL image findings"],
          do: Regex.run(~r/trivy-action@([0-9a-f]{40})/, step(steps, name), capture: :all_but_first)

    assert [[sha], [sha]] = pins
  end
end
