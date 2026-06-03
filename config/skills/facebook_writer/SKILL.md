# facebook_writer

Platform-specific writer skill for Facebook message copy.

Output target:

- `runs/<run_id>/facebook/post.md`

Rules:

- Respect `config/meta/limits.json` (`facebook.message_max_chars`).
- Keep message concise and share-friendly.
