unless Process.whereis(ExUnit.Server), do: ExUnit.start()

defmodule SpruceGoose.PapaPg19Beta3DevTest do
  use ExUnit.Case, async: true

  @script "ops/papa-development/prepare-papa-pg19beta3-dev.sh"

  test "Papa development preparation is beta3-bound and cannot target Mama or production" do
    assert File.regular?(@script), "missing Papa PG19 Beta 3 preparation script"
    assert Bitwise.band(File.stat!(@script).mode, 0o111) == 0o111

    body = File.read!(@script)

    assert body =~ "PAPA_PG19_DEV_ONLY"
    assert body =~ "ubuntu-8gb-evergreen"
    assert body =~ "for command in curl sha256sum tar make gcc python3 bison flex"
    assert before?(body, "for command in curl", "install -d -m 0700")
    assert body =~ "BISON_PKGDATADIR"
    assert body =~ "papa-pg19beta3-dev/tools/usr/share/bison"
    assert body =~ "postgresql-19beta3.tar.gz"
    assert body =~ "68fb060a0d844c133065372eda19dec726e1280046a8b3405db70f5ebc0fa923"
    assert body =~ "PostgreSQL 19beta3"
    assert body =~ "never-promote"
    assert body =~ "umask 077"
    assert body =~ "--auth-local=trust"
    assert body =~ "--auth-host=reject"
    assert body =~ "listen_addresses="

    refute body =~ "ssh mama"
    refute body =~ "100.69.235.63"
    refute body =~ "/home/admin-papa/pgdata"
    refute body =~ "sprucegoose-postgresql.service"
    refute body =~ "sprucegoose.service"
  end

  defp before?(body, first, second) do
    {first_at, _} = :binary.match(body, first)
    {second_at, _} = :binary.match(body, second)
    first_at < second_at
  end
end
