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
| The public address | an Elastic IP, independent of any instance | re-associate it — step 7 |
| DNS | Namecheap, **edited by hand** | not recreated; it does not change |
| Reverse proxy config | rendered from `infra/proxy.tf` | `terraform apply` |
| TLS | Caddy + Let's Encrypt, on the box | re-issued automatically once the address moves |

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
### The lever: the Elastic IP, not DNS

**Cutover is remapping the Elastic IP from the old instance to the new one.** One
AWS API call, atomic, a few seconds. **Rollback is remapping it back.** DNS is not
touched, so the Namecheap TTL — 1800s, hand-edited — is irrelevant to both.

`infra/compute.tf` allocates the address (`aws_eip.app`) and attaches it
(`aws_eip_association.app`) as **separate** resources precisely so the address can
outlive any instance and move between them.

**The constraint that shapes this whole document:**

> **An Elastic IP can only be remapped between instances IN THE SAME AWS ACCOUNT.**

The legacy Storytime boxes live in a **different AWS account** from the target
(FateRound's `772316781095`, `eu-west-1`). So:

| Migration | Lever | DNS change? | Does the TTL matter? |
|---|---|---|---|
| **The first one** — legacy account into `772316781095` | one Namecheap A-record edit per hostname | **yes, once** | yes, once (step 7A) |
| **Every one after it** — inside `772316781095` | EIP remap | **no** | no |

That contrast is the payoff. The first move is the only one that pays the DNS tax;
after it, rebuilding or replacing a box never touches Namecheap again.

There is a way to avoid even that one edit: **AWS Elastic IP transfer between
accounts** (`aws ec2 enable-address-transfer` in the source account, then
`aws ec2 accept-address-transfer` in the destination —
<https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/elastic-ip-addresses-eip.html#transfer-EIPs-intro>).
The address itself changes accounts, so the legacy IPs keep serving traffic
throughout and no DNS record ever changes.

**It has to be initiated by whoever controls the SOURCE account** — the one that owns
the Elastic IPs the legacy hosts currently answer on (see
[`current-state.md`](current-state.md); the addresses are deliberately not repeated in
this public repository). **Identifying that account owner is an open action**, tracked
in `infra/README.md` → Open decisions. Until someone can run
`enable-address-transfer` there, plan for step 7A.


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
- `associate_eip = false` — **the new stack must not take the live address while it
  is being built.** It still gets an auto-assigned public IPv4 to test against.
- `tls_mode` — the new box **cannot obtain a Let's Encrypt certificate for a
  hostname that does not resolve to it yet**, and none of the real ones will until
  step 7. Use either:
  - a temporary hostname (e.g. `api-v2.<zone>`) with its own hand-made Namecheap A
    record pointing at the new box's auto-assigned IP, and `tls_mode = "acme"`; or
  - `tls_mode = "none"` with `allow_plaintext_origin = true` for the verification
    window only, flipping to `"acme"` as part of step 7.

  If you are rehearsing this more than once, set
  `acme_ca_directory = "https://acme-staging-v02.api.letsencrypt.org/directory"`.
  Production Let's Encrypt allows **5 duplicate certificates per week** for the
  same set of names; burning that quota on drills turns the real cutover into an
  outage.

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
> new box with no policy change. It is also inside the lifecycle rule's prefix, so a
> forgotten copy does eventually expire — **but "eventually" is up to 7 days for a
> plaintext dump of children's data, and the bucket is versioned, so it is not a
> substitute for deleting it.** See the purge step at the end of this section, and do
> not skip it.

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

When you are satisfied, **destroy the staged copy properly**. This is a full
plaintext dump of children's personal data sitting in the backup bucket.

> ### `aws s3 rm` does not delete it
>
> The backup bucket is **versioned** (`infra/backups.tf` — deliberately, so an
> overwritten or maliciously deleted dump is recoverable). On a versioned bucket
> `aws s3 rm` writes a **delete marker**: the object disappears from `aws s3 ls`
> and stays fully readable by version id. In this bucket the staged dump would
> then survive for up to **7 days**, until `noncurrent_version_expiration` reaches
> it — while the runbook claimed it was gone.
>
> Delete every version *and* every delete marker, and verify:

```bash
# From your workstation, with operator credentials — the instance role has no
# s3:DeleteObject, let alone s3:DeleteObjectVersion.
scripts/purge-s3-object-versions.sh "$NEW_BUCKET" postgres/restore-in/source.dump
```

**Check:** it prints `purge ok: ... none remaining` and exits 0. It exits **1**,
loudly, if anything survived — permissions, object lock or MFA-delete would each
leave the dump recoverable, and a cleanup step that silently leaves versions
behind is the same class of bug as a backup that silently fails.

Confirm independently if you want to see it for yourself:

```bash
aws s3api list-object-versions --bucket "$NEW_BUCKET" \
  --prefix postgres/restore-in/ \
  --query '{versions: Versions[].VersionId, markers: DeleteMarkers[].VersionId}'
```

**Check:** both lists are `null`/empty.

**If you cannot purge** — no `s3:DeleteObjectVersion`, or the bucket has object
lock — then say so out loud in the migration record rather than assuming it is
handled: **a plaintext dump remains recoverable in `$NEW_BUCKET` for up to 7 days
(the `noncurrent_version_expiration` window), after which the lifecycle rule
removes it.** That is a GDPR-relevant retention fact, not an implementation
detail.

## 6. Verify the new stack before it owns any traffic

Against its temporary hostname, or straight at its auto-assigned public IP:

```bash
NEW_IP=$(terraform output -raw instance_public_ip)   # or the temporary hostname
curl -fsS "http://$NEW_IP/health" -H 'Host: api.<zone>'
```

> The `Host:` header matters: Caddy routes by hostname, so a request to the bare IP
> matches no site block and returns a 404-ish error that looks like a broken app.

Then exercise the paths that break in interesting ways:

- **An SSE endpoint** — story generation or TTS progress. Confirm events arrive
  incrementally, not in one buffered lump at the end. This is what
  `flush_interval -1` exists for, and it is the single most likely thing to be
  subtly wrong after a proxy change.
- **A >10 MB upload**, against `client_max_body_size`/`request_body max_size 25m`.
- **A login**, proving the database restore and `JWT_SECRET` both landed.
- **A queued job** — trigger an email or a TTS batch and watch it drain, proving
  Redis and BullMQ are wired up.

**Check:** all four behave as on the old stack. **Do not move the address until
they do.**

---

## 7. Cut over

Two cases, and which one you are in is decided by a single question: **are the old
and new instances in the same AWS account?**

- **7A — different accounts** (this is the FIRST migration: the legacy boxes are
  in another account, the new stack is in FateRound's `772316781095`). One
  Namecheap A-record edit per hostname, and the 1800s TTL applies. Once.
- **7B — same account** (every migration after that, including any rebuild of a
  box inside `772316781095`). Remap the Elastic IP. No DNS change at all.

> ### The invariant, in both cases
>
> **The old box keeps running until the new one is verified in production.** Nothing
> in step 7 destroys, stops or `terraform destroy`s the old stack — that is the only
> reason rollback exists. Decommissioning is step 9, on another day.
>
> ### One address, one owner
>
> This is what replaces the old "one hostname, one owner" rule, and the EIP model
> makes it structural rather than a discipline: **an Elastic IP has exactly one
> association at a time.** Two boxes cannot both serve the address, so there is no
> round-robin-between-two-origins failure mode to avoid any more.
>
> Two things still need care:
>
> 1. **Exactly one stack may set `associate_eip = true` for a given allocation.**
>    Two workspaces both claiming it will fight on every apply, each stealing it
>    back from the other. Set it false in the old stack as part of the cutover.
> 2. **Split-brain is now a DATA problem, not a traffic one.** The old box is still
>    running with its own Postgres. It receives no requests once the address moves,
>    but if anything reaches it directly, or a queue worker there is still draining,
>    it will write to a database nobody is reading. Stop the old stack's app
>    containers if that is a real risk — but leave the box itself up.

### 7A. Different accounts — one DNS edit

**Pre-step, at least 24 hours ahead:** lower the TTL at Namecheap.

```
Namecheap -> Domain List -> Manage -> Advanced DNS -> Host Records
  set TTL to 300 (5 min) on every record you are about to move
```

**Check:** `dig +noall +answer api.<zone>` reports a TTL that counts down from ~300,
not ~1800. The old value must have expired everywhere *before* the cutover, which is
why this is a day early and not an hour.

Then, at cutover time:

```bash
terraform workspace select all-v2
# in terraform.all-v2.tfvars: real hostnames, associate_eip = true, tls_mode = "acme"
terraform apply -var-file=terraform.all-v2.tfvars

terraform output dns_records_required     # the exact rows to type into Namecheap
```

Enter those A records at Namecheap, replacing the legacy IPs.

**Check:** `dig +short api.<zone>` returns the new Elastic IP from more than one
resolver (`dig @1.1.1.1`, `dig @8.8.8.8`). Allow up to the *old* TTL for stragglers.

**Then wait for the certificate**, because ACME could not have run before this
moment — the name did not point here:

```bash
NEW_INSTANCE=$(terraform output -raw instance_id)
aws ssm send-command --instance-ids "$NEW_INSTANCE" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["systemctl restart caddy"]'
```

Restarting Caddy forces an immediate issuance attempt instead of waiting out its
retry backoff. Then:

```bash
curl -sSv https://api.<zone>/health 2>&1 | grep -E 'issuer|subject|SSL certificate'
```

**Check:** the issuer is `Let's Encrypt` (or your staging CA if rehearsing) and the
request succeeds. If it does not, go to *When TLS breaks* in
[`infra/README.md`](../infra/README.md) — and remember the rollback below is still
available.

> **This is the one migration whose IP address changes**, so it is also the one that
> breaks `storytime_be/.github/workflows/dev-deploy.yml` (see the last section).
> Edit it in the same change window.

### 7B. Same account — remap the Elastic IP

No DNS is involved. The address moves; every record stays exactly as it is.

```bash
# The address you are moving, read from the stack that currently owns it.
terraform workspace select all
OLD_ALLOC=$(terraform output -raw eip_allocation_id)
echo "$OLD_ALLOC"

# 1. The NEW stack takes the address. allow_reassociation makes this one atomic
#    call rather than detach-then-attach, so the gap is seconds.
terraform workspace select all-v2
#    in terraform.all-v2.tfvars:
#      eip_allocation_id = "<OLD_ALLOC>"
#      associate_eip     = true
terraform plan -var-file=terraform.all-v2.tfvars -out=cut.tfplan
terraform show cut.tfplan          # expect: aws_eip_association CREATE, nothing destroyed
terraform apply cut.tfplan

# 2. Tell the OLD stack to stop claiming it, so the two do not fight.
terraform workspace select all
#    in terraform.all.tfvars: associate_eip = false
terraform apply -var-file=terraform.all.tfvars
```

**Check before applying anything:** neither plan destroys an instance, an EIP or a
backup bucket. `aws_eip.app` carries `prevent_destroy`, so a plan that tries to
release the address fails loudly rather than losing it forever.

**Check after:** 

```bash
aws ec2 describe-addresses --allocation-ids "$OLD_ALLOC" \
  --query 'Addresses[0].{IP:PublicIp,Instance:InstanceId}'
curl -fsS https://api.<zone>/health
```

The instance id is the new one, the IP is unchanged, and no DNS was touched.

**Certificates:** the new box has been serving a different address until now, so it
may not hold certificates for the real hostnames yet. Restart Caddy immediately
after the remap, exactly as in 7A, and check the issuer.

**Emergency, out-of-band version** — if you need the address moved *right now* and
will reconcile Terraform afterwards:

```bash
terraform output -raw eip_remap_command    # prints the exact command
aws ec2 associate-address --allocation-id <alloc> --instance-id <target> \
  --allow-reassociation --region eu-west-1
```

Then fix the tfvars so state and reality agree again, or the next apply will move it
back.

## 8. Rollback

**Rollback is putting the address back.** That is the only reason the old box is
still running, and it is why step 7 must never destroy it.

**7B (same account) — seconds:**

```bash
# 1. New stack lets go.
terraform workspace select all-v2
#    associate_eip = false
terraform apply -var-file=terraform.all-v2.tfvars

# 2. Old stack takes it back.
terraform workspace select all
#    associate_eip = true
terraform apply -var-file=terraform.all.tfvars
```

Or, faster, in one call:
`aws ec2 associate-address --allocation-id <alloc> --instance-id <OLD instance> --allow-reassociation`
— then reconcile the tfvars.

**7A (the cross-account first migration) — minutes, not seconds.** There is no
address to move back: rollback means editing the Namecheap records back to the
legacy IPs and waiting out the TTL you lowered. That asymmetry is the reason the
TTL pre-step is not optional, and the reason to do this one during a genuinely
quiet window.

**Caveat you must think about before cutting over, in both cases:** any data written
to the NEW stack after cutover does not exist on the old one. Rolling back therefore
loses it. Either roll back fast (minutes), or dump the new stack and restore into the
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

**`aws_eip.app` also carries `prevent_destroy`, and here it matters more than
usual.** After a 7B cutover the *old* workspace still owns the allocation in its
state while the *new* stack is serving traffic on it. A destroy that released it
would take the live address away permanently — AWS will not give the same one back.
Hand the address over first:

```bash
# In the OLD workspace: stop managing the address without releasing it.
terraform state rm 'aws_eip.app[0]'
terraform destroy -var-file=terraform.all.tfvars

# In the NEW workspace: adopt it properly, so it is not orphaned.
#   set eip_allocation_id = "" in terraform.all-v2.tfvars
terraform import 'aws_eip.app[0]' <eipalloc-...>
terraform plan -var-file=terraform.all-v2.tfvars   # expect: no changes
```

Until that import, the address is real but unmanaged — which is survivable, and
is still better than releasing it, but do not leave it that way.

**The backup bucket is not `force_destroy`, so the destroy will STOP on it.** While
any object version or delete marker remains, S3 answers `DeleteBucket` with
`BucketNotEmpty`, so Terraform reports an error and the bucket — with the backup
history in it — survives. That is intentional, and it is the point: emptying the
backup history must be a separate, deliberate act, never a side effect of a destroy.

So expect a partial destroy, and read it as success rather than a fault. Everything
else is gone; the bucket is not. If you genuinely want it gone, empty it by hand
afterwards, deliberately, and prefer not to:

```bash
# Deletes EVERY version of EVERY object, including the entire backup history.
# There is no undo. `scripts/purge-s3-object-versions.sh` is per-key on purpose and
# will not do this for you.
aws s3api list-object-versions --bucket "$BUCKET" \
  --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' > /tmp/vers.json
# ...then delete-objects in batches of 1000, and repeat for DeleteMarkers, then:
aws s3api delete-bucket --bucket "$BUCKET"
```

Better alternative for a stack you are decommissioning: leave the bucket, and let
`backup_retention_days` expire the contents on its own schedule.

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
coupling this work exists to eliminate.

**It only breaks on the cross-account migration (step 7A), because that is the only
one where the address changes.** A 7B remap keeps the same Elastic IP, so the
allowlist stays valid — which is a second, quieter payoff of making the address the
lever instead of the DNS record. Edit the workflow **as part of step 7A**, in the
same change window, and check it off before you call the migration done.
