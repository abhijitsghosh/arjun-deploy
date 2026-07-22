#!/usr/bin/env bash
#
# Arjun one-shot installer — runs the whole install and passes the outputs
# between steps for you (no copy-pasting GUIDs).
#
# Designed for Azure Cloud Shell (Bash), so it works the same from Windows,
# macOS or Linux — open https://shell.azure.com and run:
#
#   curl -sL https://raw.githubusercontent.com/abhijitsghosh/arjun-deploy/main/install.sh | bash -s -- --region australiaeast
#
# The Entra app registration is created directly via Microsoft Graph (az rest),
# NOT the Microsoft Graph Bicep extension — that extension is preview and is not
# supported inside deployment stacks. Only the platform is deployed as an ARM stack.
#
# What this installs, and what it can do:
#   * A single-replica Container App running Arjun, signed in to with Entra.
#   * A managed Postgres holding your attestations.
#   * An identity granted **Reader** on this subscription — nothing more. Arjun
#     reads configuration to assess it and never writes to your tenant.
#
# Prerequisites in the target subscription/tenant:
#   * Owner or User Access Administrator on the subscription (the deploy creates
#     the Reader role assignment)
#   * Application Administrator (or Global Administrator) to create the sign-in
#     app registration
#
set -euo pipefail

# Placeholder host: this repository. Swap for a public deploy repo (or arjun.run)
# before customers use the one-liner — see README "Distribution".
BASE="https://raw.githubusercontent.com/abhijitsghosh/arjun-deploy/main"
GRAPH="https://graph.microsoft.com/v1.0"
REGION=""; IMAGE_TAG="latest"; DB_PASSWORD=""; SUBSCRIPTION=""

usage() {
  echo "Usage: install.sh --region <azure-region> [--image-tag <ver>] [--subscription <id>] [--db-password <pw>]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--region)       REGION="${2:-}"; shift 2;;
    -t|--image-tag)    IMAGE_TAG="${2:-}"; shift 2;;
    -p|--db-password)  DB_PASSWORD="${2:-}"; shift 2;;
    -s|--subscription) SUBSCRIPTION="${2:-}"; shift 2;;
    -h|--help)         usage;;
    *) echo "Unknown option: $1"; usage;;
  esac
done
[[ -z "$REGION" ]] && usage

command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI (az) not found. Run this in Azure Cloud Shell: https://shell.azure.com"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found (it's preinstalled in Azure Cloud Shell)."; exit 1; }
az account show >/dev/null 2>&1 || { echo "ERROR: not signed in. Run 'az login' first (automatic in Cloud Shell)."; exit 1; }
[[ -n "$SUBSCRIPTION" ]] && az account set --subscription "$SUBSCRIPTION"

TENANT=$(az account show --query tenantId -o tsv)
echo "▶ Installing Arjun into subscription: $(az account show --query name -o tsv) (region $REGION)"
[[ -z "$DB_PASSWORD" ]] && DB_PASSWORD="Aj$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 22)9!"

# ---------- [1/3] Entra app registration (via Microsoft Graph) ----------
# Arjun is a confidential OIDC client: the browser signs in against Entra and the
# server exchanges the code using a client secret. So this needs a *web* redirect
# URI and a secret — unlike a SPA, which uses neither.
echo "▶ [1/3] Creating the sign-in app registration…"
ID_URI="api://arjun-${TENANT}"   # stable identifier → idempotent on re-run
APP_ID=$(az ad app list --identifier-uri "$ID_URI" --query "[0].appId" -o tsv 2>/dev/null || true)
if [[ -z "${APP_ID:-}" || "$APP_ID" == "null" ]]; then
  MANIFEST=$(mktemp)
  cat > "$MANIFEST" <<JSON
{
  "displayName": "Arjun",
  "signInAudience": "AzureADMyOrg",
  "identifierUris": ["$ID_URI"],
  "web": { "redirectUris": [] },
  "requiredResourceAccess": [{
    "resourceAppId": "00000003-0000-0000-c000-000000000000",
    "resourceAccess": [
      { "id": "e1fe6dd8-ba31-4d61-89e7-88639da4683d", "type": "Scope" }
    ]
  }]
}
JSON
  APP_ID=$(az rest --method POST --url "$GRAPH/applications" \
    --headers "Content-Type=application/json" --body @"$MANIFEST" --query appId -o tsv)
  rm -f "$MANIFEST"
