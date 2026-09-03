# Multi-Environment Flyway Setup (dev/test on EC2, production on RDS)

This runbook takes you from "SPs are edited by hand" to "every database change
is a reviewed, versioned, auditable migration" across three environments.

The core constraint that shapes every decision here: **dev and test databases
live on EC2 behind a VPN**. GitHub-hosted runners cannot reach them. The fix is
a **self-hosted runner inside your VPC** — which also removes the need to expose
production RDS to the internet.

**Time to complete:** ~1 day for dev, then weeks of real usage before test, then
weeks more before production. That pacing is the point, not a delay.

---

## Quick path

1. **Phase 1** — Provision one EC2 runner inside the existing VPC (~45 min)
2. **Phase 2** — Register the runner with GitHub and create Environments (~30 min)
3. **Phase 3** — Create least-privilege database users (~20 min)
4. **Phase 4** — Baseline the existing databases (~1 hour)
5. **Phase 5** — Add the workflows (~30 min)
6. **Phase 6** — Roll out dev → test → production, weeks apart

Do not skip ahead to production. Phase 6 explains why.

---

## What this does and does not change

| Area | Impact |
|------|--------|
| Your VPN | **No change.** Humans keep connecting exactly as today |
| Your VPC | **No new VPC.** One additional EC2 in the VPC you already have |
| Inbound firewall rules | **None added from the internet.** The runner dials out |
| Existing databases | Adopted via `baseline` — no data or schema is dropped |
| How SPs are edited | This is the change: file in Git, applied by pipeline |

The runner initiates an **outbound** HTTPS connection to GitHub and polls for
work. GitHub never opens a connection into your network.

---

## Architecture

```
                    GitHub.com
                        ▲
                        │  outbound HTTPS (443) only
                        │  runner polls for jobs
   ┌────────────────────┼──────────────────────────────┐
   │  YOUR EXISTING VPC │                              │
   │                    │                              │
   │          ┌─────────┴──────────┐                   │
   │          │  EC2 runner        │                   │
   │          │  (t3.micro)        │                   │
   │          │  sg-flyway-runner  │                   │
   │          └─────────┬──────────┘                   │
   │                    │ 3306, private IPs            │
   │        ┌───────────┼───────────┐                  │
   │        ▼           ▼           ▼                  │
   │   EC2 dev DB   EC2 test DB   RDS production       │
   │                                                    │
   └────────────────────────────────────────────────────┘
                        ▲
                        │ VPN — unchanged, humans only
                   Your laptop
```

---

## Phase 1 — AWS services

### 1.1 Confirm the VPC and subnets (no creation needed)

Every EC2 already lives in a VPC. You are adding a neighbor, not designing a
network.

```bash
# Find the VPC and subnet your dev database EC2 already uses
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=<your-dev-db-instance-name>" \
  --query 'Reservations[].Instances[].{Id:InstanceId,VPC:VpcId,Subnet:SubnetId,AZ:Placement.AvailabilityZone}' \
  --output table
```

Record the `VpcId`. The runner goes in the same VPC.

**Check whether production RDS is in that same VPC:**

```bash
aws rds describe-db-instances \
  --db-instance-identifier <your-prod-rds-id> \
  --query 'DBInstances[].{VPC:DBSubnetGroup.VpcId,Endpoint:Endpoint.Address,Public:PubliclyAccessible}' \
  --output table
```

| Result | What to do |
|--------|-----------|
| Same VPC as dev/test | One runner serves all three environments |
| Different VPC or account | **Use two runners** — one per network. This is safer anyway: the dev runner then has no path to production, even by mistake |
| `Public: true` | Plan to set it to `false` once the runner works. Nothing else should need internet access to it |

### 1.2 Decide the runner's subnet — this determines cost

The runner needs **outbound internet** to reach `github.com`. How it gets that
depends on the subnet:

| Subnet type | Outbound path | Cost | Security |
|-------------|---------------|------|----------|
| **Private + existing NAT Gateway** | Through the NAT | Already paid for | Best |
| **Private + new NAT Gateway** | Through the NAT | ~$32/mo + data | Best |
| **Public, no inbound rules** | Direct via IGW | ~$4/mo (instance only) | Acceptable |

