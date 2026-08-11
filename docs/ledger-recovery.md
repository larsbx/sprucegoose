# Ledger recovery intake

The retired ledger is historical recovery evidence. Normal SpruceGoose operation does not import it.

## Authorization and configuration

Parity and import require an active actor with `admin` at global scope. Authorization runs before filesystem or database access.

Configure a dedicated intake directory and bounded input limits:

```sh
LEDGER_IMPORT_ROOT=/path/to/recovery-intake
LEDGER_MAX_BYTES=1048576
LEDGER_MAX_LINES=10000
LEDGER_OPEN_TIMEOUT_MS=1000
```

The reader accepts only regular files beneath that root. It rejects final-path and parent-directory symlinks, non-regular files, files above either limit, and files whose descriptor no longer matches the opened path. The complete open/inspection/read runs in a killable bounded worker, so a pathname swapped to a blocking FIFO cannot hold the request indefinitely.

Parity is read-only:

```sh
sprucegoose ledger parity /path/to/recovery-intake/ledger.txt --as ADMIN
```

## Offline import

Import additionally requires all of these conditions:

- `LEDGER_RECOVERY_MODE=true`;
- `LEDGER_RECOVERY_DATABASE` exactly matches the connected database;
- the connected database's durable `authority_instance_identity` row is explicitly marked `recovery` on the offline clone (new databases start as `live`);
- the connected database is not the build-time live authority database identity;
- the isolated database authority row remains in legacy `tuxedo` mode.

After cloning the authority database into the isolated recovery PostgreSQL instance, mark only that offline copy:

```sql
UPDATE authority_instance_identity SET purpose = 'recovery' WHERE singleton;
```

Never run that statement against the live authority. Environment variables alone cannot turn a default `live` instance into a recovery target.

Run import only against an isolated recovery database:

```sh
sprucegoose ledger import /path/to/recovery-intake/ledger.txt --as ADMIN
```

Each successful import writes an immutable receipt in the same transaction. The receipt records the actor ID and name, root-relative source name, source SHA-256, byte and line counts, task and dependency counts, and timestamp. It does not store the absolute host path or file contents.

Import does not authorize an authority change, live database mutation, deployment, or production restoration. Recovery promotion remains a separate governed decision.
