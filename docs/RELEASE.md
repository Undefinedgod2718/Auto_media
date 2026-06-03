# Releases and GHCR images

Auto Media ships **pre-built** n8n and gateway images on [GitHub Container Registry](https://github.com/Undefinedgod2718/Auto_media/pkgs/container/auto-media-n8n) (public). Use this on **low-spec hosts** to avoid `docker compose build` OOM.

## SRE rule: one release = git tag + images + config

GHCR images only bake container contents (`/data/scripts`, CLIs). You must still align the **git tree**:

```bash
git fetch --tags
git checkout tags/v0.1.0   # same tag as AUTO_MEDIA_VERSION
```

Then pull and refresh runtime:

```bash
# .env
AUTO_MEDIA_VERSION=v0.1.0
AUTO_MEDIA_IMAGE_POLICY=auto

docker compose pull n8n gateway
docker compose up -d --remove-orphans n8n gateway
bash scripts/post_docker_rebuild.sh
```

`data/state/install.json` records `release_tag` / `image_tag` (schema v2) for upgrade guards.

## Maintainer: publish a release

1. Merge to `main`, verify CI green.
2. Tag SemVer and push:

   ```bash
   git tag -a v0.1.0 -m "v0.1.0"
   git push origin v0.1.0
   ```

3. [`.github/workflows/release.yml`](../.github/workflows/release.yml) builds and pushes:
   - `ghcr.io/undefinedgod2718/auto-media-n8n:<tag>`
   - `ghcr.io/undefinedgod2718/auto-media-gateway:<tag>`
4. GitHub Release gets notes + workflow JSON attachments.

First publish after merging docker-helper fixes: use **`v0.1.0`** (or `v1.0.0` if you treat B′ as 1.0).

## Consumer: image policy

| `AUTO_MEDIA_IMAGE_POLICY` | Behavior |
|-------------------------|----------|
| `auto` (default) | `AUTO_MEDIA_VERSION=v*` → **pull**; `local` or dev → **build** |
| `pull` | Always `compose pull` |
| `build` | Always `compose build` (Dev Container / hacking) |

`WIZARD_FORCE_REBUILD=1` forces **build** even when version is `v*`.

## Upgrade classes (wizard / `release_guard.sh`)

- **patch**: pull + `post_docker_rebuild`
- **minor/major**: read release notes, `git checkout` tag, re-import n8n workflows if noted
- Offline: set `AUTO_MEDIA_VERSION` manually; API check is best-effort

Check latest vs installed:

```bash
bash scripts/lib/release_guard.sh
```

## Local development (unchanged)

```bash
AUTO_MEDIA_VERSION=local
AUTO_MEDIA_IMAGE_POLICY=auto
docker compose build n8n gateway
docker compose up -d n8n gateway
```

## Troubleshooting Release CI

| Symptom | Cause | Fix |
|---------|-------|-----|
| Actions **buildx** + `build-cache-backends` | `type=gha` cache without `actions: write` | Fixed in `release.yml`; merge fix, re-run Release |
| `docker pull` **denied** | Workflow failed or GHCR package still **private** | Actions green → set package **Public** under GitHub Packages |
| No GitHub Release | `github-release` skipped after build failure | Fix build, re-trigger tag or **workflow_dispatch** |

Re-run after fixing workflow on `main`:

```bash
# Option A: new patch tag
git pull origin main
git tag -a v0.1.1 -m "v0.1.1"
git push origin v0.1.1

# Option B: move v0.1.0 (only if no successful publish yet)
git push origin :refs/tags/v0.1.0
git tag -fa v0.1.0 -m "v0.1.0"
git push origin v0.1.0 -f
```

## Not distributed

- No PyPI/npm for `auto-media-tools` (repo-only `uv run`).
- OAuth secrets stay in `data/secrets/` (never in images).
