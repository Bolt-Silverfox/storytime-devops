# Observability

Version-controlled copies of observability objects that otherwise live only in
Grafana Cloud.

Stack `dashingraccoon1269`; the snippets below need
`GRAFANA_URL=https://dashingraccoon1269.grafana.net` exported alongside the
token.
Region `prod-gb-south-1` — the AWS UK one; `prod-gb-south-0` is a separate
GCP-hosted UK region. Folder `Storytime`, UID `f6ck4k`. Prometheus datasource UID
`grafanacloud-prom`.

## `alert-rules.yaml`

Provisioning-format export of the alert rules in the `Storytime` folder, group
`production-1m`, evaluated every 1m.

| rule | query | threshold | for |
|---|---|---|---|
| storytime-api 5xx error rate | `sum(rate(http_server_duration_milliseconds_count{service_name="storytime-api",http_status_code=~"5.."}[5m]))` | above 0.1 | 5m |
| storytime-api event loop stalled | `max(nodejs_eventloop_delay_p99_seconds{service_name="storytime-api"})` | above 1 | 10m |
| storytime-api down (no telemetry) | `count(db_pool_connections_open{service_name="storytime-api"}) or vector(0)` | below 0 (wrong — see below) | 5m |

The threshold is a separate `__expr__` node in each rule, not part of the
PromQL. Don't paste the query and the comparison into Grafana as one expression.

Notification routing is by notification policy — no rule here carries
`notification_settings`, so restoring this file does not restore routing. Rules
1 and 2 are labelled `env=production` / `service=storytime-api`; the down rule
(`afybpc0sg8ikgd`) carries no labels at all, so any policy matching on those
labels will not route it.

Two things about the down rule that are easy to get wrong:

- **Do not "simplify" the expression to `absent()`.** The first version did.
  With this rule's `noDataState: NoData`, `absent()` returns an empty result
  while the service is healthy, which Grafana treats as No Data — it fired a
  real notification within minutes of being created. `count(...) or vector(0)`
  always returns a number, so it can only fire on a genuine zero. (Rules 1 and 2
  use `noDataState: OK`, where that trap does not apply.)
- **The exported threshold is `below 0`, which no value of that expression can
  satisfy, so the rule as exported never fires.** It needs to be `below 1`. The
  `or vector(0)` also guarantees a sample, so the `NoData` path can't fire
  either — and rules 1 and 2 are `noDataState: OK`, so a total API outage
  currently produces no alert at all. Fix it in the UI and re-export; hand-editing this
  file does not change Grafana.

Coverage is `storytime-api` only. `web`, `admin`, `waitlist-web` and
`waitlist-api` emit no telemetry, so they have no alerts. TLS expiry is not
covered and cannot be from these metrics — it needs an external prober, either
Grafana Synthetic Monitoring or a blackbox_exporter scrape of
`probe_ssl_earliest_cert_expiry`. Let's Encrypt stopped sending expiry emails on
2025-06-04, so nothing currently warns before a certificate lapses.

### Re-export

Needs a Grafana service-account token with `alert.provisioning:read`, in
`GRAFANA_TOKEN`. Never paste a token into a file in this repo. Run from the repo
root:

```bash
curl -fsSH "Authorization: Bearer $GRAFANA_TOKEN" \
  "$GRAFANA_URL/api/v1/provisioning/alert-rules/export?folderUid=f6ck4k" \
  -o observability/alert-rules.yaml.new \
  && mv observability/alert-rules.yaml.new observability/alert-rules.yaml
```

`-f` is what protects the committed backup: without it curl exits 0 on a 401
and writes the JSON error body into the file. With it, curl exits 22 and writes
nothing. The temp file plus `&&` guards the other case — a truncated 200, where
curl exits 18 after already emitting a partial document. Keep both.

`folderUid` is missing from the published HTML API reference but is in Grafana's
OpenAPI spec and works. YAML is the default `format`.

### Restoring from this file

**This export cannot be fed back to the HTTP API as-is.** Grafana documents this format as
being for file or Terraform provisioning, and says outright that "this format
cannot be used to update resources via the HTTP API". The API's `AlertRuleGroup`
body is `{folderUid, title, interval, rules[]}` with `interval` as an integer
number of seconds, while the export uses `{folder, name, interval: 1m}` nested
under `groups:`. So a restore is one of:

- **Recreate in the UI** using the table above. For three rules this is the
  cheapest option, and it is why the table is here.
- **Terraform** — re-export with `format=hcl` and apply the `grafana_rule_group`
  resource. Unlike file provisioning this works on Cloud, and it is the
  direction to go if these rules outgrow hand-maintenance.
- **File provisioning** — drop this file into the instance's
  `provisioning/alerting/` directory. Not available on Grafana Cloud.
- **Convert, then PUT** — translate to the API shape and
  `PUT $GRAFANA_URL/api/v1/provisioning/folder/f6ck4k/rule-groups/production-1m`
  (JSON only) with `-H "X-Disable-Provenance: true"`. No script for this exists
  in the repo. Note the whole v1 provisioning CRUD surface is marked deprecated
  in favour of `/apis/rules.alerting.grafana.app/v0alpha1` (the *export* routes
  are not), so prefer Terraform over writing a converter.

Use the FOLDER-scoped export above, not the group-scoped routes. Both
`/folder/<uid>/rule-groups/<group>/export` and
`/alert-rules/export?folderUid=<uid>&group=<group>` emit `folder: ""`, and file
provisioning rejects an empty folder rather than treating it as the root — so a
group-scoped export produces a file that cannot be restored. Folder-scoped is
the only route that fills in `folder: Storytime`.

The trade-off is that it exports every group in the folder. Today `Storytime`
holds exactly one group, `production-1m`, so the two are equivalent; if a second
group is ever added, it will appear in this file on the next re-export, which is
visible in the diff.

`X-Disable-Provenance: true` keeps the rules editable in the UI; without it they
get provenance `api` and the UI refuses to edit them. It is not free, though:
setting provenance is a separate permission, so a restore needs BOTH
`alert.provisioning:write` and `alert.provisioning.provenance:write`. A token
carrying only the first will fail on the header rather than on the write, which
is a confusing way to find out. The read-only token above will 403 on either.
Note also that Grafana refuses to mix provisioned and unprovisioned rules within
one group.
