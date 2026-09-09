# Migration runbook

**Goal: migrating is a routine operation, not a project.** New region, new AWS
account, new provider, or just rebuilding a box that has gone strange — the same
ordered procedure every time, runnable by someone who did not write it.

This is written to be followed literally. Each step says what to verify and what
"good" looks like. **Do not proceed past a step whose check failed.**

> Read [`current-state.md`](current-state.md) first if you do not already know what
> the legacy estate looks like.

---

## 0. The design promise this depends on

**The box is disposable.** Nothing that matters exists only on the instance:

| Thing | Lives in | Recreated by |
|---|---|---|
| Container images | ECR | already there; pull by tag |
| App configuration | SSM Parameter Store | `terraform apply` |
| Database contents | S3 (nightly `pg_dump`) + EBS snapshots | `pg_restore` — step 5 |
| DNS | Cloudflare, in Terraform | `terraform apply` |
| Reverse proxy config | rendered from `infra/proxy.tf` | `terraform apply` |
| TLS | Cloudflare edge, or an Origin Cert in SSM | `terraform apply` |

**The one known gap, stated plainly:** with `use_managed_database = false` the
Postgres *data directory* is a Docker volume on the instance's EBS volume. Losing
the instance means restoring from the nightly dump — so the recovery point is up to
24 hours old, plus whatever the EBS snapshot adds. That is the accepted cost of not
paying for RDS at this scale. If that RPO stops being acceptable, set
`use_managed_database = true`; the migration is then step 5 of this document, once.

Also true, and deliberate: **no literal IP addresses, no hardcoded AMI ids, and no
hardcoded region anywhere in `infra/`.** Region, AZ, instance type, hostnames and
environment name are all variables. The AMI comes from `data.aws_ami` with
`ignore_changes = [ami]`, so it is current at launch and stable thereafter.

---

## 1. Prepare

```bash
cd infra
terraform init
terraform workspace list          # confirm which workspaces exist
terraform workspace select all    # or the workspace you are migrating
```

**Check:** `terraform workspace show` prints the workspace you intend, and
`terraform plan` on the *existing* stack reports **no changes**. A dirty starting
state means you are about to migrate and apply an unrelated change at the same
time. Stop and resolve that first.

**Note the current live values** — you will compare against them at the end:

```bash
terraform output instance_id
terraform output instance_public_ip
terraform output backup_bucket
terraform output -json memory_budget
aws s3 cp "s3://$(terraform output -raw backup_bucket)/_status/last-success.json" - | cat
```

**Check:** `last_success_utc` in that heartbeat is **less than 24 hours old**. If it
is stale or missing, the backups are not working — fix that before migrating,
because step 5 depends on them entirely.

---

## 2. Take a fresh backup, and prove it restores

Do not migrate on last night's dump if you can have one from five minutes ago.

```bash
INSTANCE=$(terraform output -raw instance_id)

# Force a backup now.
aws ssm send-command --instance-ids "$INSTANCE" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["/usr/local/bin/pg-backup.sh"]' \
  --query 'Command.CommandId' --output text

# ...then read the result (substitute the command id).
aws ssm get-command-invocation --instance-id "$INSTANCE" --command-id <id> \
  --query '{Status:Status,Out:StandardOutputContent,Err:StandardErrorContent}'

# Prove it restores, into a throwaway container on the box.
aws ssm send-command --instance-ids "$INSTANCE" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["/usr/local/bin/pg-restore-verify.sh"]' \
  --query 'Command.CommandId' --output text
```

**Check:** the backup invocation `Status` is `Success` and its output contains
`backup ok:`. The verify invocation contains `restore verification ok:` with a
table count that looks like the real schema, not 0 or 1.

---

## 3. Stand up the new stack — WITHOUT touching the old one

The new stack must be a *separate workspace*, so the old one stays in its own
state and cannot be modified or destroyed by this apply.

```bash
terraform workspace new all-v2          # or all-euw2, all-newaccount, ...
cp terraform.all.tfvars terraform.all-v2.tfvars
```

