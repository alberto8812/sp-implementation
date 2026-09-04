# Lab walkthrough — what was actually run

A record of the AWS lab as it was built and verified on 2026-09-03, in the
order the steps were executed, including three places where the outcome
differed from [`../terraform/README.md`](../terraform/README.md).

The lab README describes the module. This document describes the run: the
commands that worked, the ones that did not, and why.

**Target audience**: whoever repeats this — including you, three months from
now, before adopting the same pattern on the company infrastructure described
in [`aws-multi-environment-setup.md`](aws-multi-environment-setup.md).

---

## What ended up existing

```
GitHub repo  alberto8812/sp-implementation
AWS account  783161929476, IAM user carlos-admin, us-east-1

VPC          vpc-097dc78a2615ce5a4          10.42.0.0/16
runner       i-0596c82b184c4c906            labels: self-hosted, linux, vpc-interna
dev          10.42.2.38                     EC2, MySQL 8.0, private IP only
test         10.42.17.47                    EC2, MySQL 8.0, private IP only
production   flyway-demo-production.<...>.us-east-1.rds.amazonaws.com
```

54 Terraform resources. The three databases carry the same schema
(`flyway_demo`) and the same least-privilege user (`flyway_app`).

---

## Step 0 — Prerequisites

| Tool | Why it is needed | Install |
|------|------------------|---------|
| Terraform ≥ 1.5 | Builds the lab | `brew install terraform` |
| AWS CLI v2 | Everything else | `brew install awscli` |
| `session-manager-plugin` | **The only way into the instances.** No port 22 is ever opened, so without it you can create the lab and then not reach it | `brew install --cask session-manager-plugin` |
| GitHub CLI | Loads the environment secrets | `brew install gh` |

### AWS credentials, on a fresh personal account

1. Enable MFA on the root user. Never create root access keys.
2. IAM → Users → Create user (`carlos-admin`). Do **not** grant console access;
   this identity is for the CLI only.
3. Attach `AdministratorAccess`. The module creates VPC networking, EC2, RDS,
   IAM roles, instance profiles and SSM parameters; scoping that policy by hand
   costs an hour and teaches nothing about Flyway. On a shared account, ask for
   the narrower policy listed in the lab README instead.
4. Security credentials → Create access key → **Command Line Interface**. The
   secret is shown once.
5. `aws configure` — region `us-east-1`, output `json`.
6. Verify: `aws sts get-caller-identity` must return the `carlos-admin` ARN.

### Budget alarm

The lab bills **by the hour**, roughly 42 USD per month equivalent. There is no
auto-shutdown.

Billing and Cost Management → Budgets → Monthly cost budget → **10 USD** with
an email notification. If that mail arrives, something was left running.

---

## Step 1 — Repository

The self-hosted runner registers against a specific repository and polls it for
work, so the remote has to exist before anything is built.

Commit in this order, and check the ignore rules first:

```bash
git check-ignore -v terraform/terraform.tfvars   # must match *.tfvars
git status --short                               # must be clean afterwards
```

`terraform.tfvars` holds the GitHub PAT and `terraform.tfstate` holds the
generated database passwords in cleartext. A secret pushed to GitHub is
compromised even after deletion — it stays in the history. Confirm the ignore
rules are committed *before* the first push, not after.

### Terraform and the migrations live in the same repository

For a lab, one repository. The module is coupled to this repo by design: it
takes `github_owner`/`github_repo` and registers the runner against them.

The risk that usually argues for splitting them is already handled — the
workflow filters on `paths: sql/**`, so a change under `terraform/` does not
trigger a migration.

For real infrastructure, split them: a merge under `sql/` runs a migration, a
merge under `terraform/` can destroy a VPC. Different blast radius, different
reviewers, different cadence.

---

## Step 2 — Deploy the infrastructure

### The GitHub PAT

Settings → Developer settings → Personal access tokens → **Tokens (classic)**.
Scope: **`repo`**, nothing else. Expiry: 7 days.

The token is baked into the runner's `user_data`, which is normally
unacceptable. It is tolerable here only because all three of these hold: it is
used once at boot to exchange for a short-lived registration token, it expires
in a week, and it is revoked as soon as the runner reports **Idle**. Production
uses a GitHub App instead.

### terraform.tfvars

