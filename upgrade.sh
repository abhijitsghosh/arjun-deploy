#!/usr/bin/env bash
#
# Arjun in-place upgrade — safe, image-only roll.
#
#   curl -sL https://raw.githubusercontent.com/abhijitsghosh/arjun-deploy/main/upgrade.sh | bash
#   curl -sL https://raw.githubusercontent.com/abhijitsghosh/arjun-deploy/main/upgrade.sh | bash -s -- --image-tag 0.2.0
#
# Rolls ONLY the Container App image to the target version. The database is
# untouched, and the app runs its Flyway migrations on boot — so code AND schema
# upgrade with zero data loss. It deliberately does NOT re-run the install stack,
# which would mint a new resource suffix and stand up a fresh, empty database —
# losing every attestation, the one thing that cannot be regenerated.
#
# Designed for Azure Cloud Shell (Bash), same as install.sh.
#
set -euo pipefail

RG="rg-arjun"
APP="arjun-app"
IMAGE_REPO="ghcr.io/abhijitsghosh/arjun"
# Version feed. The domain (arjunsec.run) is the single source of truth — served fresh (no-store),
# and the one place the version is updated. The GitHub mirror is a fallback if the domain is
# unreachable.
VERSION_URLS=(
  "https://arjunsec.run/version.json"
  "https://raw.githubusercontent.com/abhijitsghosh/arjun-deploy/main/version.json"
)
TAG=""

latest_version() {
  local url body ver
  for url in "${VERSION_URLS[@]}"; do
    body="$(curl -fsSL "$url" 2>/dev/null)" || continue
    ver="$(printf '%s' "$body" | (jq -r '.latest' 2>/dev/null || sed -n 's/.*"latest":"\([^"]*\)".*/\1/p'))"
    [[ -n "$ver" && "$ver" != "null" ]] && { printf '%s' "$ver"; return 0; }
  done
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--image-tag)      TAG="${2:-}"; shift 2;;
    -g|--resource-group) RG="${2:-}"; shift 2;;
    -n|--app)            APP="${2:-}"; shift 2;;
    -h|--help) echo "Usage: upgrade.sh [--image-tag <ver>] [--resource-group rg-arjun] [--app arjun-app]"; exit 0;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

az account show >/dev/null 2>&1 || { echo "ERROR: not signed in. Run 'az login' first (automatic in Cloud Shell)."; exit 1; }

# Target version: explicit --image-tag, else the latest published.
if [[ -z "$TAG" ]]; then
  TAG="$(latest_version || true)"
fi
[[ -z "$TAG" || "$TAG" == "null" ]] && { echo "ERROR: couldn't determine the latest version (tried the domain and the GitHub mirror)."; exit 1; }

CURRENT="$(az containerapp show -g "$RG" -n "$APP" --query "properties.template.containers[0].image" -o tsv 2>/dev/null || true)"
[[ -z "$CURRENT" ]] && { echo "ERROR: Arjun app '$APP' not found in resource group '$RG'. Is it installed?"; exit 1; }

echo "▶ Current:  $CURRENT"
echo "▶ Upgrading to: $IMAGE_REPO:$TAG  (image-only — your attestations are preserved)…"
az containerapp update -g "$RG" -n "$APP" --image "$IMAGE_REPO:$TAG" -o none

FQDN="$(az containerapp show -g "$RG" -n "$APP" --query "properties.configuration.ingress.fqdn" -o tsv)"
echo "▶ Waiting for the new revision to become healthy…"
# /actuator/health is the one endpoint left unauthenticated, precisely so the
# platform (and this script) can probe it.
for _ in $(seq 1 40); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "https://${FQDN}/actuator/health" 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]] && { echo "✅ Upgraded to $TAG — healthy."; echo "   Open: https://${FQDN}"; exit 0; }
  sleep 6
done
echo "⚠ Rolled to $TAG, but health didn't return 200 in time. Check: https://${FQDN}"
exit 1
