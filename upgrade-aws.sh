#!/usr/bin/env bash
#
# Arjun in-place upgrade for AWS — the parallel of upgrade.sh (Azure).
#
#   curl -sL https://raw.githubusercontent.com/abhijitsghosh/arjun-deploy/main/upgrade-aws.sh | bash -s -- --region ap-southeast-2
#
# Rolls the App Runner service to the latest published image. Your RDS database — where the
# attestations live — is untouched, and the app runs its Flyway migrations on boot, so code AND
# schema upgrade with zero data loss. It deliberately does NOT touch the CloudFormation stack, so
# nothing is torn down, recreated, or given a fresh empty database.
#
# How it works: an AWS install points App Runner at `…/arjun:latest`, and every release republishes
# that tag. Triggering a new deployment makes App Runner re-pull `:latest` — the new version — while
# preserving every other setting (the database URL, the Cognito client secret, the read-only role).
# That is why this is a `start-deployment` and not an `update-service`: the latter would replace the
# whole source configuration and drop those injected settings.
#
# Designed for AWS CloudShell (works the same from Windows, macOS or Linux) — open
# https://console.aws.amazon.com/cloudshell and run the one-liner above.
#
set -euo pipefail

STACK="arjun"
REGION=""

usage() {
  echo "Usage: upgrade-aws.sh --region <aws-region> [--stack <name>]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--region) REGION="${2:-}"; shift 2;;
    -s|--stack)  STACK="${2:-}"; shift 2;;
    -h|--help)   usage;;
    *) echo "Unknown option: $1"; usage;;
  esac
done
[[ -z "$REGION" ]] && usage
aws sts get-caller-identity >/dev/null 2>&1 || { echo "ERROR: not signed in to AWS (CloudShell signs you in automatically)."; exit 1; }

ARN="$(aws cloudformation describe-stack-resources --region "$REGION" --stack-name "$STACK" \
  --query "StackResources[?ResourceType=='AWS::AppRunner::Service'].PhysicalResourceId | [0]" \
  --output text 2>/dev/null || true)"
[[ -z "$ARN" || "$ARN" == "None" ]] && {
  echo "ERROR: App Runner service not found in stack '$STACK' (region $REGION). Is Arjun installed there?"
  exit 1
}

IMG="$(aws apprunner describe-service --region "$REGION" --service-arn "$ARN" \
  --query 'Service.SourceConfiguration.ImageRepository.ImageIdentifier' --output text)"
echo "▶ Service image: ${IMG}"
if [[ "$IMG" != *:latest ]]; then
  echo "  Note: this service is pinned to a specific tag, not ':latest'. Re-pulling that same tag"
  echo "  will not change the version. To move a pinned install, update the stack's Image parameter."
fi

echo "▶ Rolling a new deployment (re-pulls the latest published image — attestations preserved)…"
aws apprunner start-deployment --region "$REGION" --service-arn "$ARN" >/dev/null

URL="$(aws apprunner describe-service --region "$REGION" --service-arn "$ARN" \
  --query 'Service.ServiceUrl' --output text)"
echo "▶ Waiting for the new deployment to become healthy…"
# /actuator/health is the one endpoint left unauthenticated, precisely so the platform (and this
# script) can probe it.
for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "https://${URL}/actuator/health" 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]] && { echo "✅ Upgraded — healthy."; echo "   Open: https://${URL}"; exit 0; }
  sleep 6
done
echo "⚠ Deployment triggered, but health didn't return 200 in time. Check the App Runner console."
exit 1
