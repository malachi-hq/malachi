defmodule Malachi.Test.CertFixtures do
  @moduledoc """
  Loads the test X.509 certificate fixtures under `test/support/fixtures/certs/`.

  These are **public** self-signed certificates only: a certificate carries no secret (just the public key,
  subject and SANs), so committing them is safe (unlike a private key, which is never checked in). They are
  throwaway test material generated with `openssl req -x509`.

  Fixtures:

    * `svc_producer`, CN `svc-producer`, SAN `URI:spiffe://malachi/svc-producer` + `DNS:producer.internal`
    * `plain_admin`, CN `plain-admin`, no SAN extension
    * `multi_uri`, CN `multi-svc`, SANs `URI:spiffe://malachi/first`, `URI:spiffe://malachi/second`, `DNS:multi.internal`
  """

  @certs_dir Path.join(__DIR__, "fixtures/certs")

  @doc "The DER-encoded certificate `name` (e.g. `\"svc_producer\"`)."
  @spec der(String.t()) :: binary()
  def der(name) do
    [{:Certificate, der, :not_encrypted}] = name |> pem() |> :public_key.pem_decode()
    der
  end

  @doc "The raw PEM text of certificate `name`."
  @spec pem(String.t()) :: String.t()
  def pem(name), do: File.read!(Path.join(@certs_dir, "#{name}.pem"))

  @doc """
  Generates a throwaway self-signed server certificate and key (CN `localhost`, one day) under `dir`, and
  returns their paths. Generated rather than committed because a private key is never checked in; openssl
  ships on the CI image and is what the project's own cert scripts use.
  """
  @spec server_cert!(Path.t()) :: %{certfile: Path.t(), keyfile: Path.t()}
  def server_cert!(dir) do
    File.mkdir_p!(dir)
    certfile = Path.join(dir, "cert.pem")
    keyfile = Path.join(dir, "key.pem")

    args = ~w(req -x509 -newkey rsa:2048 -nodes -keyout #{keyfile} -out #{certfile} -days 1 -subj /CN=localhost)
    {_out, 0} = System.cmd("openssl", args, stderr_to_stdout: true)
    %{certfile: certfile, keyfile: keyfile}
  end

  # P-256 keys: generated in milliseconds, where an RSA key can take a second.
  @ec_key ~w(-newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes)

  @doc """
  Generates a throwaway private CA under `dir`, as `<name>.pem` and `<name>-key.pem`, valid one day, and returns
  their paths. A private CA is the shape `--cacert` is for, and what `scripts/generate-dist-certs.sh` produces; a
  self-signed leaf cannot stand in, since OTP refuses a self-signed peer even when it is named as the CA.
  """
  @spec ca!(Path.t(), String.t()) :: %{cert: Path.t(), key: Path.t()}
  def ca!(dir, name \\ "ca") do
    File.mkdir_p!(dir)
    cert = Path.join(dir, "#{name}.pem")
    key = Path.join(dir, "#{name}-key.pem")

    openssl!(
      ["req", "-x509" | @ec_key] ++ ["-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=Malachi Test CA #{name}"]
    )

    %{cert: cert, key: key}
  end

  @doc """
  Generates under `dir` a certificate signed by `ca` (from `ca!/2`), as `<name>.pem` and `<name>-key.pem`, for the
  common name `cn` and the subject alternative names `sans` (`"DNS:localhost"`, `"IP:127.0.0.1"`), which is what
  host name verification reads. Returns their paths.
  """
  @spec leaf!(%{cert: Path.t(), key: Path.t()}, Path.t(), String.t(), String.t(), [String.t()]) ::
          %{cert: Path.t(), key: Path.t()}
  def leaf!(ca, dir, name, cn, sans) do
    File.mkdir_p!(dir)
    cert = Path.join(dir, "#{name}.pem")
    key = Path.join(dir, "#{name}-key.pem")
    csr = Path.join(dir, "#{name}.csr")
    ext = Path.join(dir, "#{name}.ext")

    openssl!(["req" | @ec_key] ++ ["-keyout", key, "-out", csr, "-subj", "/CN=#{cn}"])
    File.write!(ext, "subjectAltName=#{Enum.join(sans, ",")}\n")

    openssl!(
      ~w(x509 -req -in #{csr} -CA #{ca.cert} -CAkey #{ca.key} -CAcreateserial -out #{cert} -days 1 -extfile #{ext})
    )

    File.rm!(csr)
    File.rm!(ext)
    %{cert: cert, key: key}
  end

  @doc """
  A private CA and one server certificate signed by it under `dir`: for `cn`, with `sans` (by default `DNS:<cn>`).
  Returns the paths of the CA certificate, the server certificate and its key.
  """
  @spec ca_signed!(Path.t(), String.t(), [String.t()] | nil) :: %{ca: Path.t(), cert: Path.t(), key: Path.t()}
  def ca_signed!(dir, cn \\ "localhost", sans \\ nil) do
    ca = ca!(dir)
    leaf = leaf!(ca, dir, "server", cn, sans || ["DNS:#{cn}"])
    %{ca: ca.cert, cert: leaf.cert, key: leaf.key}
  end

  defp openssl!(args) do
    case System.cmd("openssl", args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> raise "openssl #{hd(args)} exited #{status}: #{out}"
    end
  end
end
