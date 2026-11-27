defmodule Malachi.Cluster.DistGuardTest do
  # What a clustered node requires of Erlang distribution before it starts (#385). check/1 is pure, so every rule is
  # tested on facts; the options files are written per test. These tests assert the refusal, never what a node on a
  # refused configuration would allow.
  use ExUnit.Case, async: true

  alias Malachi.Cluster.DistGuard

  @moduletag :tmp_dir

  @cookie String.duplicate("k", 64)

  # Each file under a name of its own: facts/2 writes its default file while a case builds another.
  defp conf(dir, server, client) do
    path = Path.join(dir, "dist_tls_#{System.unique_integer([:positive])}.conf")
    # Erlang terms, as an ssl_dist options file holds them
    File.write!(path, :io_lib.format(~c"~p.~n", [[{:server, server}, {:client, client}]]))
    path
  end

  defp verified(dir, ca \\ "/dist/ca.crt") do
    conf(dir, [cacertfile: ca, verify: :verify_peer, fail_if_no_peer_cert: true], cacertfile: ca, verify: :verify_peer)
  end

  defp facts(dir, overrides \\ %{}) do
    Map.merge(
      %{
        clustered?: true,
        cookie: @cookie,
        baked_cookie: nil,
        dist_tls: nil,
        proto_dist: ["inet_tls"],
        optfile: verified(dir),
        client_cacertfile: nil
      },
      overrides
    )
  end

  describe "a single node" do
    test "is not checked, whatever its cookie and transport", %{tmp_dir: dir} do
      assert DistGuard.check(facts(dir, %{clustered?: false, cookie: "malachi_bench", proto_dist: []})) == :ok
    end
  end

  describe "the cookie of a clustered node" do
    test "a long random cookie over verified TLS distribution passes", %{tmp_dir: dir} do
      assert DistGuard.check(facts(dir)) == :ok
    end

    test "the release's baked cookie is refused, however long", %{tmp_dir: dir} do
      assert DistGuard.check(facts(dir, %{baked_cookie: @cookie})) == {:error, :cookie_baked}
    end

    test "an empty baked cookie file refuses nothing on its own", %{tmp_dir: dir} do
      assert DistGuard.check(facts(dir, %{baked_cookie: ""})) == :ok
    end

    for literal <- ~w(malachi_bench malachi_durable_cookie malachi_secret CHANGE_ME_to_a_long_random_string) do
      test "the committed literal #{literal} is refused", %{tmp_dir: dir} do
        assert DistGuard.check(facts(dir, %{cookie: unquote(literal)})) == {:error, :cookie_committed}
      end
    end

    test "a cookie under 20 bytes is refused, and one of 20 passes", %{tmp_dir: dir} do
      assert DistGuard.check(facts(dir, %{cookie: String.duplicate("a", 19)})) == {:error, :cookie_short}
      assert DistGuard.check(facts(dir, %{cookie: String.duplicate("a", 20)})) == :ok
    end

    test "no cookie at all is refused as too short", %{tmp_dir: dir} do
      assert DistGuard.check(facts(dir, %{cookie: nil})) == {:error, :cookie_short}
    end

    test "the cookie is checked before the transport", %{tmp_dir: dir} do
      assert DistGuard.check(facts(dir, %{cookie: "malachi_bench", proto_dist: []})) == {:error, :cookie_committed}
    end
  end

  describe "the transport of a clustered node" do
    test "plaintext is refused unless MALACHI_DIST_TLS is exactly false", %{tmp_dir: dir} do
      for tls <- [nil, "", "true"] do
        assert DistGuard.check(facts(dir, %{dist_tls: tls, proto_dist: []})) == {:error, :dist_plaintext}
      end

      assert DistGuard.check(facts(dir, %{dist_tls: "false", proto_dist: []})) == :ok
    end

    test "any other MALACHI_DIST_TLS value is refused rather than read as on or off", %{tmp_dir: dir} do
      for tls <- ~w(FALSE False 0 no off TRUE 1 yes) do
        assert DistGuard.check(facts(dir, %{dist_tls: tls})) == {:error, :dist_tls_invalid}, tls
      end
    end

    test "TLS distribution with no options file is refused", %{tmp_dir: dir} do
      assert DistGuard.check(facts(dir, %{optfile: nil})) == {:error, :dist_tls_no_optfile}
    end

    test "an options file that cannot be read, or holds no server and client, is refused", %{tmp_dir: dir} do
      missing = Path.join(dir, "missing.conf")
      assert DistGuard.check(facts(dir, %{optfile: missing})) == {:error, :dist_tls_unreadable}

      garbage = Path.join(dir, "garbage.conf")
      File.write!(garbage, "not erlang terms")
      assert DistGuard.check(facts(dir, %{optfile: garbage})) == {:error, :dist_tls_unreadable}

      half = Path.join(dir, "half.conf")
      File.write!(half, "[{server, [{verify, verify_peer}, {fail_if_no_peer_cert, true}]}].\n")
      assert DistGuard.check(facts(dir, %{optfile: half})) == {:error, :dist_tls_unreadable}
    end

    test "an options file that does not verify both ways is refused", %{tmp_dir: dir} do
      ok_server = [verify: :verify_peer, fail_if_no_peer_cert: true]
      ok_client = [verify: :verify_peer]

      for {server, client} <- [
            {[verify: :verify_none, fail_if_no_peer_cert: true], ok_client},
            {[verify: :verify_peer], ok_client},
            {[verify: :verify_peer, fail_if_no_peer_cert: false], ok_client},
            {ok_server, [verify: :verify_none]},
            {ok_server, []}
          ] do
        path = conf(dir, server, client)

        assert DistGuard.check(facts(dir, %{optfile: path})) == {:error, :dist_tls_unverified},
               inspect({server, client})
      end
    end

    test "a distribution CA that is the client CA, by any path to it, is refused", %{tmp_dir: dir} do
      ca = Path.join(dir, "ca.crt")
      File.write!(ca, "ca")
      link = Path.join(dir, "link.crt")
      File.ln_s!(ca, link)

      assert DistGuard.check(facts(dir, %{optfile: verified(dir, ca), client_cacertfile: ca})) ==
               {:error, :dist_ca_shared}

      assert DistGuard.check(facts(dir, %{optfile: verified(dir, link), client_cacertfile: ca})) ==
               {:error, :dist_ca_shared}

      other = Path.join(dir, "other.crt")
      File.write!(other, "ca")
      assert DistGuard.check(facts(dir, %{optfile: verified(dir, ca), client_cacertfile: other})) == :ok
    end
  end

  describe "facts" do
    test "baked_cookie/1 reads releases/COOKIE under the release root, trimmed", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "releases"))
      File.write!(Path.join([dir, "releases", "COOKIE"]), "BAKEDCOOKIE\n")
      assert DistGuard.baked_cookie(dir) == "BAKEDCOOKIE"
      assert DistGuard.baked_cookie(Path.join(dir, "nowhere")) == nil
      assert DistGuard.baked_cookie(nil) == nil
    end

    test "facts/1 reads this VM: its cookie and its distribution protocols" do
      facts = DistGuard.facts(true)
      assert facts.clustered?
      assert facts.cookie == Atom.to_string(Node.get_cookie())
      assert is_list(facts.proto_dist)
      refute "inet_tls" in facts.proto_dist
    end
  end

  test "every denylisted cookie is a shell-safe word, since the release template writes them into a case pattern" do
    for cookie <- DistGuard.denylist(), do: assert(cookie =~ ~r/\A[A-Za-z0-9_]+\z/)
  end
end

defmodule Malachi.Cluster.DistGuardFactsEnvTest do
  # facts/1 against the environment, apart from the async module above: it sets a variable the whole VM reads.
  use ExUnit.Case, async: false

  alias Malachi.Cluster.DistGuard

  test "the options file comes from the VM's own arguments, never from MALACHI_DIST_TLS_OPTFILE" do
    previous = System.get_env("MALACHI_DIST_TLS_OPTFILE")

    on_exit(fn ->
      if previous,
        do: System.put_env("MALACHI_DIST_TLS_OPTFILE", previous),
        else: System.delete_env("MALACHI_DIST_TLS_OPTFILE")
    end)

    System.put_env("MALACHI_DIST_TLS_OPTFILE", "/dist/verified.conf")

    # this VM was started with no -ssl_dist_optfile, so there is no file its distribution reads
    assert :init.get_argument(:ssl_dist_optfile) == :error
    assert DistGuard.facts(true).optfile == nil
  end
end