fi
echo "    app id: $APP_ID"
APP_OBJ=$(az ad app show --id "$APP_ID" --query id -o tsv)

# Service principal for the app (idempotent) — retry for Entra replication lag.
SP_OBJ=$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null || true)
if [[ -z "${SP_OBJ:-}" || "$SP_OBJ" == "null" ]]; then
  for _ in 1 2 3 4 5; do
    SP_OBJ=$(az ad sp create --id "$APP_ID" --query id -o tsv 2>/dev/null || true)
    [[ -n "${SP_OBJ:-}" && "$SP_OBJ" != "null" ]] && break
    sleep 8
  done
fi

# A client secret for the code exchange. Existing secrets cannot be read back, so
# each install mints a fresh one; older ones can be pruned in the portal.
CLIENT_SECRET=$(az rest --method POST --url "$GRAPH/applications/$APP_OBJ/addPassword" \
  --headers "Content-Type=application/json" \
  --body "{\"passwordCredential\":{\"displayName\":\"arjun-install-$(date +%Y%m%d%H%M%S)\"}}" \
  --query secretText -o tsv)

# ---------- [2/3] Platform (ARM deployment stack) ----------
echo "▶ [2/3] Deploying the platform — 10–15 min (the database is the slow part)…"
az stack sub create --name arjun --location "$REGION" \
  --template-uri "$BASE/azuredeploy.json" \
  --parameters containerImage="ghcr.io/abhijitsghosh/arjun:$IMAGE_TAG" \
               dbAdminPassword="$DB_PASSWORD" \
               entraClientId="$APP_ID" \
               entraClientSecret="$CLIENT_SECRET" \
  --action-on-unmanage deleteAll --deny-settings-mode none --yes --only-show-errors -o none
APP_URL=$(az stack sub show --name arjun --query "outputs.appUrl.value" -o tsv)
MI_PRINCIPAL=$(az stack sub show --name arjun --query "outputs.managedIdentityPrincipalId.value" -o tsv)
echo "    app url: $APP_URL"

# ---------- [3/3] Redirect URI ----------
# Only known once the app has a hostname, so it is registered after the deploy.
# Spring's OAuth2 client uses /login/oauth2/code/{registrationId}.
echo "▶ [3/3] Registering the sign-in redirect URL…"
az rest --method PATCH --url "$GRAPH/applications/$APP_OBJ" \
  --headers "Content-Type=application/json" \
  --body "{\"web\":{\"redirectUris\":[\"$APP_URL/login/oauth2/code/entra\"]}}" --only-show-errors -o none

# Recycle so the app picks up the registered redirect URI cleanly.
REV=$(az containerapp revision list -g rg-arjun -n arjun-app --query "[?properties.active].name | [0]" -o tsv 2>/dev/null || true)
[[ -n "${REV:-}" ]] && az containerapp revision restart -g rg-arjun -n arjun-app --revision "$REV" --only-show-errors -o none 2>/dev/null || true

cat <<EOF

✅ Arjun is installed.

   Open:   $APP_URL
   Sign in with your work account (one consent prompt).
   Next:   describe your environment, answer the control questionnaire, and run
           an assessment — you get an SSP and its Annex as Office documents.

   Arjun holds Reader on this subscription and nothing more. It reads your
   configuration to assess it; it never changes anything in your tenant.

   Upgrade later (image-only, your attestations are preserved):
     curl -sL https://raw.githubusercontent.com/abhijitsghosh/arjun-deploy/main/upgrade.sh | bash

   Tear down later:
     az stack sub delete --name arjun --action-on-unmanage deleteAll --yes
     az ad app delete --id $APP_ID
EOF
