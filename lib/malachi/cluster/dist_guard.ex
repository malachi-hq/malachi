defmodule Malachi.Cluster.DistGuard do
  @moduledoc """
  What a clustered node requires of Erlang distribution before it starts (#385): a cookie of this deployment's own,
  and TLS distribution that verifies its peers, unless plaintext is asked for explicitly.

  A node is clustered when `MALACHI_CLUSTER_STRATEGY` names a discovery strategy or its control plane has peers
  (`MALACHI_LOG_CLUSTER` with more than one `MALACHI_LOG_NODES`). A single node is not checked: it reaches no peer.

  The cookie is refused when it is:

    * the one baked into the release (`releases/COOKIE`), shared by every copy of the same build, which is what a
      release without `RELEASE_COOKIE` runs on;
    * a value committed to this repository (`denylist/0`), which anyone can read;
    * shorter than 20 bytes, the length of the cookie Erlang generates for itself.

  Distribution must run over TLS (`-proto_dist inet_tls`) with an options file whose server side has `verify_peer`
  and `fail_if_no_peer_cert` and whose client side has `verify_peer`, and its CA must not be the one that signs
  client certificates (`MALACHI_TLS_CACERTFILE`), since any certificate that CA signs could then join the cluster.
  `MALACHI_DIST_TLS=false` is the one way to run plaintext distribution; any value other than `true`, `false` or
  unset is refused.

  In a release, `rel/env.sh.eex` applies the cookie rules, requires TLS and reads the options file's terms before the
  VM starts, so those refusals come before the node listens. Reading the options file as Erlang terms and comparing
  its CA with `MALACHI_TLS_CACERTFILE` happen only here, once the VM runs and its distribution port is open. This
  module is the check for every node, the ones `mix run` starts included, and the release template takes its
  denylist from here. `check/1` is pure; `facts/1` reads the running VM.
  """

  # Cookies committed to this repository, now or in its history: they stay refused for good, since the history is
  # public. Each is a shell-safe word, because rel/env.sh.eex writes them into a `case` pattern.
  @denylist ~w(malachi_bench malachi_durable_cookie malachi_secret CHANGE_ME_to_a_long_random_string)

  @min_cookie_bytes 20

  @type reason ::
          :cookie_baked
          | :cookie_committed
          | :cookie_short
          | :dist_tls_invalid
          | :dist_plaintext
          | :dist_tls_no_optfile
          | :dist_tls_unreadable
          | :dist_tls_unverified
          | :dist_ca_shared

  @type facts :: %{
          required(:clustered?) => boolean(),
          required(:cookie) => String.t() | nil,
          required(:baked_cookie) => String.t() | nil,
          required(:dist_tls) => String.t() | nil,
          required(:proto_dist) => [String.t()],
          required(:optfile) => Path.t() | nil,
          required(:client_cacertfile) => Path.t() | nil
        }

  @doc "The cookies committed to this repository, which a clustered node refuses."
  @spec denylist() :: [String.t()]
  def denylist, do: @denylist

  @doc "The shortest cookie a clustered node accepts, in bytes."
  @spec min_cookie_bytes() :: pos_integer()
  def min_cookie_bytes, do: @min_cookie_bytes

  @doc "Checks `facts` (see `facts/0`): `:ok`, or the first reason the node must not start."
  @spec check(facts()) :: :ok | {:error, reason()}
  def check(%{clustered?: false}), do: :ok

  def check(facts) do
    with :ok <- check_cookie(facts.cookie, facts.baked_cookie) do
      check_transport(facts)
    end
  end

  defp check_cookie(cookie, baked) do
    cond do
      is_binary(baked) and baked != "" and cookie == baked -> {:error, :cookie_baked}
      cookie in @denylist -> {:error, :cookie_committed}
      not is_binary(cookie) or byte_size(cookie) < @min_cookie_bytes -> {:error, :cookie_short}
      true -> :ok
    end
  end

  defp check_transport(%{dist_tls: "false"}), do: :ok

  defp check_transport(%{dist_tls: tls} = facts) when tls in [nil, "", "true"] do
    cond do
      "inet_tls" not in facts.proto_dist -> {:error, :dist_plaintext}
      facts.optfile in [nil, ""] -> {:error, :dist_tls_no_optfile}
      true -> check_options(facts.optfile, facts.client_cacertfile)
    end
  end

  defp check_transport(_facts), do: {:error, :dist_tls_invalid}

  defp check_options(optfile, client_ca) do
    with {:ok, [opts]} when is_list(opts) <- :file.consult(String.to_charlist(optfile)),
         server when is_list(server) <- Keyword.get(opts, :server),
         client when is_list(client) <- Keyword.get(opts, :client) do
      cond do
        server[:verify] != :verify_peer or server[:fail_if_no_peer_cert] != true ->
          {:error, :dist_tls_unverified}

        client[:verify] != :verify_peer ->
          {:error, :dist_tls_unverified}

        same_file?(server[:cacertfile], client_ca) or same_file?(client[:cacertfile], client_ca) ->
          {:error, :dist_ca_shared}

        true ->
          :ok
      end
    else
      _unreadable -> {:error, :dist_tls_unreadable}
    end
  end

  # The same file by device and inode, so a link or another spelling of the path cannot hide it.
  defp same_file?(a, b) when a in [nil, ""] or b in [nil, ""], do: false

  defp same_file?(a, b) do
    with {:ok, %File.Stat{major_device: d, inode: i}} <- File.stat(to_string(a)),
         {:ok, %File.Stat{major_device: ^d, inode: ^i}} <- File.stat(to_string(b)) do
      true
    else
      _ -> false
    end
  end

  @doc """
  The facts `check/1` reads, from the running VM: whether the node is clustered (`clustered?`, from the caller, which
  knows its configuration), the cookie in effect, the release's baked cookie, `MALACHI_DIST_TLS`, the distribution
  protocols and the options file the VM was started with (`-ssl_dist_optfile`, never a variable), and
  `MALACHI_TLS_CACERTFILE`.
  """
  @spec facts(boolean()) :: facts()
  def facts(clustered?) do
    %{
      clustered?: clustered?,
      cookie: cookie(),
      baked_cookie: baked_cookie(System.get_env("RELEASE_ROOT")),
      dist_tls: System.get_env("MALACHI_DIST_TLS"),
      proto_dist: init_values(:proto_dist),
      # Only the file the VM was started with: a variable naming another would vouch for options the distribution
      # does not use (a VM started with -ssl_dist_opt alone, say).
      optfile: List.first(init_values(:ssl_dist_optfile)),
      client_cacertfile: System.get_env("MALACHI_TLS_CACERTFILE")
    }
  end

  defp cookie do
    case Node.get_cookie() do
      :nocookie -> nil
      cookie -> Atom.to_string(cookie)
    end
  end

  @doc false
  # The cookie a release bakes into releases/COOKIE when it is built without one, or nil.
  @spec baked_cookie(Path.t() | nil) :: String.t() | nil
  def baked_cookie(root) when root in [nil, ""], do: nil

  def baked_cookie(root) do
    case File.read(Path.join([root, "releases", "COOKIE"])) do
      {:ok, text} -> String.trim(text)
      {:error, _} -> nil
    end
  end

  # Every value the VM was started with for `-flag`: `:init.get_argument/1` answers one list of charlists per
  # occurrence of the flag.
  defp init_values(flag) do
    case :init.get_argument(flag) do
      {:ok, occurrences} -> for values <- occurrences, value <- values, do: List.to_string(value)
      :error -> []
    end
  end
end
