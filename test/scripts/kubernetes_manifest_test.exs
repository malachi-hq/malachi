defmodule KubernetesManifestTest do
  # The Kubernetes example's Erlang distribution (#385): TLS between the pods, epmd and distribution bound to the pod
  # IP, only the Malachi pods allowed to reach those two ports, and a cookie placeholder the nodes refuse. Read as
  # text, as the workflow tests are; there is no YAML parser among the test dependencies.
  use ExUnit.Case, async: true

  alias Malachi.Cluster.DistGuard

  @manifest Path.expand("../../deploy/kubernetes/malachi.yaml", __DIR__)

  setup_all do
    docs = @manifest |> File.read!() |> String.split(~r/^---$/m)
    {:ok, docs: docs, text: File.read!(@manifest)}
  end

  defp doc(docs, kind, name) do
    Enum.find(docs, &(&1 =~ ~r/^kind: #{kind}$/m and &1 =~ ~r/^  name: #{name}$/m)) ||
      flunk("no #{kind} #{name} in the manifest")
  end

  test "the pods run TLS distribution with the options file of the mounted secret", %{text: text} do
    assert text =~ ~r/- name: MALACHI_DIST_TLS\n\s+value: "true"/
    assert text =~ ~r{- name: MALACHI_DIST_TLS_OPTFILE\n\s+value: /etc/malachi/dist/dist_tls.conf}
  end

  test "the options file verifies the peers both ways", %{docs: docs} do
    conf = doc(docs, "Secret", "malachi-dist-tls")
    [server] = Regex.run(~r/\{server, \[[^\n]*\]\}/, conf)
    [client] = Regex.run(~r/\{client, \[[^\n]*\]\}/, conf)
    assert server =~ "{verify, verify_peer}"
    assert server =~ "{fail_if_no_peer_cert, true}"
    assert client =~ "{verify, verify_peer}"
  end

  test "epmd and distribution bind to the pod IP", %{text: text} do
    assert text =~ ~r/- name: POD_IP\n\s+valueFrom:\n\s+fieldRef:\n\s+fieldPath: status.podIP/
    assert text =~ ~r/- name: MALACHI_DIST_INTERFACE\n\s+value: \$\(POD_IP\)/
  end

  test "only the Malachi pods reach epmd and the distribution port; the client ports stay open", %{docs: docs} do
    policy = doc(docs, "NetworkPolicy", "malachi-distribution")
    assert policy =~ ~r/podSelector:\n\s+matchLabels:\n\s+app: malachi\n\s+policyTypes:\n\s+- Ingress/

    [restricted, open] = String.split(policy, ~r/^    - ports:$/m, parts: 2)
    assert restricted =~ ~r/- from:\n\s+- podSelector:\n\s+matchLabels:\n\s+app: malachi/
    for port <- [4369, 9100], do: assert(restricted =~ "port: #{port}")
    for port <- [4040, 4041], do: assert(open =~ "port: #{port}")
    refute open =~ "4369"
    refute open =~ "9100"
  end

  test "the cookie placeholder is one a clustered node refuses", %{docs: docs} do
    [_, cookie] = Regex.run(~r/release-cookie: "([^"]*)"/, doc(docs, "Secret", "malachi-secrets"))
    assert cookie in DistGuard.denylist()
  end
end