```hcl
aws_region      = "us-east-1"
project_name    = "flyway-demo"
vpc_cidr        = "10.42.0.0/16"
use_nat_gateway = false

github_owner = "alberto8812"
github_repo  = "sp-implementation"
github_pat   = "ghp_..."          # revoke after the runner shows Idle
```

`github_owner` and `github_repo` must match the repository exactly. A mismatch
is the most common failure: the instance boots, asks for a registration token,
GitHub refuses, and the runner never appears.

`use_nat_gateway = false` saves about 33 USD/month. The instances sit in public
subnets with Security Groups that allow **zero inbound traffic**. The public
subnet is not the risk; an open ingress rule would be.

### Apply

```bash
terraform init
terraform plan     # expect: 54 to add, 0 to change, 0 to destroy
terraform apply
```

8–12 minutes, dominated by RDS.

Read the plan before approving. Three Security Groups, **two ingress rules** —
that pair of numbers is the whole architecture. The two rules are "EC2 MySQL
accepts 3306 from the runner's Security Group" and "RDS accepts 3306 from the
runner's Security Group". The runner's own group has none.

Both rules reference the runner's **Security Group ID**, not a CIDR. The rule
survives an instance replacement, and a different instance in the same subnet
does not inherit the access. Identity, not location.

---

## Step 3 — Post-apply

### 3.1 Confirm the runner, then revoke the PAT

Settings → Actions → Runners. `flyway-demo-runner` must show **Idle** with
`self-hosted`, `linux`, `vpc-interna`. Allow 2–3 minutes after apply returns.

If it does not appear:

```bash
aws ssm start-session --target <runner_instance_id> --region us-east-1
sudo tail -100 /var/log/flyway-runner-bootstrap.log
```

The log names which of the three usual causes it was, and never prints the
token.

Once it shows Idle, **delete the PAT in GitHub.** It has done its only job.

### 3.2 Create the Flyway user on RDS

dev and test create their own Flyway user at boot, because the bootstrap script
runs on the database host. RDS is a managed service with no host to run
anything on, so this is manual — once.

From the runner (`aws ssm start-session --target <runner_instance_id>`):

```bash
PROJECT=flyway-demo
REGION=us-east-1
SCHEMA=flyway_demo
FLYWAY_USER=flyway_app
RDS_HOST=<rds_endpoint from terraform output>

MASTER_PW="$(aws ssm get-parameter --region "$REGION" \
  --name "/$PROJECT/production/rds_master_password" \
  --with-decryption --query Parameter.Value --output text)"

FLYWAY_PW="$(aws ssm get-parameter --region "$REGION" \
  --name "/$PROJECT/production/db_password" \
  --with-decryption --query Parameter.Value --output text)"

echo "master: ${#MASTER_PW} chars, flyway: ${#FLYWAY_PW} chars"   # both 24
```

Both must report 24 characters. A zero means the runner's IAM role could not
read the parameter, and nothing below will work.

```bash
umask 077
cat > "$HOME/.rds.cnf" <<EOF
[client]
host=$RDS_HOST
user=flyway_admin
password=$MASTER_PW
EOF

mysql --defaults-extra-file="$HOME/.rds.cnf" <<SQL
CREATE USER IF NOT EXISTS '$FLYWAY_USER'@'%' IDENTIFIED BY '$FLYWAY_PW';
ALTER USER '$FLYWAY_USER'@'%' IDENTIFIED BY '$FLYWAY_PW';

GRANT SELECT, INSERT, UPDATE, DELETE,
      CREATE, ALTER, DROP, INDEX, REFERENCES,
      CREATE ROUTINE, ALTER ROUTINE, EXECUTE,
      CREATE VIEW, SHOW VIEW, TRIGGER
  ON \`$SCHEMA\`.* TO '$FLYWAY_USER'@'%';

FLUSH PRIVILEGES;
SQL

shred -u "$HOME/.rds.cnf"
```

The defaults file exists so the password never reaches `ps aux` or the shell
history. `umask 077` makes it mode 600.

The grant is not `GRANT ALL` and not `ON *.*`. `CREATE ROUTINE` and
`ALTER ROUTINE` are there because stored procedures are the point of the
project. `DROP` is there because migrations legitimately need it; what makes
that tolerable is backups, the production approval gate, and
`-cleanDisabled=true`.

Verify all three environments before moving on:

