defmodule SiteImagesWorkflowTest do
  # The site's images live in Git LFS (#373), whose free quota counts every download and blocks the account
  # once spent. These pin how the two workflows that build the site reach them: each image is checked from its
  # pointer before anything is fetched, the fetch is cached, and a fork's pull request never fetches at all.
  # Text checks, as release_workflow_test does.
  use ExUnit.Case, async: true

  alias Malachi.Test.WorkflowText

  @fork "${{ github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository }}"
  @cache_key "key: site-images-${{ hashFiles('site/blog/**/*.png', 'site/kit/**/*.png') }}"

  defp step(job, name) do
    job |> String.split(~r/^      - name: /m) |> tl() |> Enum.find(&String.starts_with?(&1, name))
  end

  defp job(file, id), do: file |> WorkflowText.path() |> File.read!() |> WorkflowText.jobs() |> Map.fetch!(id)

  defp position(job, text), do: job |> :binary.match(text) |> elem(0)

  describe "ci.yml, the docs build of Code Quality" do
    setup do
      %{job: job("ci.yml", "quality")}
    end

    test "checks out without LFS and keeps no credential, so only the script fetches", %{job: job} do
      checkout = step(job, "📥 Checkout code")
      refute checkout =~ "lfs: true"
      assert checkout =~ "persist-credentials: false"
    end

    test "caches the LFS objects by the pointers' hash, never for a fork's pull request", %{job: job} do
      cache = step(job, "🖼️ Cache the site's images")
      assert cache =~ "path: .git/lfs/objects"
      assert cache =~ @cache_key

      assert cache =~
               "if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository"
    end

    test "a fork only checks the pointers; anything else checks, then fetches", %{job: job} do
      fetch = step(job, "🖼️ Fetch the site's images")
      assert fetch =~ "FORK: #{@fork}"

      assert fetch =~
               ~s(if [ "$FORK" = true ]; then scripts/site-images-pull.sh --check-only; else scripts/site-images-pull.sh; fi)
    end

    test "the site check accepts pointers only for a fork, which never fetched the images", %{job: job} do
      check = step(job, "🏠 Check the landing page is staged")
      assert check =~ "FORK: #{@fork}"

      assert check =~
               ~s(if [ "$FORK" = true ]; then mix malachi.docs.site --check --lfs-pointers; else mix malachi.docs.site --check; fi)
    end

    test "the images are in place before the docs are built", %{job: job} do
      assert position(job, "scripts/site-images-pull.sh") < position(job, "mix docs --warnings-as-errors")
      assert position(job, "🖼️ Cache the site's images") < position(job, "🖼️ Fetch the site's images")
    end
  end

  describe "pages.yml, the published site" do
    setup do
      %{job: job("pages.yml", "build")}
    end

    test "caches, checks and fetches the images before the docs are built", %{job: job} do
      assert step(job, "🖼️ Cache the site's images") =~ @cache_key
      assert step(job, "🖼️ Fetch the site's images") =~ "run: scripts/site-images-pull.sh\n"
      refute job =~ "--check-only"
      assert position(job, "scripts/site-images-pull.sh") < position(job, "mix docs")
      refute job =~ "lfs: true"
    end
  end

  test "the images the script fetches are the ones .gitattributes stores in LFS" do
    attributes = File.read!(Path.expand("../../.gitattributes", __DIR__))
    script = File.read!(Path.expand("../../scripts/site-images-pull.sh", __DIR__))

    for pattern <- ["site/blog/**/*.png", "site/kit/**/*.png"] do
      assert attributes =~ "#{pattern} filter=lfs diff=lfs merge=lfs -text\n"
      assert script =~ "':(glob)#{pattern}'"
    end
  end
end
