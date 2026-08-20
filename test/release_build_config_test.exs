ExUnit.start()

defmodule SpruceGoose.ReleaseBuildConfigTest do
  @moduledoc """
  The governed release provenance suite was refutation-only: every script test
  drove a *fake* `mix` on a synthetic fixture repository, so the whole suite
  passed while the real project could not produce a release at all. The cycle-4
  end-to-end build proved that gap by failing with

      ** (Mix) Unknown release :spruce_goose. The available releases are: []

  because the real `mix.exs` declared no `:releases` block.

  These tests bind the real, committed `mix.exs` of this worktree. They are
  deliberately boot-free: the project file is evaluated in a separate OS
  process, no application, Repo, or release is started, and nothing outside a
  read of `mix.exs` happens.
  """
  use ExUnit.Case, async: true

  @project_root Path.expand("..", __DIR__)

  # Exactly the option keys this task's operator decision permits in the
  # predecessor worktree. Full CI/CD release configuration (paths, cookies,
  # runtime config providers, overlays, tarball/deployment shaping) is scoped to
  # successor tsk-20260813T140419Z-d8dbffc5 and must NOT appear here.
  @permitted_release_option_keys [:applications, :strip_beams]

  @deployment_option_keys [
    :cookie,
    :config_providers,
    :include_erts,
    :overlays,
    :path,
    :quiet,
    :rel_templates_path,
    :reboot_system_after_config,
    :runtime_config_path,
    :validate_compile_env,
    :version
  ]

  setup_all do
    %{config: read_project_config!()}
  end

  test "real mix.exs declares a release that Mix's own lookup can resolve", %{config: config} do
    app = Keyword.fetch!(config, :app)
    releases = Keyword.get(config, :releases, [])

    # `Mix.Release.lookup_release/2` raises "Unknown release" when
    # `config[:releases][name]` is falsy. Bind that exact condition.
    assert Keyword.keyword?(releases) and releases != [],
           "mix.exs declares no :releases block; `mix release #{app}` cannot resolve a release. " <>
             "Got: #{inspect(releases)}"

    opts = releases[app]

    assert opts,
           "mix.exs declares releases #{inspect(Keyword.keys(releases))} but none named " <>
             "#{inspect(app)}; scripts/build-governed-release invokes `mix release #{app}`."

    assert Keyword.keyword?(opts), "release options for #{inspect(app)} must be a keyword list"
  end

  test "exactly one release is declared, so an unnamed build is unambiguous", %{config: config} do
    releases = Keyword.get(config, :releases, [])

    assert length(Keyword.keys(releases)) == 1,
           "multiple releases require :default_release; this task declares a minimal single " <>
             "release. Got: #{inspect(Keyword.keys(releases))}"
  end

  test "the declared release stays minimal and carries no deployment configuration", %{
    config: config
  } do
    app = Keyword.fetch!(config, :app)
    opts = Keyword.get(config, :releases, [])[app] || []
    keys = Keyword.keys(opts)

    assert keys -- @permitted_release_option_keys == [],
           "release option keys must stay within #{inspect(@permitted_release_option_keys)} for " <>
             "this task; full release configuration is scoped to successor " <>
             "tsk-20260813T140419Z-d8dbffc5. Unexpected: " <>
             inspect(keys -- @permitted_release_option_keys)

    for key <- @deployment_option_keys do
      refute Keyword.has_key?(opts, key),
             "deployment option #{inspect(key)} is out of scope for this task"
    end

    refute Keyword.has_key?(config, :default_release)
  end

  test "the release names this application explicitly and permanently", %{config: config} do
    app = Keyword.fetch!(config, :app)
    opts = Keyword.get(config, :releases, [])[app] || []

    assert Keyword.get(opts, :applications) == [{app, :permanent}],
           "the release must name #{inspect(app)} explicitly as :permanent so the assembled " <>
             "release identity is declared rather than inferred. Got: " <>
             inspect(Keyword.get(opts, :applications))
  end

  test "the release preserves compile provenance chunks", %{config: config} do
    app = Keyword.fetch!(config, :app)
    opts = Keyword.get(config, :releases, [])[app] || []

    assert Keyword.get(opts, :strip_beams) == false
  end

  test "the escript entry point is preserved alongside the release", %{config: config} do
    # The governed CLI ships as an escript today. Adding a release must not
    # silently displace it.
    assert Keyword.get(config, :escript)[:main_module] == SpruceGoose.CLI
  end

  # Evaluates mix.exs in a separate OS process and returns the project keyword
  # list. Separate process so this suite never redefines the project module in
  # its own VM, and never starts Mix, deps, the application, or a release.
  defp read_project_config! do
    script = """
    Mix.start()
    Mix.env(:prod)
    {{:module, module, _, _}, _} = Code.eval_file("mix.exs")
    IO.write(:erlang.term_to_binary(module.project()) |> Base.encode64())
    """

    {out, status} =
      System.cmd("elixir", ["-e", script],
        cd: @project_root,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "prod"}, {"ERL_CRASH_DUMP_SECONDS", "0"}]
      )

    assert status == 0, "could not evaluate #{@project_root}/mix.exs:\n#{out}"

    out
    |> String.trim()
    |> Base.decode64!()
    |> :erlang.binary_to_term()
  end
end