```bash
mysql -h "$RDS_HOST"  -u "$FLYWAY_USER" -p"$FLYWAY_PW" -e "SHOW GRANTS FOR CURRENT_USER();"
mysql -h 10.42.2.38   -u "$FLYWAY_USER" -p"$DEV_PW"    -e "SELECT 'dev OK';"
mysql -h 10.42.17.47  -u "$FLYWAY_USER" -p"$TEST_PW"   -e "SELECT 'test OK';"
```

`SHOW GRANTS` should return exactly two rows: `GRANT USAGE ON *.*` — which
grants nothing, it only means the user exists — and the scoped grant on
`` `flyway_demo`.* ``.

A hang means a Security Group is blocking. `Access denied` means the network is
fine and only the credentials are wrong, which is progress.

### 3.3 The three GitHub Environments

Settings → Environments → New environment: `dev`, `test`, `production`.

A GitHub Environment is a boundary GitHub enforces, not a naming convention. A
secret stored in `production` is unreadable by a job declaring
`environment: dev` — not discouraged, unavailable. This is the mechanism that
makes it impossible for a dev run to reach the production database.

Then, from a machine where `gh` is authenticated:

```bash
terraform output -raw github_secret_commands
```

That prints 15 commands, already filled in. Each password is piped straight
from Parameter Store into `gh secret set`, so it never becomes a literal in the
shell history.

Verify:

```bash
gh secret list --env dev
gh secret list --env test
gh secret list --env production
```

Five per environment: `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`,
`DB_PASSWORD`.

> In zsh, the `#` comment lines in that output fail with
> `command not found: #`. Harmless — the real commands still run.

### 3.4 Protect production

Settings → Environments → production:

| Setting | Value |
|---------|-------|
| Required reviewers | at least one person |
| Prevent self-review | **off** in a one-person lab, **on** in a real team |
| Wait timer | off |
| Allow administrators to bypass | **off** |
| Deployment branches and tags | Selected → `main` |

Two separate saves: the green **Save protection rules** button covers the
reviewer block, and the branch policy saves on its own. Configuring reviewers
and walking away leaves production open to every branch.

Leaving the admin bypass enabled means the person in a hurry can switch the
rule off alone, which makes it a suggestion rather than a rule.

`Prevent self-review` requires an approver other than whoever triggered the
run. That is correct in a team and self-defeating alone — you would trigger a
deployment you can never approve.

Verify against the API, not the page:

```bash
gh api repos/<owner>/<repo>/environments/production \
  --jq '{admins_can_bypass: .can_admins_bypass,
         rules: [.protection_rules[].type],
         branch_policy: .deployment_branch_policy}'
```

Expect `"admins_can_bypass": false`.

### 3.5 Baseline the three databases

```bash
FLYWAY_VERSION=10.20.1
mkdir -p "$HOME/flyway" "$HOME/nosql"
curl -sSL -o "$HOME/flyway.tar.gz" \
  "https://repo1.maven.org/maven2/org/flywaydb/flyway-commandline/${FLYWAY_VERSION}/flyway-commandline-${FLYWAY_VERSION}-linux-x64.tar.gz"
tar -xzf "$HOME/flyway.tar.gz" -C "$HOME/flyway"
export PATH="$HOME/flyway/flyway-${FLYWAY_VERSION}:$PATH"

for ENV in dev test production; do
  echo "=== $ENV ==="
  HOST="$(aws ssm get-parameter --region "$REGION" --name "/$PROJECT/$ENV/db_host" --query Parameter.Value --output text)"
  PW="$(aws ssm get-parameter --region "$REGION" --name "/$PROJECT/$ENV/db_password" --with-decryption --query Parameter.Value --output text)"
  flyway -url="jdbc:mysql://$HOST:3306/$SCHEMA" \
         -user="$FLYWAY_USER" -password="$PW" \
         -locations=filesystem:"$HOME/nosql" \
         -cleanDisabled=true \
         -baselineVersion=0 \
         -baselineDescription="Before Flyway adoption" \
         baseline
done
```

Expect `Successfully baselined schema with version: 0` three times.

Extract under `$HOME`, **not** `/tmp` — see correction 3 below.

`baseline` writes one row into a new `flyway_schema_history` table and does not
touch anything else. `migrate` then applies everything above the baseline
version.

---

## Step 4 — The promotion pipeline

The workflow that shipped with the repository targeted a single environment
using repository-level `RDS_*` secrets. It was replaced by two files.

