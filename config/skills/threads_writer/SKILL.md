# threads_writer

Platform-specific writer skill for Threads content.

Source baseline:

- `config/skills/duoke_threads_copywriter/`

Output target:

- `runs/<run_id>/threads/post.md`

Rules:

- Respect `config/meta/limits.json` (`threads.chars_per_post`).
- Keep thread chain readable; split by post.
