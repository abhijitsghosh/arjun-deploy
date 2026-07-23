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
#   * Everything goes into ONE resource group (default rg-arjun) you can inspect
#     or delete as a unit: a single-replica Container App running Arjun, and a
#     managed Postgres holding your attestations.
#   * The app's identity is granted **Reader** on the subscription — nothing more.
#     Arjun reads configuration to assess it and never writes to your tenant.
#
# Prerequisites in the target subscription/tenant:
#   * Contributor on the resource group (or the rights to create it) — the deploy
#     itself is resource-group scoped.
#   * Owner or User Access Administrator on the subscription — ONLY for the final
#     Reader grant that lets Arjun assess. If you lack it, the install completes
#     and tells you the one command an admin runs to enable assessment.
#   * Application Administrator (or Global Administrator) to create the sign-in
#     app registration.
#
set -euo pipefail

# Distribution host: the public arjun-deploy repo (stand-in for arjun.run).
BASE="https://raw.githubusercontent.com/abhijitsghosh/arjun-deploy/main"
GRAPH="https://graph.microsoft.com/v1.0"
REGION=""; IMAGE_TAG="latest"; DB_PASSWORD=""; SUBSCRIPTION=""; RG="rg-arjun"

usage() {
  echo "Usage: install.sh --region <azure-region> [--resource-group <name>] [--image-tag <ver>] [--subscription <id>] [--db-password <pw>]"
  echo
  echo "  Everything installs into --resource-group (default rg-arjun), so the whole"
  echo "  footprint is one group you can inspect or delete as a unit."
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--region)         REGION="${2:-}"; shift 2;;
    -g|--resource-group) RG="${2:-}"; shift 2;;
    -t|--image-tag)      IMAGE_TAG="${2:-}"; shift 2;;
    -p|--db-password)    DB_PASSWORD="${2:-}"; shift 2;;
    -s|--subscription)   SUBSCRIPTION="${2:-}"; shift 2;;
    -h|--help)           usage;;
    *) echo "Unknown option: $1"; usage;;
  esac
done
[[ -z "$REGION" ]] && usage

command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI (az) not found. Run this in Azure Cloud Shell: https://shell.azure.com"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found (it's preinstalled in Azure Cloud Shell)."; exit 1; }
az account show >/dev/null 2>&1 || { echo "ERROR: not signed in. Run 'az login' first (automatic in Cloud Shell)."; exit 1; }
[[ -n "$SUBSCRIPTION" ]] && az account set --subscription "$SUBSCRIPTION"

TENANT=$(az account show --query tenantId -o tsv)
SUB_ID=$(az account show --query id -o tsv)
echo "▶ Installing Arjun into subscription: $(az account show --query name -o tsv)"
echo "  region: $REGION   resource group: $RG"
[[ -z "$DB_PASSWORD" ]] && DB_PASSWORD="Aj$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 22)9!"