Edit `terraform.all-v2.tfvars`:

- `environment` — must match the workspace name (`guards.tf` enforces this).
- `aws_region` / `vpc_cidr` — if the region is changing. **If the region is
  changing, re-read [`infra/README.md` → Region](../infra/README.md#region-and-data-residency)
  first: this is a GDPR decision, not a latency one.**
- `backup_bucket_name` — a *new* bucket. Never point two stacks at one.
- `cloudflare_enabled = true`, but **leave the hostnames pointing nowhere yet** —
  give the new stack temporary hostnames (e.g. `api-v2.<zone>`) so it can be
  tested end to end before it owns the real names.

```bash
terraform plan -var-file=terraform.all-v2.tfvars -out=v2.tfplan
terraform show v2.tfplan | less
```

**Check, before applying:** the plan creates and destroys **nothing** belonging to
the old stack — it is a different workspace, so it should be all `create`. If you
see a single `destroy` or `must be replaced`, you are in the wrong workspace. Stop.

```bash
terraform apply v2.tfplan
```

**Check:** `terraform output instance_id` is a *new* id, and
`aws ssm start-session --target <new id>` connects. On the box:

```bash
sudo tail -50 /var/log/user-data.log      # ends with "bootstrap complete"
docker ps                                  # every enabled service + postgres + redis
systemctl status caddy --no-pager
systemctl list-timers 'storytime-*' --no-pager
```

**Check:** no container in `Restarting`, Caddy `active (running)`, and both
`storytime-pg-backup.timer` and `storytime-pg-verify.timer` listed.

---

## 4. Point config at the new stack

The new stack's SSM tree is namespaced by its own prefix, so it starts empty apart
from what its tfvars created. Anything in the old tree that is not in your tfvars
must be copied across:

```bash
OLD=/storytime-all
NEW=/storytime-all-v2

# Compare the SHAPE of the two trees. Names only — do not print values.
diff \
  <(aws ssm get-parameters-by-path --path "$OLD" --recursive --query 'Parameters[].Name' \
      --output text | tr '\t' '\n' | sed "s|^$OLD||" | sort) \
  <(aws ssm get-parameters-by-path --path "$NEW" --recursive --query 'Parameters[].Name' \
      --output text | tr '\t' '\n' | sed "s|^$NEW||" | sort)
```

**Check:** that diff is empty. If it is not, add the missing names to
`secret_keys` / `config_plain` and re-apply — **do not** hand-create parameters on
the side, or the next apply will not know about them.

---

## 5. Restore the data into the new stack

**The new box cannot read the old stack's bucket, by design.** Its instance role is
scoped to its own bucket and prefix, so `aws s3 cp s3://<old-bucket>/...` on the new
box returns `AccessDenied`.

Rather than widen that role, **stage the dump between buckets from your own
workstation**, using your operator credentials. The new box then reads from its own
bucket, which it is already permitted to do, and no IAM change is made or has to be
remembered and revoked afterwards.

```bash
# --- On your workstation, with credentials for both buckets ---
OLD_BUCKET=<old stack's backup bucket>
NEW_BUCKET=$(terraform output -raw backup_bucket)      # in the new workspace
OLD_STACK=<old name_prefix>-<old environment>          # e.g. storytime-all

# Newest dump. Keys are date-ordered, so lexicographic == chronological.
KEY=$(aws s3 ls "s3://$OLD_BUCKET/postgres/$OLD_STACK/" --recursive \
        | awk '{print $4}' | grep '\.dump$' | sort | tail -1)
echo "$KEY"
[ -n "$KEY" ] || { echo "no dump found in the old bucket" >&2; exit 1; }

# Server-side copy into the new stack's own prefix. Never lands on your laptop.
aws s3 cp "s3://$OLD_BUCKET/$KEY" "s3://$NEW_BUCKET/postgres/restore-in/source.dump" \
  --sse AES256
```

**Check:** the object exists and is the expected size.

```bash
aws s3api head-object --bucket "$NEW_BUCKET" --key postgres/restore-in/source.dump \
  --query ContentLength --output text
```

> The instance role covers `postgres/*`, so `postgres/restore-in/` is readable by the
> new box with no policy change. It is also inside the lifecycle rule's prefix, so the
> staged copy expires on its own rather than lingering.

Then, on the new box:

```bash
NEW_INSTANCE=$(terraform output -raw instance_id)
aws ssm start-session --target "$NEW_INSTANCE"
```

```bash
set -euo pipefail

# Define these INSIDE the session — a variable exported on your workstation does
# not exist here.
STACK=<new name_prefix>-<new environment>     # e.g. storytime-all-v2
BUCKET=<new backup bucket>

# The dump is plaintext children's personal data while it is on disk. Register
# cleanup BEFORE creating it, so an interruption cannot leave a copy behind, and
# keep the two deletions independent — chaining with && lets a failure in the
# first skip the second.
cleanup() {
  docker exec postgres rm -f /tmp/restore.dump >/dev/null 2>&1 || true
  if [ -f /var/tmp/restore.dump ]; then shred -u /var/tmp/restore.dump || rm -f /var/tmp/restore.dump; fi
}
trap cleanup EXIT INT TERM HUP

# Use the CONFIGURED identity rather than assuming `storytime`: db_name and
# db_username are variables, so a guess restores into the wrong database or fails.
DB_USER=$(aws ssm get-parameter --name "/$STACK/_db/USERNAME" --query 'Parameter.Value' --output text)
DB_NAME=$(aws ssm get-parameter --name "/$STACK/_db/NAME"     --query 'Parameter.Value' --output text)

aws s3 cp "s3://$BUCKET/postgres/restore-in/source.dump" /var/tmp/restore.dump

# --clean --if-exists makes this repeatable; without them a second attempt fails
# on objects that already exist.
docker cp /var/tmp/restore.dump postgres:/tmp/restore.dump
docker exec postgres pg_restore \
  --username="$DB_USER" --dbname="$DB_NAME" \
  --clean --if-exists --no-owner --no-privileges --jobs 2 \
  /tmp/restore.dump
```

**Check:** table count and a couple of row counts match the source.

```bash
docker exec postgres psql -U "$DB_USER" -d "$DB_NAME" -c \
  "SELECT count(*) FROM information_schema.tables
    WHERE table_schema NOT IN ('pg_catalog','information_schema');"
docker exec postgres psql -U "$DB_USER" -d "$DB_NAME" -c \
  "SELECT 'users', count(*) FROM users UNION ALL SELECT 'stories', count(*) FROM stories;"
```

`pg_restore` reporting errors about roles or extensions it could not create is
normal with `--no-owner --no-privileges`. Errors about *tables* are not.

When you are satisfied, remove the staged copy — it is a full plaintext dump:

```bash
aws s3 rm "s3://$NEW_BUCKET/postgres/restore-in/source.dump"
```

(The instance role has no `s3:DeleteObject`, so run this from your workstation.)

## 6. Verify the new stack through its temporary hostname

Before it owns any real traffic:

```bash
curl -fsS https://api-v2.<zone>/health
```

Then exercise the paths that break in interesting ways:

- **An SSE endpoint** — story generation or TTS progress. Confirm events arrive
  incrementally, not in one buffered lump at the end. This is what
  `flush_interval -1` exists for, and it is the single most likely thing to be
  subtly wrong after a proxy change.
- **A >10 MB upload**, against `client_max_body_size`/`request_body max_size 25m`.
- **A login**, proving the database restore and `JWT_SECRET` both landed.
- **A queued job** — trigger an email or a TTS batch and watch it drain, proving
  Redis and BullMQ are wired up.

**Check:** all four behave as on the old stack. **Do not flip DNS until they do.**

---

## 7. Cut over — flip the Cloudflare record

This is the whole point of putting DNS in Terraform with a low TTL.

> ### One hostname, one owner. Never two.
>
> Cloudflare permits **multiple A records for the same name**, and Terraform
> workspaces do not coordinate with each other. So if you add the real hostname to
> `all-v2` *before* removing it from `all`, both records exist and Cloudflare
> **round-robins traffic between the two origins** — half of it to a stack you have
> not finished verifying, with a split-brain database underneath.
>
> That is far worse than a few seconds of NXDOMAIN. So: **remove, then add**, with
> both plans computed in advance so the two applies are back to back.

Edit the tfvars first — remove the real hostnames from `terraform.all.tfvars`, and add
them to `terraform.all-v2.tfvars` — then compute **both** plans before applying
either:

```bash
terraform workspace select all
terraform plan -var-file=terraform.all.tfvars     -out=release.tfplan
terraform show release.tfplan            # expect: cloudflare_record DESTROY only

terraform workspace select all-v2
terraform plan -var-file=terraform.all-v2.tfvars  -out=cut.tfplan
terraform show cut.tfplan                # expect: cloudflare_record CREATE only
```

**Check before applying anything:** `release.tfplan` destroys **only**
`cloudflare_record` resources. If it proposes destroying the instance, the EIP or the
backup bucket, **stop** — you still need the old box for rollback.

Then apply them back to back, release first:

```bash
terraform workspace select all   && terraform apply release.tfplan
terraform workspace select all-v2 && terraform apply cut.tfplan
```

**Do this during a quiet period**, and watch:

```bash
dig +short api.<zone>
curl -fsS https://api.<zone>/health
```

Expect a gap of a few seconds between the two applies during which the name does not
resolve. With `cloudflare_proxied = true` the edge address does not change — only the
origin behind it — so propagation is effectively instant; unproxied,
`cloudflare_dns_ttl` (default 60s) bounds it.

## 8. Rollback

**Rollback is flipping the record back.** That is the only reason the old box is
still running, and it is why step 7 must never destroy it.

Same single-owner rule, in reverse — remove from `all-v2` first, then restore to
`all`, or you recreate the split-brain you just avoided:

```bash
# 1. Release the hostnames from the new stack.
terraform workspace select all-v2
#    remove the real hostnames from terraform.all-v2.tfvars
terraform apply -var-file=terraform.all-v2.tfvars

# 2. Return them to the old stack.
terraform workspace select all
#    restore the real hostnames in terraform.all.tfvars
terraform apply -var-file=terraform.all.tfvars
```

**Caveat you must think about before cutting over:** any data written to the NEW
stack after cutover does not exist on the old one. Rolling back therefore loses
it. Either roll back fast (minutes), or dump the new stack and restore into the
old one first. Decide which of those you are doing *before* step 7, not during it.

---

## 9. Decommission — only after you are confident

Wait at least one full business day, and confirm:

- the new stack's backup heartbeat is fresh and its restore verification has run;
- no errors attributable to the migration;
- nothing still resolves to the old stack.

```bash
terraform workspace select all
terraform destroy -var-file=terraform.all.tfvars
```

**Check the destroy plan.** `aws_db_instance` carries `prevent_destroy`, so if you
were using managed RDS Terraform will refuse — that is deliberate, and removing
the guard to get past it is a decision that needs a human.

**The backup bucket is not `force_destroy`, so `destroy` leaves it and its
contents behind.** That is intentional: emptying the backup history must be a
separate, deliberate act, never a side effect. Delete it by hand, later, once you
are certain — and prefer keeping it.

Finally, rename the new workspace to the plain name if you want to (there is no
`terraform workspace rename`; it means a state move, so most teams just keep
`all-v2` and move on).

---

## Known coupling outside this repository

**`storytime_be/.github/workflows/dev-deploy.yml` hardcodes the legacy host's
`IP:22` and the legacy RDS hostname** in five `step-security/harden-runner`
`allowed-endpoints` blocks under `egress-policy: block`. Any migration silently
breaks dev deploys until that file is edited: the runner will block the connection
and the failure will look like a network problem, not a configuration one.

Not fixed here — it is in another repository — but it is exactly the kind of hidden
coupling this work exists to eliminate. Edit it **as part of step 7**, in the same
change window, and check it off before you call the migration done.
