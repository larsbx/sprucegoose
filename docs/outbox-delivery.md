# Outbox delivery

SpruceGoose records task and inbox changes in `outbox_events` in the same PostgreSQL transaction as the authoritative change. Delivery is opt-in and at-least-once.

## Enable the dispatcher

Set both variables in the service environment:

```sh
OUTBOX_DISPATCHER_ENABLED=true
OUTBOX_HANDLER=MyApp.SpruceGooseEventHandler
```

The handler module must load and export `deliver/1`. Enabling the dispatcher with a missing or invalid handler fails startup. When enabled, one `Oban.Plugins.Cron` entry inserts `SpruceGoose.Outbox.Dispatcher` every minute. The worker does not enqueue its own successor.

## Delivery contract

The handler receives the immutable outbox event, including `id` and `event_key`. Consumers must deduplicate on one of those values. A retry delivers the same value.

Return `:ok` after successful delivery. Return `{:error, reason}` for a failed delivery. A raise, exit, throw, timeout, or other return value is also a failed attempt. The dispatcher bounds each handler call to 30 seconds by default.

The dispatcher claims one eligible row in a short transaction by moving its `available_at` timestamp to a lease. The lease is at least one minute and always exceeds the configured handler timeout by 30 seconds. The dispatcher then calls the handler outside that transaction and records the result before claiming another row. One poisoned event cannot roll back a sibling event's successful accounting.

Outcome updates match both the event ID and the claimed lease timestamp. If a newer worker has reclaimed the event, a stale worker cannot overwrite the newer lease or its accounting. If the process stops after external success but before the database update, the lease expires and the same event is delivered again.

After 20 failed attempts, an event enters `failed` state. Pending attempts use exponential backoff capped at one hour.

## Inspect and replay failed events

Only an actor with `admin` at global scope may inspect or replay failed events:

```sh
sprucegoose outbox failed
sprucegoose outbox replay EVENT_ID
```

Replay accepts only a failed event. It preserves the immutable event ID, event key, aggregate identity, event type, and payload. It resets delivery state and makes the event immediately eligible. The consumer must still deduplicate because the prior external delivery may have succeeded without a recorded acknowledgment.

These commands use the normal declared actor resolution. The current `--as` model is an operational attribution guardrail, not authenticated caller identity.
