# Forgejo automatic delivery controller

The controller has two separate service modes. `review` holds only the reviewer
token and model command. `deliver` holds the merger token and can invoke one
digest-pinned deployment adapter owned by an allowlisted repository. Never put
both token files in either service's readable paths.

The example units make the opposite token inaccessible. The delivery unit also
makes the Pi credential directory inaccessible, so merge and deployment code
cannot invoke the model account. Keep repository deployment credentials outside
the review unit's readable paths and add matching `InaccessiblePaths` entries
for every allowlisted adapter.

The controller refuses unsupported repositories, stale pull-request heads,
missing checks, self-review, non-passing or stale review metadata, changed heads,
unapproved deployment adapters, missing receipts, unhealthy deployments, and
deployments without a ready rollback.

Copy `policy.example.json` outside the repository, replace every placeholder,
and keep it readable only by the controller user. A repository adapter receives
the exact head, merged commit, review ID, CI digest, and receipt path as
`DELIVERY_*` environment variables. It must deploy the exact merged commit,
retain or perform rollback on failure, run its health check, and atomically write
JSON containing at least:

```json
{"merged_commit":"40 lowercase hex characters","health":"healthy","rollback_ready":true}
```

Run the regression check with:

```sh
python3 -m unittest test/forgejo_delivery_controller_test.py
```
