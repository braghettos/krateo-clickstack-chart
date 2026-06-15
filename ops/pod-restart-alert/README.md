# Pod Restart Alert (HyperDX Native)

Create a pod restart alert in the HyperDX UI. Alerts fire when Kubernetes pod restart events (Killing, BackOff, Unhealthy, Failed) exceed a threshold and post to Slack. Integrates with Krateo Autopilot so the Observability Agent can investigate when @mentioned in the channel.

> For the full system architecture, see [docs/architecture.md](../docs/architecture.md) or [docs/architecture.html](../docs/architecture.html).

**Target channel:** `#krateo-troubleshooting` in workspace `aiagents-gruppo`

> **Alert resolution:** HyperDX sends resolution notifications automatically when the alert clears. See [docs/ALERT_RESOLUTION_DEEP_DIVE.md](../docs/ALERT_RESOLUTION_DEEP_DIVE.md) for how ClickHouse and HyperDX handle fire vs. resolve.

## Architecture

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  OTel Collector │────▶│    ClickHouse    │◀────│  HyperDX        │
│  (K8s events)   │     │    otel_logs     │     │  Alert Engine   │
└─────────────────┘     └──────────────────┘     └────────┬────────┘
                                                          │
                                                          ▼
                                                 ┌─────────────────┐
                                                 │  Slack Channel  │
                                                 │  #krateo-troubleshooting
                                                 └────────┬────────┘
                                                          │
                        ┌─────────────────────────────────┘
                        │ @mention to investigate
                        ▼
                 ┌──────────────────┐
                 │  KAgent Slack    │────▶ Krateo Autopilot
                 │  Bot (A2A)       │      (Observability → k8s-agent → helm-agent)
                 └──────────────────┘
```

## Event Types

The alert detects pod-related K8s events with these reasons:

| Reason    | Meaning                                      |
|-----------|----------------------------------------------|
| Killing   | Container killed (OOMKilled, SIGKILL)        |
| BackOff   | CrashLoopBackOff – container repeatedly crashing |
| Unhealthy | Liveness/readiness probe failed              |
| Failed    | Container failed to start                    |

## Setup: HyperDX UI Workflow

### Step 1: Create Slack Webhook in HyperDX

1. Open HyperDX UI (e.g. `http://<hyperdx-ip>:3000` or port-forward: `kubectl port-forward svc/krateo-clickstack-app -n clickhouse-system 3000:3000`)
2. Go to **Alerts** → **Integrations** → **Webhooks**
3. **Add webhook**:
   - Service type: `Slack`
   - Paste your Slack incoming webhook URL
   - **Target channel:** Create the webhook in the Slack workspace `aiagents-gruppo` and configure it to post to `#krateo-troubleshooting`
4. Note the webhook ID or name (used when creating the alert)

### Step 2: Create Saved Search for Pod Restart Events

1. Go to **Search**
2. Use **SQL mode** with this query filter:

```sql
ResourceAttributes['telemetry.source'] = 'k8s-events'
AND JSONExtractString(Body, 'object', 'involvedObject', 'kind') = 'Pod'
AND JSONExtractString(Body, 'object', 'type') = 'Warning'
```

> **Why `type = 'Warning'` instead of filtering by specific reasons?** Pods can restart for many reasons beyond CrashLoopBackOff — OOMKill, eviction, preemption, failed mounts, scheduling failures, probe failures, etc. Filtering by `type = 'Warning'` catches all abnormal pod events regardless of the specific reason.

>>>>>>> afbdc4d (fix: broaden pod restart alert to catch all Warning events)
3. Save the search (e.g. "Pod Restart Events")

### Step 3: Add Alert to the Saved Search

1. Open the saved search and click **Alerts** (top-right)
2. Create the alert:
   - **Threshold:** above 0
   - **Interval:** 5m (or 1m for faster detection)
   - **Channel:** select the Slack webhook from Step 1
   - **Name:** "Pod Restart Alert"
   - **Message:** Include an @mention of the KAgent Slack bot so it is tagged and takes charge. Example:

     ```
     Pod restart detected in cluster. <@BOT_USER_ID> please investigate and fix.
     ```

     Replace `BOT_USER_ID` with the bot's Slack user ID (from Slack app settings → Install App → Bot User ID, or use the format `<@U0ABC123>`).

3. Save the alert

### Alternative: API Bootstrap Script

If you prefer to create the alert via API (after creating the webhook and saved search in the UI):

```bash
cp .env.example .env
# Edit .env with your values (HYPERDX_URL, HYPERDX_API_KEY, WEBHOOK_ID, SAVED_SEARCH_ID)

chmod +x bootstrap-alert.sh
./bootstrap-alert.sh
```

Requires `curl` and `jq`. Create your API key in HyperDX: Settings → API Keys. Do not commit `.env` (it contains secrets).

### Step 4: Integrate KAgent in the Same Channel

Add the KAgent Slack bot to `#krateo-troubleshooting` so it receives @mentions when the alert fires. See the Krateo Autopilot repo: `manifests/slack-integration/README.md`.

**Agent chain:** When the bot is invoked, the Autopilot routes to:
1. **Observability Agent** – diagnoses via ClickHouse (pod logs, K8s events, metrics)
2. **k8s-agent** – remediation (ApplyManifest, PatchResource, GetPodLogs, ExecuteCommand, etc.)
3. **helm-agent** – Helm troubleshooting (ListReleases, GetRelease, Upgrade, Uninstall, etc.)

## Troubleshooting

- **No events in ClickHouse**: Ensure the OTel deployment collector is running and watching K8s events. Verify with:
  ```bash
  kubectl exec -it -n clickhouse-system svc/krateo-clickstack-clickhouse -- \
    clickhouse-client -q "SELECT count() FROM otel_logs WHERE ResourceAttributes['telemetry.source'] = 'k8s-events'"
  ```

- **Slack webhook fails**: Check the URL is correct and the webhook is enabled. Test with:
  ```bash
  curl -X POST -H 'Content-type: application/json' --data '{"text":"Test"}' YOUR_WEBHOOK_URL
  ```

- **HyperDX UI not reachable**: Port-forward the service:
  ```bash
  kubectl port-forward svc/krateo-clickstack-app -n clickhouse-system 3000:3000
  ```
  Then open http://localhost:3000
