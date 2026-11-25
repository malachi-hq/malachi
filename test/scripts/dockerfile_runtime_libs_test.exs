defmodule DockerfileRuntimeLibsTest do
  # The release image ships OpenSSL and zlib from Alpine packages newer than the pinned base images, as
  # explicit minimum versions. The builder stage must install the patched OpenSSL because the runner copies
  # libssl.so.3 and libcrypto.so.3 from it, and that copy is what OTP's crypto NIF loads; the runner pins
  # the same packages plus zlib so the apk database image scanners read matches what ships. Dropping a
  # minimum, or turning it into a bare package name, would silently ship the vulnerable versions again.
  use ExUnit.Case, async: true

  @dockerfile Path.expand("../../Dockerfile", __DIR__)

  @openssl ["libssl3>=3.5.9-r1", "libcrypto3>=3.5.9-r1"]
  @zlib "zlib>=1.4-r0"

  setup_all do
    {:ok, stages: stages(File.read!(@dockerfile))}
  end

  test "the Dockerfile has a builder and a runner stage", %{stages: stages} do
    assert Map.has_key?(stages, "builder")
    assert Map.has_key?(stages, "runner")
  end

  test "the builder installs each patched OpenSSL package exactly once, in an apk add", %{stages: stages} do
    for constraint <- @openssl do
      assert apk_constraints(stages["builder"]) |> Enum.count(&(&1 == constraint)) == 1,
             "builder stage must apk add '#{constraint}' exactly once"
    end
  end

  test "the runner installs zlib and the patched OpenSSL packages in an apk add", %{stages: stages} do
    runner = apk_constraints(stages["runner"])

    for constraint <- [@zlib | @openssl] do
      assert constraint in runner, "runner stage must apk add '#{constraint}'"
    end
  end

  test "no stage installs one of these packages without a minimum version", %{stages: stages} do
    for {stage, text} <- stages, package <- apk_packages(text), package in ~w(zlib libssl3 libcrypto3) do
      flunk("#{stage} stage installs #{package} with no minimum version")
    end
  end

  test "the runner still takes its OpenSSL libraries from the builder", %{stages: stages} do
    assert stages["runner"] =~ ~r{^COPY --from=builder /usr/lib/libssl\.so\.3 /usr/lib/$}m
    assert stages["runner"] =~ ~r{^COPY --from=builder /usr/lib/libcrypto\.so\.3 /usr/lib/$}m
  end

  describe "the checks themselves" do
    test "a constraint without >= is not taken as a minimum" do
      text = "FROM alpine AS runner\nRUN apk add --no-cache zlib libssl3\n"
      assert apk_constraints(stages(text)["runner"]) == []
      assert apk_packages(stages(text)["runner"]) == ["zlib", "libssl3"]
    end

    test "a minimum in a comment or outside apk add does not count" do
      text = "FROM alpine AS builder\n# apk add 'libssl3>=3.5.9-r1'\nRUN echo 'libssl3>=3.5.9-r1'\n"
      assert apk_constraints(stages(text)["builder"]) == []
    end
  end

  # Splits the file into `%{stage_name => text}` on `FROM ... AS name`.
  defp stages(text) do
    ~r/^FROM\s+\S+\s+AS\s+(\w+)\s*$/m
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.drop_while(&(not String.starts_with?(&1, "FROM")))
    |> Enum.chunk_every(2)
    |> Map.new(fn [from, body] ->
      [_, name] = Regex.run(~r/AS\s+(\w+)/, from)
      {name, body}
    end)
  end

  # Every word of every `RUN apk add` instruction (continuation lines joined), quotes stripped.
  defp apk_words(text) do
    text
    |> String.replace(~r/\\\n/, " ")
    |> String.split("\n")
    |> Enum.filter(&(&1 =~ ~r/^RUN\s+apk\s+add\b/))
    |> Enum.flat_map(&String.split/1)
    |> Enum.map(&String.trim(&1, "'"))
  end

  defp apk_constraints(text), do: text |> apk_words() |> Enum.filter(&String.contains?(&1, ">="))

  defp apk_packages(text) do
    text
    |> apk_words()
    |> Enum.reject(&(&1 in ~w(RUN apk add) or String.starts_with?(&1, "-") or String.contains?(&1, ">=")))
  end
end
