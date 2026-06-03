# ADR: Run Layout by Platform

## Status

Accepted

## Decision

Use platform-scoped artifacts under each run:

`runs/<run_id>/{threads,instagram,facebook}/post.md`

Images:

- `runs/<run_id>/instagram/carousel/*.png`
- `runs/<run_id>/threads/media/*.png`
- `runs/<run_id>/facebook/media/*.png`

Legacy `runs/<run_id>/post.md` remains as compatibility shim during migration.
