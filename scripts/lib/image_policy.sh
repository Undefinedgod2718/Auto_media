#!/usr/bin/env bash
# Resolve AUTO_MEDIA_VERSION / IMAGE_POLICY → pull vs local build.
# shellcheck disable=SC2034

AUTO_MEDIA_GHCR_OWNER="${AUTO_MEDIA_GHCR_OWNER:-undefinedgod2718}"

auto_media_load_env_file() {
  local root="$1"
  if [[ -f "${root}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${root}/.env"
    set +a
  fi
}

# Export AUTO_MEDIA_N8N_IMAGE / AUTO_MEDIA_GATEWAY_IMAGE when version is a release tag (v*).
auto_media_apply_image_env() {
  local ver="${AUTO_MEDIA_VERSION:-local}"
  if [[ "$ver" =~ ^v[0-9] ]]; then
    export AUTO_MEDIA_N8N_IMAGE="${AUTO_MEDIA_N8N_IMAGE:-ghcr.io/${AUTO_MEDIA_GHCR_OWNER}/auto-media-n8n:${ver}}"
    export AUTO_MEDIA_GATEWAY_IMAGE="${AUTO_MEDIA_GATEWAY_IMAGE:-ghcr.io/${AUTO_MEDIA_GHCR_OWNER}/auto-media-gateway:${ver}}"
    export AUTO_MEDIA_IMAGE_TAG="${ver}"
  else
    export AUTO_MEDIA_N8N_IMAGE="${AUTO_MEDIA_N8N_IMAGE:-auto-media-n8n:local}"
    export AUTO_MEDIA_GATEWAY_IMAGE="${AUTO_MEDIA_GATEWAY_IMAGE:-auto-media-gateway:local}"
    export AUTO_MEDIA_IMAGE_TAG="${AUTO_MEDIA_IMAGE_TAG:-local}"
  fi
}

# 0 = should pull; 1 = should build
auto_media_should_build_images() {
  local policy="${AUTO_MEDIA_IMAGE_POLICY:-auto}"
  local ver="${AUTO_MEDIA_VERSION:-local}"
  case "$policy" in
    pull) return 1 ;;
    build) return 0 ;;
    auto)
      if [[ "${WIZARD_FORCE_REBUILD:-0}" == "1" ]]; then
        return 0
      fi
      if [[ "$ver" =~ ^v[0-9] ]]; then
        return 1
      fi
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}

auto_media_compose_prepare_images() {
  local root="$1"
  shift
  local -a dc=("$@")
  auto_media_load_env_file "$root"
  auto_media_apply_image_env
  if auto_media_should_build_images; then
    echo "image_policy: compose build n8n gateway (AUTO_MEDIA_VERSION=${AUTO_MEDIA_VERSION:-local} policy=${AUTO_MEDIA_IMAGE_POLICY:-auto})" >&2
    "${dc[@]}" build n8n gateway
  else
    echo "image_policy: compose pull n8n gateway (${AUTO_MEDIA_N8N_IMAGE})" >&2
    "${dc[@]}" pull n8n gateway
  fi
}
