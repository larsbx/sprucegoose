# Mama authority operations

SpruceGoose PostgreSQL and the persistent control-plane release run on `mama`.
Evergreen retains the stopped pre-cutover database as rollback state and reaches
the mama Unix socket through `sprucegoose-remote-client.service`. No SpruceGoose
TCP listener is exposed and there is no application-level dual-write path.

The canonical bridge unit is `sprucegoose-remote-client.service`. Install it on
evergreen with:

```sh
install -m 0644 ops/mama-authority/sprucegoose-remote-client.service \
  "$HOME/.config/systemd/user/sprucegoose-remote-client.service"
systemctl --user daemon-reload
systemctl --user disable --now sprucegoose.service
systemctl --user enable --now sprucegoose-remote-client.service
./sprucegoose version
```

## Cross-host Systemwide SOP authority

Papa is the canonical policy source while the authoritative SpruceGoose service
runs on mama. The two identical absolute paths are different filesystems; path
identity is therefore never accepted as content identity.

The installed thin client reads
`~/.config/sprucegoose/sop-authority.json` before opening the forwarded Unix
socket. When that policy exists, every command hashes Papa's canonical SOP and
retrieves mama's digest over batch-mode SSH. A missing source, failed SSH check,
invalid policy, or digest mismatch refuses before socket access. This is a
secondary consistency control, not the trust anchor: direct authority calls do
not pass through Papa's client.

Mama's production release must set `SYSTEMWIDE_SOP_EXPECTED_SHA256` in its
mode-`0600` service environment. `SopGate` reads and hashes Mama's configured
SOP itself and refuses task creation, re-acknowledgment, start, and revision
authorization when the bytes do not match that deployment pin. Production
startup refuses a missing or malformed pin.

Publication is event-driven. `sprucegoose-sop-authority-sync.path` watches only
the canonical SOP and starts a oneshot publisher. The publisher streams the
retrieved Papa bytes to mama, verifies the digest there, fsyncs the temporary
file, and atomically replaces the authority copy. There is no polling timer.
Publication does not update Mama's deployment pin. After any byte change the
service therefore refuses governed mutations until a governed deployment
verifies those exact Mama bytes, advances the pin, and restarts the application.

Install or update the operational controls on Papa without restarting or
releasing the mama application:

```sh
install -d -m 0700 "$HOME/.config/sprucegoose"
install -d -m 0755 "$HOME/.local/libexec"
install -m 0644 scripts/sprucegoose-sop-publish.py \
  "$HOME/.local/libexec/sprucegoose-sop-publish.py"
install -m 0600 ops/mama-authority/sop-authority.json \
  "$HOME/.config/sprucegoose/sop-authority.json"
install -m 0644 ops/mama-authority/sprucegoose-sop-authority-sync.service \
  "$HOME/.config/systemd/user/sprucegoose-sop-authority-sync.service"
install -m 0644 ops/mama-authority/sprucegoose-sop-authority-sync.path \
  "$HOME/.config/systemd/user/sprucegoose-sop-authority-sync.path"
systemctl --user daemon-reload
systemctl --user start sprucegoose-sop-authority-sync.service
systemctl --user enable --now sprucegoose-sop-authority-sync.path
./sprucegoose version
```

For an application deployment, advance the Mama trust anchor only after byte
publication succeeds:

```sh
systemctl --user start sprucegoose-sop-authority-sync.service
digest="$(sha256sum "/home/admin-papa/.openclaw/vaults/openclaw-system/10-sop/Systemwide SOP.md" | cut -d' ' -f1)"
test "$digest" = "$(ssh mama sha256sum "/home/admin-papa/.openclaw/vaults/openclaw-system/10-sop/Systemwide SOP.md" | cut -d' ' -f1)"
# Through the governed mode-0600 service-environment deployment mechanism, set:
# SYSTEMWIDE_SOP_EXPECTED_SHA256=$digest
ssh mama systemctl --user restart sprucegoose.service
```

Do not edit only the pin, accept a caller-supplied digest inside a task command,
or update the running application's environment dynamically. The verified SOP
bytes and pin are one release input, and Mama independently hashes the bytes.

Verification must include all controls:

1. Matched Papa/mama digests allow `./sprucegoose version`.
2. Mama's service-environment pin equals that digest; verify equality without
   printing the rest of the secret-bearing environment file.
3. `mix test test/sop_version_test.exs test/cli_database_test.exs:289` proves
   locally valid bytes with a wrong pin cannot create, re-acknowledge, or start.
4. A temporary client policy naming deliberately different local bytes refuses
   with `Systemwide SOP authority mismatch` before socket access. Never alter
   either live SOP to produce the negative control.

If publication fails, leave the path unit active, inspect
`journalctl --user -u sprucegoose-sop-authority-sync.service`, and correct SSH or
filesystem access. Do not disable the client policy, start Papa's stale local
application service, or bypass the socket bridge.

The final pre-cutover dump is retained on both hosts at
`~/migration-snapshots/sg-final-precutover-20260802T143504Z.dump`, mode `0400`.
Its adjacent SHA-256 file verifies transport integrity, and its core-count file
records the Project, Roadmap, Workflow, Task, and TODO snapshot used for parity.

## Rollback

Rollback is an authority move, not a client fallback. First stop the mama
application service to freeze writes. Dump mama's current `spruce_goose_dev`,
verify its SHA-256, restore it over evergreen's stopped database, and compare
the five core counts. Only then stop and disable the bridge and start
evergreen's local `sprucegoose.service`. Never run both application services.

The pre-cutover dump is a last-known-good recovery point, but restoring it after
new mama writes would discard those writes. Prefer a fresh frozen mama dump:

```sh
ssh mama systemctl --user stop sprucegoose.service
# pg_dump mama, copy and verify it, then restore it while evergreen is stopped.
systemctl --user disable --now sprucegoose-remote-client.service
systemctl --user enable --now sprucegoose.service
./sprucegoose version
```

If the bridge fails, inspect `systemctl --user status
sprucegoose-remote-client.service` and SSH reachability. Do not automatically
start the stale evergreen authority.