# ---------- [1/3] Entra app registration (via Microsoft Graph) ----------
# Arjun is a confidential OIDC client: the browser signs in against Entra and the
# server exchanges the code using a client secret. So this needs a *web* redirect
# URI and a secret — unlike a SPA, which uses neither.
echo "▶ [1/3] Creating the sign-in app registration…"
# Arjun is a confidential OIDC client — it signs users in, it does not expose an
# API — so it needs no identifier URI (api://…). Adding one also trips tenants
# whose policy restricts identifier-URI formats. Idempotency on re-run keys off
# the display name instead.
APP_ID=$(az ad app list --display-name "Arjun" --query "[0].appId" -o tsv 2>/dev/null || true)
if [[ -z "${APP_ID:-}" || "$APP_ID" == "null" ]]; then
  MANIFEST=$(mktemp)
  cat > "$MANIFEST" <<JSON
{
  "displayName": "Arjun",
  "signInAudience": "AzureADMyOrg",
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

# ---------- [2/4] Resource group + platform (RG-scoped deployment stack) ----------
# The whole footprint installs into one resource group. Deploying at group scope
# means this step needs Contributor on the group, not Owner on the subscription.
echo "▶ [2/4] Creating resource group '$RG'…"
az group create --name "$RG" --location "$REGION" --only-show-errors -o none

echo "▶ [3/4] Deploying the platform — 10–15 min (the database is the slow part)…"
az stack group create --name arjun --resource-group "$RG" \
  --template-uri "$BASE/azuredeploy.json" \
  --parameters containerImage="ghcr.io/abhijitsghosh/arjun:$IMAGE_TAG" \
               dbAdminPassword="$DB_PASSWORD" \
               entraClientId="$APP_ID" \
               entraClientSecret="$CLIENT_SECRET" \
  --action-on-unmanage deleteAll --deny-settings-mode none --yes --only-show-errors -o none
APP_URL=$(az stack group show --name arjun --resource-group "$RG" --query "outputs.appUrl.value" -o tsv)
MI_PRINCIPAL=$(az stack group show --name arjun --resource-group "$RG" --query "outputs.managedIdentityPrincipalId.value" -o tsv)
echo "    app url: $APP_URL"

# ---------- [4/4] Redirect URI + Reader for assessment ----------
# Redirect URI: only known once the app has a hostname. Spring's OAuth2 client
# uses /login/oauth2/code/{registrationId}.
echo "▶ [4/4] Registering the sign-in redirect URL + granting read access to assess…"
az rest --method PATCH --url "$GRAPH/applications/$APP_OBJ" \
  --headers "Content-Type=application/json" \
  --body "{\"web\":{\"redirectUris\":[\"$APP_URL/login/oauth2/code/entra\"]}}" --only-show-errors -o none

# Reader on the subscription so Arjun can assess it. This is a SEPARATE grant from
# the deployment (which lives entirely in the resource group) — it needs Owner or
# User Access Administrator on the subscription. If you lack that, this step warns
# and continues; an admin can grant it later, or you can scope it to just the
# resource groups Arjun should assess:
#   az role assignment create --assignee-object-id $MI_PRINCIPAL \
#     --assignee-principal-type ServicePrincipal --role Reader \
#     --scope /subscriptions/$SUB_ID/resourceGroups/<rg-to-assess>
if az role assignment create --assignee-object-id "$MI_PRINCIPAL" \
     --assignee-principal-type ServicePrincipal --role Reader \
     --scope "/subscriptions/$SUB_ID" --only-show-errors -o none 2>/dev/null; then
  READER_OK=1
else
  READER_OK=0
fi

# Recycle so the app picks up the registered redirect URI cleanly.
REV=$(az containerapp revision list -g "$RG" -n arjun-app --query "[?properties.active].name | [0]" -o tsv 2>/dev/null || true)
[[ -n "${REV:-}" ]] && az containerapp revision restart -g "$RG" -n arjun-app --revision "$REV" --only-show-errors -o none 2>/dev/null || true

cat <<EOF

✅ Arjun is installed — everything is in resource group '$RG'.

   Open:   $APP_URL
   Sign in with your work account (one consent prompt).
   Next:   describe your environment, answer the control questionnaire, and run
           an assessment — you get an SSP and its Annex as Office documents.

   Arjun holds Reader on this subscription and nothing more. It reads your
   configuration to assess it; it never changes anything in your tenant.
EOF

if [[ "$READER_OK" -ne 1 ]]; then
  cat <<EOF

⚠ Could not grant Reader on the subscription (you may lack Owner / User Access
   Administrator). Arjun is installed but cannot assess until an admin runs:
     az role assignment create --assignee-object-id $MI_PRINCIPAL \\
       --assignee-principal-type ServicePrincipal --role Reader \\
       --scope /subscriptions/$SUB_ID
EOF
fi

cat <<EOF

   Upgrade later (image-only, your attestations are preserved):
     curl -sL https://raw.githubusercontent.com/abhijitsghosh/arjun-deploy/main/upgrade.sh | bash -s -- --resource-group $RG

   Tear down later (removes the whole group in one go):
     az stack group delete --name arjun --resource-group $RG --action-on-unmanage deleteAll --yes
     az group delete --name $RG --yes
     az role assignment delete --assignee $MI_PRINCIPAL --scope /subscriptions/$SUB_ID --role Reader
     az ad app delete --id $APP_ID
EOF
