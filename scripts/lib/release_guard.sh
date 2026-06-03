#!/usr/bin/env bash
# GitHub Releases API + install.json SemVer guard (offline-safe).
set -euo pipefail

AUTO_MEDIA_GITHUB_REPO="${AUTO_MEDIA_GITHUB_REPO:-Undefinedgod2718/Auto_media}"

release_guard_curl() {
  local url="$1"
  local hdr=()
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    hdr=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl -fsSL "${hdr[@]}" -H "Accept: application/vnd.github+json" "$url"
}

# Prints latest release tag (e.g. v1.0.0) or empty on failure.
release_fetch_latest_tag() {
  local body tag
  body="$(release_guard_curl "https://api.github.com/repos/${AUTO_MEDIA_GITHUB_REPO}/releases/latest" 2>/dev/null)" || return 1
  tag="$(printf '%s' "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tag_name") or "")' 2>/dev/null)" || return 1
  [[ -n "$tag" ]] || return 1
  printf '%s' "$tag"
}

# Strip leading v and split semver; prints major minor patch or empty.
_release_parse() {
  local t="${1#v}"
  python3 -c 'import sys
p=sys.argv[1].split(".")
if len(p)!=3 or not all(x.isdigit() for x in p): sys.exit(1)
print(p[0], p[1], p[2])' "$t" 2>/dev/null || return 1
}

# Log upgrade class: patch | minor | major | unknown
release_compare_semver() {
  local from="${1:-}" to="${2:-}"
  if [[ -z "$from" || -z "$to" ]]; then
    echo "unknown"
    return 0
  fi
  local fa fb fc ta tb tc
  read -r fa fb fc < <(_release_parse "$from" || echo "")
  read -r ta tb tc < <(_release_parse "$to" || echo "")
  if [[ -z "$fa" || -z "$ta" ]]; then
    echo "unknown"
    return 0
  fi
  if [[ "$ta" -gt "$fa" ]]; then echo "major"; return 0; fi
  if [[ "$tb" -gt "$fb" ]]; then echo "minor"; return 0; fi
  if [[ "$tc" -gt "$fc" ]]; then echo "patch"; return 0; fi
  if [[ "$from" != "$to" ]]; then echo "downgrade"; return 0; fi
  echo "same"
}

release_guard_load_install() {
  local state="$1"
  INSTALL_RELEASE_TAG=""
  INSTALL_IMAGE_TAG=""
  INSTALL_SCHEMA=0
  [[ -f "$state" ]] || return 0
  eval "$(
    INSTALL_STATE="$state" python3 - <<'PY'
import json, os, shlex
from pathlib import Path
p = Path(os.environ["INSTALL_STATE"])
d = {}
if p.is_file():
    try:
        d = json.loads(p.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        pass
print(f"INSTALL_RELEASE_TAG={shlex.quote(str(d.get('release_tag') or ''))}")
print(f"INSTALL_IMAGE_TAG={shlex.quote(str(d.get('image_tag') or ''))}")
print(f"INSTALL_SCHEMA={int(d.get('schema_version', 0))}")
PY
  )"
}

# Report latest vs installed; sets RELEASE_GUARD_TARGET_TAG when API OK.
release_guard_report() {
  local root="$1"
  local state="${2:-${DATA_ROOT:-$root/data}/state/install.json}"
  local latest="" kind=""
  release_guard_load_install "$state"
  if latest="$(release_fetch_latest_tag 2>/dev/null)"; then
    export RELEASE_GUARD_LATEST_TAG="$latest"
    echo "release_guard: GitHub latest=${latest} installed=${INSTALL_RELEASE_TAG:-<none>}" >&2
    if [[ -n "${INSTALL_RELEASE_TAG:-}" ]]; then
      kind="$(release_compare_semver "$INSTALL_RELEASE_TAG" "$latest")"
      case "$kind" in
        major|minor)
          echo "release_guard: upgrade class=${kind} — read docs/RELEASE.md and git checkout tags/${latest}" >&2
          ;;
        patch)
          echo "release_guard: patch available — docker compose pull && bash scripts/post_docker_rebuild.sh" >&2
          ;;
        same)
          echo "release_guard: install release matches latest" >&2
          ;;
      esac
    fi
    if [[ -z "${AUTO_MEDIA_VERSION:-}" || "${AUTO_MEDIA_VERSION:-}" == "local" ]]; then
      echo "release_guard: hint: set AUTO_MEDIA_VERSION=${latest} in .env for pull-first (low-spec hosts)" >&2
    fi
  else
    echo "release_guard: WARN — cannot reach GitHub releases API (offline?); using AUTO_MEDIA_VERSION=${AUTO_MEDIA_VERSION:-local}" >&2
    latest="${AUTO_MEDIA_VERSION:-}"
  fi
  export RELEASE_GUARD_TARGET_TAG="${latest}"
  return 0
}

warn_release_git_drift() {
  local root="$1"
  local state="${2:-${DATA_ROOT:-$root/data}/state/install.json}"
  local describe=""
  release_guard_load_install "$state"
  describe="$(git -C "$root" describe --tags --exact-match 2>/dev/null || git -C "$root" describe --tags 2>/dev/null || echo "")"
  if [[ -n "${INSTALL_RELEASE_TAG:-}" && -n "$describe" && "$describe" != "$INSTALL_RELEASE_TAG" ]]; then
    echo "release_guard: warn: install.json release_tag=${INSTALL_RELEASE_TAG} but git describe=${describe}" >&2
    echo "release_guard: align repo: git fetch --tags && git checkout tags/${INSTALL_RELEASE_TAG}" >&2
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  # shellcheck source=scripts/lib/image_policy.sh
  source "$(dirname "${BASH_SOURCE[0]}")/image_policy.sh"
  auto_media_load_env_file "$ROOT"
  export DATA_ROOT="${DATA_ROOT:-$ROOT/data}"
  release_guard_report "$ROOT"
  warn_release_git_drift "$ROOT"
fi
