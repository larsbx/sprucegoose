defmodule SpruceGoose.Deployment.ReleaseTest do
  use ExUnit.Case, async: true

  alias SpruceGoose.Deployment.Release

  @commit "0123456789abcdef0123456789abcdef01234567"
  @digest "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

  test "accepts only canonical immutable release identities" do
    assert {:ok, %Release{source_commit: @commit, image_digest: @digest}} =
             Release.new(@commit, @digest)

    for invalid <- [
          {"main", @digest},
          {String.upcase(@commit), @digest},
          {@commit, "latest"},
          {@commit, "sha256:" <> String.duplicate("g", 64)}
        ] do
      assert {:error, :invalid_release_identity} = Release.new(elem(invalid, 0), elem(invalid, 1))
    end
  end
end