**If you already have a NAT Gateway, use a private subnet.** If not, a public
subnet with a Security Group that allows **zero inbound traffic** is a
reasonable trade-off for a first rollout — the instance has a public IP but
nothing can connect to it. Use SSM (step 1.4) instead of SSH so you never open
port 22.

Check for an existing NAT:

```bash
aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=<your-vpc-id>" "Name=state,Values=available" \
  --query 'NatGateways[].{Id:NatGatewayId,Subnet:SubnetId}' --output table
```

### 1.3 Create the runner's Security Group

Two Security Groups working as a pair is the cleanest model: one identifies the
runner, the other grants it access.

```bash
aws ec2 create-security-group \
  --group-name sg-flyway-runner \
  --description "GitHub Actions self-hosted runner for Flyway migrations" \
  --vpc-id <your-vpc-id>
# Record the returned GroupId as SG_RUNNER
```

**Inbound rules: none.** Leave it empty. Do not add SSH.

AWS grants all outbound traffic by default, which is what the runner needs. To
be explicit and restrictive instead:

```bash
# Optional hardening: replace the default allow-all egress
aws ec2 revoke-security-group-egress --group-id <SG_RUNNER> \
  --protocol -1 --port -1 --cidr 0.0.0.0/0

aws ec2 authorize-security-group-egress --group-id <SG_RUNNER> \
  --protocol tcp --port 443 --cidr 0.0.0.0/0   # GitHub + package repos

aws ec2 authorize-security-group-egress --group-id <SG_RUNNER> \
  --protocol tcp --port 3306 --cidr <your-vpc-cidr>   # databases, internal only
```

### 1.4 Create an IAM role for the runner

This role is **not** for database access — Flyway authenticates with a username
and password. It exists so you can reach the instance through Session Manager
without ever opening port 22.

```bash
cat > /tmp/ec2-trust.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
JSON

aws iam create-role --role-name FlywayRunnerRole \
  --assume-role-policy-document file:///tmp/ec2-trust.json

aws iam attach-role-policy --role-name FlywayRunnerRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam create-instance-profile --instance-profile-name FlywayRunnerProfile
aws iam add-role-to-instance-profile \
  --instance-profile-name FlywayRunnerProfile --role-name FlywayRunnerRole
```

**Why `AmazonSSMManagedInstanceCore` and nothing else:** it grants exactly the
permissions the SSM agent needs to register the instance and open a shell
session. It grants no access to S3, RDS, or any other service. Access to the
instance is then controlled by IAM permissions on *your* user, and every session
is logged in CloudTrail.

### 1.5 Launch the runner instance

```bash
aws ec2 run-instances \
  --image-id <latest-amazon-linux-2023-ami> \
  --instance-type t3.micro \
  --subnet-id <runner-subnet-id> \
  --security-group-ids <SG_RUNNER> \
  --iam-instance-profile Name=FlywayRunnerProfile \
  --no-associate-public-ip-address \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=flyway-gh-runner}]'
```

Notes:

- Drop `--no-associate-public-ip-address` if you chose a public subnet.
- `t3.micro` is sufficient. Flyway migrations are I/O-bound, not CPU-bound.
- Find the current AMI: `aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query 'Parameters[].Value' --output text`

### 1.6 Grant the runner access to each database

This is the one change to your existing infrastructure. Grant by **Security
Group reference**, not by IP — IPs change, group membership does not.

```bash
# For each database Security Group (dev EC2, test EC2, prod RDS):
aws ec2 authorize-security-group-ingress \
  --group-id <sg-of-the-database> \
  --protocol tcp --port 3306 \
  --source-group <SG_RUNNER>
```

This traffic never leaves the VPC. Nothing becomes reachable from the internet.

**If the dev/test databases run MySQL on the EC2 host itself**, also confirm
MySQL is listening on the private interface, not only on loopback:

```ini
# /etc/mysql/mysql.conf.d/mysqld.cnf  (or /etc/my.cnf)
bind-address = 0.0.0.0
```

Restart MySQL after changing this.