**`.github/workflows/flyway-migrate.yml`** — the orchestrator:

```yaml
dev  →  test (needs: dev)  →  production (needs: test)
```

**`.github/workflows/flyway-run.yml`** — a reusable workflow, called once per
environment.

Four lines carry the design:

| Line | What it buys |
|------|--------------|
| `runs-on: [self-hosted, linux, vpc-interna]` | GitHub-hosted runners have no route to the private databases |
| `environment: ${{ inputs.environment }}` | Scopes the secrets **and** applies the protection rules. A production run pauses here |
| `needs: test` | Production is unreachable if test failed — the job does not start |
| `flyway validate` | Fails when an already-applied versioned migration has been edited |
| `FLYWAY_CLEAN_DISABLED: "true"` | `flyway clean` drops every object in the schema. Nothing here needs it |

Push, and the run walks dev → test → production, stopping at
**Waiting for approval**. Approving records who approved, when, for which
environment, and with what comment — permanently.

---

## Three corrections to the lab README

### 1. `runs-on` pointed at a GitHub-hosted runner

`.github/workflows/flyway-migrate.yml` shipped with `runs-on: ubuntu-latest`.
The whole lab exists so that a runner **inside** the VPC can reach private
databases. With that line, the runner registers, reports Idle, and never
receives a job, while the jobs run in GitHub's cloud where the databases are
unreachable.

Fixed to `runs-on: [self-hosted, linux, vpc-interna]` — the labels the module
assigns.

### 2. `-baselineVersion=1` skips the migration that creates the schema

The lab README, section 5.5, baselines at version 1. But
`sql/V1__baseline_schema.sql` **creates** `clientes` and `pedidos`.

Baselining at 1 tells Flyway that version 1 is already applied, so `migrate`
only applies versions above it:

| Migration | Result on an empty schema |
|-----------|---------------------------|
| `V1__baseline_schema.sql` | Skipped. The tables are never created |
| `V2__create_sp_get_cliente.sql` | Succeeds — MySQL does not resolve table references when creating a procedure |
| `V3__add_telefono_clientes.sql` | Fails: `Table 'clientes' doesn't exist` |

`baseline` exists for the opposite situation, and it is the situation this
project is ultimately aimed at: an existing database, full of objects and
years of data, adopting Flyway now. It means "everything that exists today is
the starting point, do not try to recreate it".

Here the schemas are empty and `V1` builds them, so `-baselineVersion=0` is
correct: the history table is created, the mechanism is exercised, and nothing
is skipped. Confirmed working on Flyway 10.20.1.

### 3. `flyway validate` fails on pending migrations

`validate` treats a resolved-but-not-applied migration as a failure by default:

```
ERROR: Validate failed: Migrations have failed validation
Detected resolved migration not applied to database: 1.
```

On the first run of any environment, *every* migration is pending, so a
`validate` step placed before `migrate` always fails.

What is worth keeping from `validate` is the checksum check — the guard against
an already-applied versioned migration being edited. Pending migrations are the
normal state before a migrate, so they are excluded:

```yaml
run: flyway -locations=filesystem:sql -ignoreMigrationPatterns='*:pending' validate
```

### 4. `/tmp` on the runner is a 457 MB tmpfs

Amazon Linux 2023 mounts `/tmp` as tmpfs — RAM, not disk. On a `t3.micro` with
1 GB of RAM that is about 457 MB. The Flyway command-line tarball bundles a
full JRE and does not fit:

```
tar: ... Cannot create symlink ...: No space left on device
WARNING: Skipping unloadable jar file: ... (zip file is empty)
```

The extraction half-succeeds and leaves truncated jars. It may still appear to
work if the driver you need happened to extract.

Extract under `$HOME` instead — the root volume has 20 GB, of which about 17 GB
are free. The workflow is unaffected: `$RUNNER_TEMP` lives under
`/home/ghrunner/actions-runner/_work/_temp`, on the EBS volume.

---

## Day-to-day: which file type for what

This is the distinction the whole adoption rests on.

### `R__` — repeatable. Stored procedures go here.

```
sql/R__sp_actualizar_pedido.sql   →  CREATE PROCEDURE sp_actualizar_pedido
sql/R__sp_get_cliente.sql         →  CREATE PROCEDURE sp_get_cliente
```

**Edit these in place, as often as needed.** One file per procedure, always the
same file. Flyway notices the checksum changed and re-applies it.

