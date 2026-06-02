# ADR: Run State and Idempotency

## Status

Accepted

## Decision

Use `runs/<run_id>/state.json` as the single source of truth for order and idempotency.

Key fields:

- `stage_seq`
- `stage`
- `locks`
- `hitl.active_wait`

Rules:

- Stage is monotonic by default.
- Publish scripts require `stage_seq >= 7` (`pre_publish_ok`).
- Repeated publish with successful prior result becomes `skipped: already_published`.