### 1.7 Verify connectivity before going further

Connect to the runner through SSM and prove it can reach every database. **Do
not proceed until all three succeed.**

```bash
aws ssm start-session --target <runner-instance-id>
```

Then, on the runner:

```bash
sudo dnf install -y mariadb105 java-17-amazon-corretto-headless

# One check per environment
mysql -h <dev-ec2-private-ip>  -u <user> -p -e "SELECT 1;"
mysql -h <test-ec2-private-ip> -u <user> -p -e "SELECT 1;"
mysql -h <prod-rds-endpoint>   -u <user> -p -e "SELECT 1;"
```

A hang means a Security Group is blocking you. `Access denied` means the network
is fine and only the credentials are wrong — that is progress.

---

## Phase 2 — GitHub

### 2.1 Install the runner service

In the repository: **Settings → Actions → Runners → New self-hosted runner →
Linux**. GitHub generates a token and the exact commands. On the runner:

```bash
sudo dnf install -y libicu tar gzip
mkdir ~/actions-runner && cd ~/actions-runner
curl -o actions-runner-linux-x64.tar.gz -L <url-from-github>
tar xzf actions-runner-linux-x64.tar.gz

./config.sh --url https://github.com/<org>/<repo> \
            --token <token-from-github> \
            --labels self-hosted,linux,vpc-interna \
            --unattended

sudo ./svc.sh install
sudo ./svc.sh start
sudo ./svc.sh status
```

The `vpc-interna` label is how workflows target this runner. Keep the name
stable — the workflows reference it.

Confirm it shows **Idle** in Settings → Actions → Runners.

### 2.2 Create the three Environments

**Settings → Environments → New environment.** Create `dev`, `test`, and
`production`.

Environments are not cosmetic. A job declaring `environment: dev` is
**technically unable** to read secrets scoped to `production`. That is an
enforced boundary, not a convention.

### 2.3 Add secrets per environment

For each environment, add these five secrets:

| Secret | dev | test | production |
|--------|-----|------|-----------|
| `DB_HOST` | dev EC2 private IP | test EC2 private IP | RDS endpoint |
| `DB_PORT` | `3306` | `3306` | `3306` |
| `DB_NAME` | schema name | schema name | schema name |
| `DB_USER` | `flyway_dev` | `flyway_test` | `flyway_prod` |
| `DB_PASSWORD` | *(distinct)* | *(distinct)* | *(distinct)* |

Use a **different password per environment**. If one leaks, the blast radius
stops at that environment.

Via CLI:

```bash
gh secret set DB_HOST --env dev
gh secret set DB_PASSWORD --env dev
# ... repeat per secret, per environment
```

GitHub masks any secret value in workflow logs automatically. You will see
`Database: ******** (MySQL 8.0)` rather than the endpoint.

### 2.4 Protect the production environment

In **Settings → Environments → production**, enable:

- ☑️ **Required reviewers** — name at least one person (not yourself alone)
- ☑️ **Deployment branches: Selected branches → `main`** only
- ☑️ **Wait timer: 0** (the reviewer gate is what matters)

A production migration now pauses at *Waiting for approval* until a named human
clicks Approve. That click is recorded permanently.

---

## Phase 3 — Database users

Create a dedicated Flyway user per environment. Never reuse an application user
and never use `root`.

```sql
CREATE USER 'flyway_dev'@'%' IDENTIFIED BY '<strong-password>';

GRANT SELECT, INSERT, UPDATE, DELETE,
      CREATE, ALTER, DROP, INDEX, REFERENCES,
      CREATE ROUTINE, ALTER ROUTINE, EXECUTE,
      CREATE VIEW, SHOW VIEW, TRIGGER
  ON <schema_name>.* TO 'flyway_dev'@'%';

FLUSH PRIVILEGES;
```

| Grant | Needed for |
|-------|-----------|
| `CREATE`, `ALTER`, `DROP`, `INDEX` | Table and column migrations |
| `CREATE ROUTINE`, `ALTER ROUTINE` | Stored procedures — your main use case |
| `SELECT`, `INSERT`, `UPDATE`, `DELETE` | The `flyway_schema_history` table and data migrations |
| `REFERENCES` | Foreign keys |

