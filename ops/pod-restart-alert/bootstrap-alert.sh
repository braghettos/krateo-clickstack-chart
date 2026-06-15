#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Pod Restart Alert – HyperDX API Bootstrap
#
# Creates the pod restart alert via HyperDX API. Requires:
#   1. Webhook created in HyperDX UI (Alerts → Integrations → Webhooks)
#   2. Saved search created in HyperDX UI (Search → save "Pod Restart Events")
#
# Usage:
#   export HYPERDX_URL="http://localhost:3000"   # or your HyperDX base URL
#   export HYPERDX_API_KEY="your-personal-api-key"
#   export WEBHOOK_ID="webhook-id-from-hyperdx-ui"
#   export SAVED_SEARCH_ID="saved-search-id-from-hyperdx-ui"
#   export KRATEO_BOT_MENTION="<@U0ABC123>"      # optional, for @mention in alert
#   ./bootstrap-alert.sh
#
# Or use .env file:
#   cp .env.example .env
#   # edit .env with your values
#   ./bootstrap-alert.sh
#
# To get IDs: create webhook and saved search in UI, then GET /api/v1/webhooks
# and GET /api/v1/saved-searches (or inspect network tab when loading the UI).
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && set -a && source "$SCRIPT_DIR/.env" && set +a

HYPERDX_URL="${HYPERDX_URL:-http://localhost:3000}"
HYPERDX_API_KEY="${HYPERDX_API_KEY:-}"
WEBHOOK_ID="${WEBHOOK_ID:-}"
SAVED_SEARCH_ID="${SAVED_SEARCH_ID:-}"
KRATEO_BOT_MENTION="${KRATEO_BOT_MENTION:-}"

API_BASE="${HYPERDX_URL%/}/api"

die() { echo "[ERROR] $*" >&2; exit 1; }

[ -n "$HYPERDX_API_KEY" ] || die "HYPERDX_API_KEY is required"
[ -n "$WEBHOOK_ID" ]     || die "WEBHOOK_ID is required (create webhook in HyperDX UI first)"
[ -n "$SAVED_SEARCH_ID" ] || die "SAVED_SEARCH_ID is required (create saved search in HyperDX UI first)"

MESSAGE="Pod restart detected in cluster."
[ -n "$KRATEO_BOT_MENTION" ] && MESSAGE="$MESSAGE $KRATEO_BOT_MENTION please investigate and fix."

echo "[bootstrap] Creating Pod Restart Alert via HyperDX API..."
echo "[bootstrap]   API: $API_BASE"
echo "[bootstrap]   Webhook ID: $WEBHOOK_ID"
echo "[bootstrap]   Saved Search ID: $SAVED_SEARCH_ID"

PAYLOAD=$(jq -n \
  --arg interval "5m" \
  --arg source "search" \
  --arg savedSearchId "$SAVED_SEARCH_ID" \
  --arg name "Pod Restart Alert" \
  --arg message "$MESSAGE" \
  --arg webhookId "$WEBHOOK_ID" \
  --arg groupBy "k8s.namespace.name,k8s.pod.name" \
  '{
    interval: $interval,
    threshold: 2,
    threshold_type: "above",
    groupBy: ($groupBy | split(",")),
    source: $source,
    savedSearchId: $savedSearchId,
    name: $name,
    message: $message,
    channel: { type: "slack_webhook", webhookId: $webhookId }
  }')

RESP=$(curl -s -w "\n%{http_code}" -X POST "$API_BASE/alerts" \
  -H "Authorization: Bearer $HYPERDX_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

HTTP_CODE=$(echo "$RESP" | tail -n 1)
HTTP_BODY=$(echo "$RESP" | sed '$d')

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
  echo "[bootstrap] Alert created successfully."
  echo "$HTTP_BODY" | jq . 2>/dev/null || echo "$HTTP_BODY"
else
  echo "[bootstrap] API returned HTTP $HTTP_CODE"
  echo "$HTTP_BODY" | jq . 2>/dev/null || echo "$HTTP_BODY"
  exit 1
fi