The prefix is on the **file name**, and it is how Flyway decides how to treat
the file — it never inspects the contents to decide. The procedure inside keeps
its own name, and callers keep using `CALL sp_actualizar_pedido(...)`
unchanged.

MySQL 8 has no `CREATE OR REPLACE PROCEDURE`, so a repeatable migration starts
with `DROP PROCEDURE IF EXISTS`. That is what makes it safe to run repeatedly.

Convention for the team: **`R__` plus the procedure's exact name.** No
deliberation required.

### `V__` — versioned. Structural change goes here.

```
sql/V3__add_telefono_clientes.sql
```

**Never edit these after they are applied.** An `ALTER TABLE` that already ran
cannot run again. The next change is a new file: `V4__`, `V5__`.

The `validate` step is the enforcement. Edit an applied `V__` and the pipeline
stops at dev; test and production are skipped.

### The everyday flow

```
edit sql/R__sp_xxx.sql  →  commit  →  push
        ↓
      dev applies
        ↓
      test applies
        ↓
   production waits for approval  →  approve  →  applies
```

`git log sql/R__sp_xxx.sql` then answers who changed that procedure, when, and
why.

---

## Teardown

```bash
cd terraform
terraform destroy
```

5–10 minutes, mostly RDS. **This is the cost control — there is no
auto-shutdown.** `terraform apply` rebuilds everything in about 12 minutes.

Terraform does not remove:

- [ ] **The runner registration in GitHub.** The instance is deleted; the
      registration survives as an offline runner, and every job matching its
      labels then **queues forever** instead of failing.
      ```bash
      gh api repos/<owner>/<repo>/actions/runners --jq '.runners[] | "\(.id) \(.name) \(.status)"'
      gh api -X DELETE repos/<owner>/<repo>/actions/runners/<id>
      ```
- [ ] **The three Environments and their secrets** — delete each one.
- [ ] **Manual RDS snapshots**, which keep billing.
- [ ] **CloudWatch log groups** under `/aws/rds/` and `/aws/ssm/`.
- [ ] **The GitHub PAT**, if it was not already revoked.
- [ ] **`terraform.tfstate`**, which still holds the generated passwords in
      cleartext.

### Keep the Environments if you plan to rebuild

The three GitHub Environments and their protection rules cost nothing and take
ten minutes of clicking to recreate. Delete them only when the project is
finished for good. Their secrets will be overwritten on the next rebuild
anyway.

The runner registration is the opposite: **delete it every time**. A
registered-but-offline runner makes every job matching its labels queue
forever rather than fail, so the next run hangs with no error to read.

---

## Rebuilding the lab

About 30 minutes, most of it waiting for RDS. Everything in GitHub survives a
teardown; everything in AWS is created fresh, including new IP addresses, a new
RDS endpoint and **new passwords** — `random_password` regenerates on every
apply.

| # | Step | Time |
|---|------|------|
| 1 | New GitHub PAT (classic, `repo` scope, 7 days) into `terraform/terraform.tfvars` | 5 min |
| 2 | `terraform apply` | 12 min |
| 3 | Confirm the runner shows **Idle**, then revoke the PAT | 3 min |
| 4 | Reload all 15 environment secrets | 2 min |
| 5 | Recreate the Flyway user on RDS (step 3.2) | 5 min |
| 6 | Baseline the three databases at version 0 (step 3.5) | 3 min |
| 7 | Trigger the pipeline: Actions → Flyway Migrate → **Run workflow** | — |

Step 4 is not optional and is the one that gets skipped. The old secrets point
at machines that no longer exist:

```bash
cd terraform
terraform output -raw github_secret_commands
```

Step 7 uses `workflow_dispatch`, so the pipeline can be run without pushing a
commit — useful for a rehearsal, and for leaving the environments at a known
state before a demo.

### What survives a teardown, and what does not

| Survives | Is recreated |
|----------|--------------|
| The repository and every migration | The three databases and their data |
| The three Environments and their protection rules | Every password |
| The approval history in Actions | Private IPs and the RDS endpoint |
| Past workflow runs and their logs | `flyway_schema_history` |

### Before a demo

Apply in the morning, run the pipeline once end to end to confirm it is green,
and leave it running. At roughly six cents an hour, the cost of a rehearsed
demo is negligible next to building the lab with an audience watching.
