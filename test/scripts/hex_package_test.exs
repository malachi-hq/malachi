defmodule HexPackageTest do
  # `mix hex.publish` ships what `package/0` names and nothing else. The checks below pin the parts Hex and its
  # users read (description, maintainers, license, links) and the allow-list in `files`, so a later edit that adds
  # tests, benchmarks or generated docs to the package, or drops a file a published package needs, fails here
  # rather than at publish time. Publishing itself stays with the maintainer; this never calls Hex.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp package, do: Mix.Project.config()[:package]

  describe "metadata Hex shows on the package page" do
    test "the description is the one the project declares, and it is a real sentence" do
      assert package()[:description] == Mix.Project.config()[:description]
      assert String.length(package()[:description]) in 40..300
    end

    test "the package names at least one maintainer" do
      assert [_ | _] = package()[:maintainers]
      assert Enum.all?(package()[:maintainers], &(is_binary(&1) and &1 != ""))
    end

    test "the license is MIT, the one the repository's LICENSE file carries" do
      assert package()[:licenses] == ["MIT"]
      assert File.read!(Path.join(@root, "LICENSE")) =~ "MIT License"
    end

    test "links point at the documentation site, the repository and its releases" do
      links = package()[:links]
      config = Mix.Project.config()

      assert links["Documentation"] == config[:site_url]
      assert links["GitHub"] == config[:source_url]
      assert links["Releases"] == config[:source_url] <> "/releases"
    end
  end

  describe "files allow-list" do
    @files Mix.Project.config()[:package][:files]

    test "ships the code, the runtime config and the release templates a node needs" do
      for needed <- ~w(lib priv config rel mix.exs README.md LICENSE SECURITY.md) do
        assert needed in @files, "#{needed} is missing from the package files"
      end
    end

    test "every listed path exists in the repository, so a rename cannot silently drop it" do
      for entry <- @files do
        assert File.exists?(Path.join(@root, entry)), "files lists #{entry}, which does not exist"
      end
    end

    test "does not ship tests, benchmarks, the TUI, the generated docs or CI configuration" do
      for excluded <- ~w(test benchmark tui docs doc .github scripts deploy) do
        refute excluded in @files, "#{excluded} must not be in the published package"
      end
    end
  end
end
