> **Archived.** Current docs: [INSTALL.md](../INSTALL.md), [VERIFY.md](../VERIFY.md), or [README.md#architecture](../../README.md#architecture).

# Executive installer — suggested Git workflow

Use a feature branch (e.g. `feat/executive-installer`) and land changes in separate commits:

1. `feat(installer): interactive setup_wizard + env-check curl`
2. `feat(forwarder): compose forwarder service + forwarder_ctl`
3. `feat(console): global engine priority editor (engines.copy/svg)`
4. `feat(vc): config version history + rollback`
5. `fix(consistency): strict-stage drift, dashboard port docs, dead-config note`

Run `bash scripts/amctl.sh doctor` before each commit. Do not force-push `main`.
