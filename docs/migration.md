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

```bash
NEW_INSTANCE=$(terraform output -raw instance_id)
OLD_BUCKET=<old stack's backup bucket>

aws ssm start-session --target "$NEW_INSTANCE"
```

On the new box:

```bash
# Newest dump from the OLD stack's bucket. Keys are date-ordered, so
# lexicographic order is chronological.
KEY=$(aws s3 ls "s3://$OLD_BUCKET/postgres/" --recursive | awk '{print $4}' \
        | grep '\.dump$' | sort | tail -1)
echo "$KEY"

aws s3 cp "s3://$OLD_BUCKET/$KEY" /var/tmp/restore.dump

# Into the running container. --clean --if-exists makes this repeatable; without
# them a second attempt fails on objects that already exist.
docker cp /var/tmp/restore.dump postgres:/tmp/restore.dump
docker exec postgres pg_restore \
  --username="$(aws ssm get-parameter --name "$NEW/_db/USERNAME" --query 'Parameter.Value' --output text)" \
  --dbname="$(aws ssm get-parameter --name "$NEW/_db/NAME" --query 'Parameter.Value' --output text)" \
  --clean --if-exists --no-owner --no-privileges --jobs 2 \
  /tmp/restore.dump

# The dump is plaintext children's data. Remove it from both filesystems.
docker exec postgres rm -f /tmp/restore.dump
shred -u /var/tmp/restore.dump
```

**Check:** table count and a couple of row counts match the source.

```bash
docker exec postgres psql -U <user> -d <db> -c \
  "SELECT count(*) FROM information_schema.tables
    WHERE table_schema NOT IN ('pg_catalog','information_schema');"
docker exec postgres psql -U <user> -d <db> -c \
  "SELECT 'users', count(*) FROM users UNION ALL SELECT 'stories', count(*) FROM stories;"
```

`pg_restore` reporting errors about roles or extensions it could not create is
normal with `--no-owner --no-privileges`. Errors about *tables* are not.

---

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

Move the real hostnames from the old stack's tfvars to the new one:

```bash
# In terraform.all-v2.tfvars: give the new stack the REAL hostnames.
# In terraform.all.tfvars:    remove them from the old stack.

terraform workspace select all-v2
terraform plan -var-file=terraform.all-v2.tfvars -out=cut.tfplan
terraform show cut.tfplan          # expect: cloudflare_record changes ONLY
terraform apply cut.tfplan

terraform workspace select all
terraform plan -var-file=terraform.all.tfvars -out=release.tfplan
terraform show release.tfplan      # expect: cloudflare_record DESTROY only
terraform apply release.tfplan
```

**Check:** the second plan destroys **only** `cloudflare_record` resources. If it
proposes destroying the instance, the EIP, or the backup bucket, **stop** — you
still need the old box for rollback.

**Do the DNS change during a quiet period, and watch:**

```bash
dig +short api.<zone>
curl -fsS https://api.<zone>/health
```

With `cloudflare_proxied = true` the edge address does not change at all; only the
origin behind it does, so propagation is effectively instant. Unproxied,
`cloudflare_dns_ttl` (default 60s) bounds it.

---

## 8. Rollback

**Rollback is flipping the record back.** That is the only reason the old box is
still running, and it is why step 7 must never destroy it.

```bash
terraform workspace select all
# restore the hostnames in terraform.all.tfvars
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
