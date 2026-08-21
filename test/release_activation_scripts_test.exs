ExUnit.start()

defmodule SpruceGoose.ReleaseActivationScriptsTest do
  use ExUnit.Case, async: true

  @deploy Path.expand("../scripts/deploy-sprucegoose", __DIR__)
  @rollback Path.expand("../scripts/rollback-sprucegoose", __DIR__)

  test "production activation requires an exact explicit confirmation after provenance validation" do
    text = File.read!(Path.expand("../scripts/activate-sprucegoose-release", __DIR__))
    assert text =~ ~s(scripts/validate-governed-release "$archive")
    assert text =~ ~s(expected="ACTIVATE:${target}:${task}")
    assert text =~ ~s([[ $confirmation == "$expected" ]])
    assert before?(text, "scripts/validate-governed-release", "if ! $activate")
    assert before?(text, "if ! $activate", "systemctl --user restart")
  end

  test "missing receipt and dirty worktree fail before validation or activation" do
    text = File.read!(Path.expand("../scripts/activate-sprucegoose-release", __DIR__))
    assert before?(text, "transferable receipt is missing", "scripts/validate-governed-release")
    assert before?(text, "dirty worktree refused", "scripts/validate-governed-release")
    assert before?(text, "scripts/validate-governed-release", "systemctl --user restart")
  end

  test "rollback requires prior activation evidence and restores on restart failure" do
    text = File.read!(Path.expand("../scripts/activate-sprucegoose-release", __DIR__))
    assert text =~ "rollback requires an existing --previous-activation-record"
    assert text =~ ~s(mv -T -- "$backup" "$install_dir")
    assert text =~ "service activation failed; previous release restored"
  end

  test "build normalizes the release cookie to the governed placeholder before archiving" do
    text = File.read!(Path.expand("../scripts/build-governed-release", __DIR__))
    assert text =~ "GOVERNED-PLACEHOLDER-COOKIE-PROVISION-AT-ACTIVATION"
    assert text =~ ~s(>"$release/releases/COOKIE")
    assert before?(text, "GOVERNED-PLACEHOLDER-COOKIE-PROVISION-AT-ACTIVATION", "tar --sort=name")
  end

  test "activation refuses a non-placeholder cookie and provisions the real one before the swap" do
    text = File.read!(Path.expand("../scripts/activate-sprucegoose-release", __DIR__))
    assert text =~ "staged release must carry the governed cookie placeholder"
    assert text =~ ~s(cp -p -- "$install_dir/releases/COOKIE" "$staged_cookie")

    assert before?(
             text,
             "staged release must carry the governed cookie placeholder",
             ~s(mv -T -- "$stage" "$install_dir")
           )

    assert before?(text, ~s(chmod 600 -- "$staged_cookie"), "systemctl --user restart")
  end

  test "public entry points are executable thin wrappers" do
    for path <- [@deploy, @rollback] do
      assert File.exists?(path)
      assert File.stat!(path).mode |> Bitwise.band(0o111) != 0
      assert File.read!(path) =~ "activate-sprucegoose-release"
    end
  end

  defp before?(text, left, right), do: :binary.match(text, left) < :binary.match(text, right)
end