Scope every grant to the single schema. No `*.*`, no `GRANT ALL`, no
`SUPER`, no `FILE`.

Restrict the host where you can — `'flyway_prod'@'10.0.%'` is better than `'%'`
if your runner's subnet is stable.

---

## Phase 4 — Baseline the existing databases

**This is the step people skip, and it is the one that breaks the first run.**

Your databases already contain tables and stored procedures. Running
`flyway migrate` against them without preparation makes Flyway assume the schema
is empty, attempt `V1__baseline_schema.sql`, and fail with `table already
exists`.

Baselining tells Flyway: *everything up to this point already exists — start
counting from here.*

### 4.1 Capture the current production schema

Production is the source of truth for what the schema actually is.

```bash
mysqldump -h <prod-rds-endpoint> -u <readonly-user> -p \
  --no-data --routines --triggers --events \
  --skip-add-drop-table --skip-comments \
  <schema_name> > /tmp/prod-schema-snapshot.sql
```

`--no-data` captures structure only. `--routines` is what pulls in your stored
procedures.

### 4.2 Split the snapshot into migration files

```
sql/
  V1__existing_schema_baseline.sql   ← tables, from the dump. Documentation only.
  R__sp_actualizar_pedido.sql        ← one file per SP, extracted from the dump
  R__sp_get_cliente.sql
  R__sp_...
```

For each stored procedure in the dump, create one `R__<name>.sql` containing:

```sql
DROP PROCEDURE IF EXISTS <name>;

DELIMITER //
CREATE PROCEDURE <name>(...)
BEGIN
    -- body copied verbatim from the dump
END //
DELIMITER ;
```

Copy the bodies **verbatim**. Do not fix, reformat, or improve anything yet.
The first commit must be a faithful snapshot of reality — improvements come as
separate, reviewable PRs afterward.

Commit this. **This commit is the moment your stored procedures enter version
control.**

### 4.3 Run baseline on each environment

Once per database, starting with dev:

```bash
flyway -url="jdbc:mysql://<host>:3306/<schema>" \
       -user=<user> -password=<pass> \
       -baselineVersion=1 \
       -baselineDescription="Existing schema before Flyway adoption" \
       baseline
```

This creates `flyway_schema_history` with exactly one row marking version 1 as
applied. No schema objects are touched.

### 4.4 Verify the baseline

```bash
flyway -url=... -locations=filesystem:sql info
```

Expected output:

| Category | Version | State |
|----------|---------|-------|
| Versioned | 1 | `Baseline` |
| Repeatable | | `Pending` (each SP file) |

The `R__` files show as `Pending` because Flyway has not applied them yet. The
first `migrate` will run them — which drops and recreates each procedure with
**the exact same body it already has**. Behavior does not change. From that
point forward, Flyway owns them.

---

## Phase 5 — Workflows

### 5.1 Shared setup step

`.github/workflows/db-dev-test.yml`:

```yaml
name: DB migrate (dev + test)

on:
  push:
    branches: [main]
    paths:
      - "sql/**"
      - ".github/workflows/db-*.yml"

env:
  FLYWAY_VERSION: "10.20.1"

jobs:
  dev:
    runs-on: [self-hosted, linux, vpc-interna]
    environment: dev
    concurrency:
      group: flyway-dev
      cancel-in-progress: false
    steps:
      - uses: actions/checkout@v4

      - name: Install Flyway CLI (pinned)
        run: |
          curl -sSL -o "$RUNNER_TEMP/flyway.tar.gz" \
            "https://repo1.maven.org/maven2/org/flywaydb/flyway-commandline/${FLYWAY_VERSION}/flyway-commandline-${FLYWAY_VERSION}-linux-x64.tar.gz"
          tar -xzf "$RUNNER_TEMP/flyway.tar.gz" -C "$RUNNER_TEMP"
          echo "$RUNNER_TEMP/flyway-${FLYWAY_VERSION}" >> "$GITHUB_PATH"

      - name: Info (before)
        run: flyway -locations=filesystem:sql -cleanDisabled=true info
        env: &conn
          FLYWAY_URL: "jdbc:mysql://${{ secrets.DB_HOST }}:${{ secrets.DB_PORT }}/${{ secrets.DB_NAME }}"
          FLYWAY_USER: ${{ secrets.DB_USER }}
          FLYWAY_PASSWORD: ${{ secrets.DB_PASSWORD }}

      - name: Migrate
        run: flyway -locations=filesystem:sql -cleanDisabled=true migrate
        env: *conn

      - name: Info (after)
        run: flyway -locations=filesystem:sql -cleanDisabled=true info
        env: *conn

  test:
    needs: dev
    runs-on: [self-hosted, linux, vpc-interna]
    environment: test
    concurrency:
      group: flyway-test
      cancel-in-progress: false
    steps:
      # identical steps, resolving `test` environment secrets
```

