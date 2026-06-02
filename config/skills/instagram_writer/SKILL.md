# instagram_writer

Platform-specific writer skill for Instagram caption and carousel narrative.

Source baseline:

- `config/skills/duoke_threads_copywriter/` Part 2 rules.

Output target:

- `runs/<run_id>/instagram/post.md`

Rules:

- Respect `config/meta/limits.json` (`caption_max_chars`, `hashtag_max`).
- Provide clear carousel page intent.
