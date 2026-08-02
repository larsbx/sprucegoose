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