### 5.2 Production workflow — manual and gated

`.github/workflows/db-prod.yml`:

```yaml
name: DB migrate (PRODUCTION)

on:
  workflow_dispatch: {}     # manual only — never on push

env:
  FLYWAY_VERSION: "10.20.1"

jobs:
  production:
    runs-on: [self-hosted, linux, vpc-interna]
    environment: production      # triggers the approval gate
    concurrency:
      group: flyway-prod
      cancel-in-progress: false
    steps:
      - uses: actions/checkout@v4
      - name: Install Flyway CLI (pinned)
        run: |
          curl -sSL -o "$RUNNER_TEMP/flyway.tar.gz" \
            "https://repo1.maven.org/maven2/org/flywaydb/flyway-commandline/${FLYWAY_VERSION}/flyway-commandline-${FLYWAY_VERSION}-linux-x64.tar.gz"
          tar -xzf "$RUNNER_TEMP/flyway.tar.gz" -C "$RUNNER_TEMP"
          echo "$RUNNER_TEMP/flyway-${FLYWAY_VERSION}" >> "$GITHUB_PATH"

      - name: Validate (applies nothing)
        run: flyway -locations=filesystem:sql -cleanDisabled=true validate
        env: &conn
          FLYWAY_URL: "jdbc:mysql://${{ secrets.DB_HOST }}:${{ secrets.DB_PORT }}/${{ secrets.DB_NAME }}"
          FLYWAY_USER: ${{ secrets.DB_USER }}
          FLYWAY_PASSWORD: ${{ secrets.DB_PASSWORD }}

      - name: Info (before)
        run: flyway -locations=filesystem:sql -cleanDisabled=true info
        env: *conn

      - name: Migrate
        run: flyway -locations=filesystem:sql -cleanDisabled=true migrate
        env: *conn

      - name: Info (after)
        run: flyway -locations=filesystem:sql -cleanDisabled=true info
        env: *conn
```

### 5.3 Why these specific settings

| Setting | Reason |
|---------|--------|
| `concurrency.group` per environment | Two simultaneous `migrate` runs against one database corrupt the history table |
| `cancel-in-progress: false` | Never kill a migration mid-flight. Queue instead |
| `needs: dev` on the test job | If dev fails, test is never attempted. The chain stops itself |
| `-cleanDisabled=true` | `flyway clean` drops the entire schema. Make the prohibition visible in the file |
| `workflow_dispatch` only for prod | Merging says "the code is correct". Deploying says "ship it now". Different decisions |
| `validate` before `migrate` in prod | Fails fast on any checksum drift without touching anything |
| Pinned `FLYWAY_VERSION` | A new Flyway release must never reach production unreviewed |
| `info` before and after | Permanent audit trail in the Actions log |

Keep the pinned CI version aligned with what developers run locally.

---

## Phase 6 — Rollout order

**Do not configure all three environments in one sitting.**

| Stage | Duration | Exit criteria |
|-------|----------|---------------|
| **1. dev only** | 2–4 weeks | The team has run 10+ real migrations. Someone has broken it and recovered without help |
| **2. add test** | 2–4 weeks | QA has validated changes that arrived via the pipeline. The `needs:` chain has caught at least one real failure |
| **3. add production** | — | Everything in the checklist below is true |

The value of this pacing is that every mistake your team is going to make gets
made in dev, where it costs nothing. Compressing the timeline moves those
mistakes to production.

---

## Production readiness checklist

Do not run the production workflow until every line is true.

**Infrastructure**

- [ ] The runner reaches the production RDS endpoint (verified from the runner shell)
- [ ] Production RDS `PubliclyAccessible` is `false`
- [ ] Production RDS Security Group allows 3306 only from `sg-flyway-runner`
- [ ] Automated RDS backups are enabled with an adequate retention window

**Access**

- [ ] `flyway_prod` is a dedicated user, scoped to one schema, with no `SUPER` or `GRANT ALL`
- [ ] The production password differs from dev and test
- [ ] Production secrets exist only in the `production` GitHub Environment
- [ ] `Required reviewers` is enabled and names someone other than the person deploying
- [ ] `Deployment branches` is restricted to `main`

**Migrations**

- [ ] Every migration in `sql/` ran successfully in dev, then in test
- [ ] `flyway baseline` has been run on production and `flyway info` reports a clean state
- [ ] `flyway validate` against production passes with zero checksum mismatches
- [ ] No `V__` file has been edited since it was applied anywhere
- [ ] Every stored procedure currently in production exists as an `R__` file in Git

**Process**

- [ ] A manual RDS snapshot was taken immediately before the first production run
- [ ] The team knows that `V__` files are immutable once applied
- [ ] The team knows `flyway repair` is not a routine command
- [ ] A rollback plan exists for the specific migration being applied
- [ ] The first production run is scheduled in a low-traffic window with the team available

**The single most important line:** take a manual snapshot before the first
production migration. Flyway does not roll back DDL. MySQL does not support
transactional DDL. If a migration half-applies, the snapshot is your recovery
path.

```bash
aws rds create-db-snapshot \
  --db-instance-identifier <prod-rds-id> \
  --db-snapshot-identifier flyway-adoption-$(date +%Y%m%d-%H%M)
```

---

## Rollback

There is no `flyway undo` in the OSS edition. Plan forward instead.

| Situation | Response |
|-----------|----------|
| A stored procedure (`R__`) is wrong | Revert the file in Git, merge, re-run. The previous body is restored |
| A `V__` migration applied but was wrong | Write `V<next>__fix_....sql`. **Never edit the applied file** |
| A `V__` migration failed midway | Fix the state manually, delete the failed row from `flyway_schema_history`, then re-run. Investigate before repeating |
| The schema is unrecoverable | Restore the snapshot. This is why you took one |

Repeatable migrations are cheap to reverse — that is a strong argument for
keeping stored procedures in `R__` files.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Job hangs, then connection timeout | Security Group blocks the runner | Add ingress 3306 from `sg-flyway-runner` |
| `Access denied for user` | Wrong credentials — but the network is fine | Check the environment's secrets |
| `Table 'x' already exists` on first run | Baseline was skipped | Run `flyway baseline` (Phase 4) |
| `checksum mismatch` | An applied `V__` file was edited | Revert the file. Use `repair` only if the edit was intentional and agreed |
| Runner shows Offline | Service stopped | `sudo ./svc.sh status` on the instance |
| Job queues forever | No runner matches the labels | Check labels match `[self-hosted, linux, vpc-interna]` |
| `Communications link failure` | MySQL bound to loopback only | Set `bind-address = 0.0.0.0` and restart |

---

## Daily workflow, once this is live

```
1. git checkout -b feat/<change>
2. Edit sql/R__<procedure>.sql
3. Test locally against Docker: flyway info → migrate → CALL
4. Push, open a Pull Request
5. Team reviews the SP diff            ← the point of all this
6. Merge to main  → dev migrates → test migrates
7. QA validates in test
8. Actions → "DB migrate (PRODUCTION)" → Run workflow → approve
```

Step 5 is the payoff. A reviewer sees exactly which line of the procedure
changed, and can reject it before it reaches any database.

---

## Next step

Start with Phase 1 and stop after step 1.7. Connectivity from the runner to the
dev database is the gate — everything downstream assumes it works, and nothing
else is worth configuring until it does.
