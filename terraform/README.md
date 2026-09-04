# Flyway lab infrastructure

A disposable, self-contained AWS lab that stands up the three-environment
architecture described in [`../docs/aws-multi-environment-setup.md`](../docs/aws-multi-environment-setup.md):
dev and test running MySQL 8.0 on EC2, production on RDS, all reached by a
self-hosted GitHub Actions runner inside the VPC.

The runbook tells you how to adopt this pattern on infrastructure you already
have. This module builds a throwaway copy of it so you can practise the full
promotion cycle without touching anything corporate. Nothing here peers with,
reads from, or writes to an existing VPC.

**It bills by the hour. Destroy it when you are not using it.**

---

## 1. What this creates

```
                        GitHub.com
                            ▲
                            │  outbound HTTPS (443) only
                            │  runner polls for jobs
   ┌────────────────────────┼──────────────────────────────────┐
   │  LAB VPC  10.42.0.0/16 │                                  │
   │                        │                                  │
   │   ┌────────────────────┴───────────────────────────────┐  │
   │   │  public subnets (2 AZs)                            │  │
   │   │                                                    │  │
   │   │   ┌──────────────┐  ┌───────────┐  ┌────────────┐  │  │
   │   │   │ EC2 runner   │  │ EC2 dev   │  │ EC2 test   │  │  │
   │   │   │ AL2023       │  │ Ubuntu    │  │ Ubuntu     │  │  │
   │   │   │ sg-runner    │  │ MySQL 8.0 │  │ MySQL 8.0  │  │  │
   │   │   │ NO ingress   │  │ sg-mysql  │  │ sg-mysql   │  │  │
   │   │   └──────┬───────┘  └─────▲─────┘  └─────▲──────┘  │  │
   │   └──────────┼────────────────┼──────────────┼─────────┘  │
   │              │  3306, by Security Group reference          │
   │              │                                             │
   │   ┌──────────┼─────────────────────────────────────────┐  │
   │   │  private subnets (2 AZs)   │                        │  │
   │   │                            ▼                        │  │
   │   │                   ┌──────────────────┐              │  │
   │   │                   │ RDS MySQL 8.0    │              │  │
   │   │                   │ production       │              │  │
   │   │                   │ sg-rds, private  │              │  │
   │   │                   └──────────────────┘              │  │
   │   └─────────────────────────────────────────────────────┘  │
   └─────────────────────────────────────────────────────────────┘
                            ▲
                            │ SSM Session Manager — no SSH, no port 22
                       Your laptop
```

With `use_nat_gateway = true` the three EC2 instances move into the private
subnets and reach the internet through a NAT Gateway instead. RDS is in the
private subnets either way.

| Resource | Count | Purpose |
|----------|-------|---------|
| `aws_vpc` | 1 | Isolated lab network, `10.42.0.0/16` by default |
| `aws_subnet` public | 2 | Where the EC2 instances live by default, one per AZ |
| `aws_subnet` private | 2 | Always holds RDS; holds the EC2 instances when NAT is enabled |
| `aws_internet_gateway` | 1 | Outbound path for the public subnets |
| `aws_nat_gateway` + `aws_eip` | 0 or 2 | Only when `use_nat_gateway = true` |
| `aws_route_table` + associations | 2 + 4 | Public table has a default route; private table has one only with NAT |
| `aws_security_group` runner | 1 | Zero ingress rules. Egress 443 to the internet, 3306 inside the VPC |
| `aws_security_group` mysql-ec2 | 1 | Ingress 3306 from the runner group only |
| `aws_security_group` rds | 1 | Ingress 3306 from the runner group only, no egress |
| `aws_iam_role` + profile runner | 2 | `AmazonSSMManagedInstanceCore` plus read of this project's SSM parameters |
| `aws_iam_role` + profile mysql | 2 | Same, scoped to dev and test parameters only |
| `aws_instance` runner | 1 | Amazon Linux 2023, registers itself with GitHub at boot |
| `aws_instance` mysql dev / test | 2 | Ubuntu 22.04, MySQL 8.0, schema and Flyway user created at boot |
| `aws_db_instance` | 1 | Production MySQL 8.0, private, encrypted |
| `aws_db_subnet_group` | 1 | Pins RDS to the private subnets |
| `random_password` | 4 | One per environment, plus the RDS master password |
| `aws_ssm_parameter` | 16 | Passwords as `SecureString`, host/port/schema/user as `String` |

Roughly **54 resources** with the default `use_nat_gateway = false`, and 57 with
it enabled.

### Design decisions worth knowing

**Ubuntu 22.04 for the MySQL hosts, not Amazon Linux 2023.** On Jammy,
`apt-get install mysql-server` gives MySQL 8.0 from the base archive with no
third-party repository. Amazon Linux 2023 ships MariaDB, which would mean dev
and test run a different engine from production RDS — and the entire value of
the dev → test → production chain is that the earlier environments predict the
later one.

**No key pair, anywhere.** Access to every instance is AWS Systems Manager
Session Manager. Port 22 is never opened, there is no private key to leak, and
every session is recorded in CloudTrail.

**Subnet placement is a cost decision, not a security one.** With
`use_nat_gateway = false` the instances sit in a public subnet with a public IP
and a Security Group that allows **zero inbound traffic**. Nothing can reach
them; they can still reach out to GitHub and the package mirrors. With
`use_nat_gateway = true` they move to a private subnet and egress through the
NAT Gateway, which is cleaner and costs about 32 USD per month. Both are
defensible; the free one is the default.

**Passwords never appear in Terraform outputs.** They are generated by
`random_password` and written straight to Parameter Store as `SecureString`.
The outputs give you the parameter paths, not the values.

---

## 2. Cost

Prices are on-demand `us-east-1`, rounded, as a planning estimate. Check the
[AWS pricing calculator](https://calculator.aws) for your region.

| Resource | Rate | Monthly (730 h) |
|----------|------|-----------------|
| EC2 runner, `t3.micro` | 0.0104 USD/h | ~7.60 USD |
| EC2 dev MySQL, `t3.micro` | 0.0104 USD/h | ~7.60 USD |
| EC2 test MySQL, `t3.micro` | 0.0104 USD/h | ~7.60 USD |
| EBS gp3, 3 × 20 GB | 0.08 USD/GB-mo | ~4.80 USD |
| RDS `db.t4g.micro` | 0.016 USD/h | ~11.70 USD |
| RDS gp3 storage, 20 GB | 0.115 USD/GB-mo | ~2.30 USD |
| RDS backups, 1 day retention | free up to instance size | ~0.00 USD |
| Data transfer (light lab use) | — | ~1.00 USD |
| **Total, `use_nat_gateway = false`** | | **~42 USD/month** |
| NAT Gateway | 0.045 USD/h + 0.045 USD/GB | ~33 USD |
| **Total, `use_nat_gateway = true`** | | **~75 USD/month** |

Two things this table does not say loudly enough:

- **This bills per hour, not per month.** A lab left running for a weekend costs
  about 3 USD. A lab forgotten for a quarter costs about 125 USD.
- **`terraform destroy` is the cost control.** There is no auto-shutdown here.
  Run it when you finish a session; `terraform apply` rebuilds the whole thing
  in about 12 minutes.

Free Tier accounts absorb much of the EC2 and RDS cost for the first 12 months,
but not the NAT Gateway.

---

## 3. Prerequisites

| Tool | Minimum | Check |
|------|---------|-------|
| Terraform | 1.5.0 | `terraform version` |
| AWS CLI | v2 | `aws --version` |
| Session Manager plugin | any | `session-manager-plugin --version` |
| GitHub CLI | 2.x | `gh --version` |

```bash
aws sts get-caller-identity   # must succeed before anything else
gh auth status                # must show the repo's account
```

If `session-manager-plugin` is missing, install it — without it
`aws ssm start-session` fails and you have no way into the instances.

### GitHub personal access token

The runner exchanges a long-lived token for a short-lived registration token at
boot. Create a **classic** token:

1. GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)
2. **Generate new token (classic)**
3. Scope: **`repo`** only. Nothing else is needed.
4. Expiration: 7 days is plenty — it is used once.
5. Copy the value into `terraform.tfvars` as `github_pat`.

Revoke it as soon as the runner shows **Idle**. Fine-grained tokens need
`Administration: read and write` on the repository; the classic `repo` scope is
simpler and is what this module is tested against.

### IAM permissions for the deploying user

The identity running `terraform apply` needs to create and delete: VPC
networking, EC2 instances, Security Groups, IAM roles and instance profiles, RDS
instances and subnet groups, and SSM parameters. In a personal sandbox account
`AdministratorAccess` is the pragmatic answer. In a shared account, ask for a
policy covering `ec2:*`, `rds:*`, `ssm:*` on `/<project_name>/*`, and
`iam:*Role*` / `iam:*InstanceProfile*` / `iam:PassRole` on
`arn:aws:iam::<account>:role/<project_name>-*`.

---

## 4. Deploy

```bash
cd terraform

cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: github_owner, github_repo, github_pat are required.

terraform init      # downloads providers, writes .terraform.lock.hcl (commit it)
terraform plan      # read this. It should create ~54 resources and destroy 0.
terraform apply     # type: yes
```

Expected duration:

| Phase | Time |
|-------|------|
| VPC, subnets, Security Groups, IAM | < 1 min |
| EC2 instances created | ~1 min |
| RDS instance available | **8–12 min** — this dominates the wall clock |
| Instance bootstrap finishing in the background | ~3 min after the instance exists |

`terraform apply` returns as soon as AWS reports the resources created. The
runner registration and the MySQL setup happen inside the instances afterwards,
so the runner will not appear in GitHub for a couple of minutes after apply
finishes.

Record the outputs:

```bash
terraform output
terraform output -raw ssm_session_command
terraform output -raw github_secret_commands
```

---

## 5. Post-apply: complete the setup

Terraform stops at the AWS boundary. Five things remain.

### 5.1 Confirm the runner registered

Go to **Settings → Actions → Runners** in the repository. The runner named
`<project_name>-runner` should show **Idle** with the labels
`self-hosted, linux, vpc-interna`.

If it does not appear after five minutes, read the bootstrap log:

```bash
aws ssm start-session --target "$(terraform output -raw runner_instance_id)"

# on the instance:
sudo tail -100 /var/log/flyway-runner-bootstrap.log
sudo cat /var/log/cloud-init-output.log | tail -50
sudo systemctl status 'actions.runner.*'
```

The log records every step and never prints the token. The usual failure is
`GitHub returned no registration token`, which means the PAT lacked the `repo`
scope or the owner/repo pair is wrong.

### 5.2 Create the Flyway user on RDS

The dev and test hosts create their own Flyway user at boot because the
bootstrap script runs on the database host. RDS has no host to run anything on,
so this one is manual — once.

Open a shell on the runner:

```bash
aws ssm start-session --target "$(terraform output -raw runner_instance_id)"
```

On the runner:

```bash
PROJECT=flyway-demo          # your project_name
REGION=us-east-1             # your aws_region
SCHEMA=flyway_demo           # your db_schema_name
FLYWAY_USER=flyway_app       # your flyway_db_user
RDS_HOST=<paste rds_endpoint from terraform output>

# Master password and the generated Flyway password, read from Parameter Store.
MASTER_PW="$(aws ssm get-parameter --region "$REGION" \
  --name "/$PROJECT/production/rds_master_password" \
  --with-decryption --query Parameter.Value --output text)"

FLYWAY_PW="$(aws ssm get-parameter --region "$REGION" \
  --name "/$PROJECT/production/db_password" \
  --with-decryption --query Parameter.Value --output text)"

# A mode-600 defaults file, so no password lands in the process list.
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

That grant list is exactly Phase 3 of the runbook: scoped to one schema, no
`GRANT ALL`, no `*.*`, no `SUPER`.

### 5.3 Create the three GitHub Environments

**Settings → Environments → New environment.** Create `dev`, `test` and
`production`. A job declaring `environment: dev` is technically unable to read a
secret scoped to `production` — that is an enforced boundary, not a convention.

Then, from your laptop (not the runner — `gh` is authenticated there):

```bash
terraform output -raw github_secret_commands
```

That prints the exact command list, already filled in with the private IPs, the
RDS endpoint and the Parameter Store paths. Each password is piped straight from
`aws ssm get-parameter` into `gh secret set`, so it never becomes a literal in
your shell history.

To read any single value by hand:

```bash
aws ssm get-parameter --name /flyway-demo/dev/db_password \
  --with-decryption --query Parameter.Value --output text
```

### 5.4 Protect the production environment

In **Settings → Environments → production**:

- Enable **Required reviewers** and name at least one person other than yourself
- Set **Deployment branches** to *Selected branches* → `main`
- Leave **Wait timer** at 0; the reviewer gate is what matters

A production migration now pauses at *Waiting for approval* until a named human
clicks Approve, and that click is recorded permanently.

### 5.5 Baseline all three databases

The dev and test schemas are created empty, and RDS creates `db_name` on its
own, so strictly speaking `migrate` would work without a baseline. Baseline them
anyway: it is the step the runbook exists to teach, and it makes the lab behave
like the real adoption.

**Baseline at version 0, not 1.** `sql/V1__baseline_schema.sql` creates the
`clientes` and `pedidos` tables. Baselining at 1 marks that migration as already
applied, so `migrate` skips it, the tables are never created, and
`V3__add_telefono_clientes.sql` fails with `Table 'clientes' doesn't exist`.
Version 1 is the right baseline only for a database whose objects already exist
— which is the real adoption case this lab imitates, but not the lab itself.

**Extract Flyway under `$HOME`, not `/tmp`.** On Amazon Linux 2023 `/tmp` is a
tmpfs sized from RAM — about 457 MB on a `t3.micro`. The command-line tarball
bundles a full JRE, does not fit, and leaves truncated jars behind with only a
`No space left on device` line buried in the tar output.

From the runner:

```bash
FLYWAY_VERSION=10.20.1
mkdir -p "$HOME/flyway" "$HOME/nosql"
curl -sSL -o "$HOME/flyway.tar.gz" \
  "https://repo1.maven.org/maven2/org/flywaydb/flyway-commandline/${FLYWAY_VERSION}/flyway-commandline-${FLYWAY_VERSION}-linux-x64.tar.gz"
tar -xzf "$HOME/flyway.tar.gz" -C "$HOME/flyway"
export PATH="$HOME/flyway/flyway-${FLYWAY_VERSION}:$PATH"

# baseline writes one history row and reads no migrations, so it needs a
# locations directory but not the repository.
for ENV in dev test production; do
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

---

## 6. Verify it works

**Network reachability, from the runner.** Do not move on until all three
succeed:

```bash
mysql -h "$(aws ssm get-parameter --region "$REGION" --name "/$PROJECT/dev/db_host"        --query Parameter.Value --output text)" -u "$FLYWAY_USER" -p -e "SELECT 1;"
mysql -h "$(aws ssm get-parameter --region "$REGION" --name "/$PROJECT/test/db_host"       --query Parameter.Value --output text)" -u "$FLYWAY_USER" -p -e "SELECT 1;"
mysql -h "$(aws ssm get-parameter --region "$REGION" --name "/$PROJECT/production/db_host" --query Parameter.Value --output text)" -u "$FLYWAY_USER" -p -e "SELECT 1;"
```

A hang means a Security Group is blocking you. `Access denied for user` means
the network is fine and only the credentials are wrong — that is progress.

**Flyway state:**

```bash
flyway -url="jdbc:mysql://$HOST:3306/$SCHEMA" -user="$FLYWAY_USER" -password="$PW" \
       -locations=filesystem:sql -cleanDisabled=true info
```

Expected after baseline, before the first migrate:

| Category | Version | Description | State |
|----------|---------|-------------|-------|
| Versioned | 1 | Existing schema before Flyway adoption | `Baseline` |
| Versioned | 2 | create sp get cliente | `Pending` |
| Versioned | 3 | add telefono clientes | `Pending` |
| Repeatable | | sp actualizar pedido | `Pending` |

**End to end:** push a change under `sql/` on `main` and watch the workflow pick
up the `[self-hosted, linux, vpc-interna]` runner in the Actions tab.

---

## 7. Destroy

```bash
cd terraform
terraform destroy    # type: yes
```

Expect 5–10 minutes, most of it waiting for RDS. This removes every resource in
the table in section 1, including the generated passwords in Parameter Store and
the RDS instance with no final snapshot.

### What Terraform does NOT remove

Work through this list every time, in order:

- [ ] **The runner registration in GitHub.** Terraform deletes the instance; the
      registration survives as an offline runner. **A registered-but-offline
      runner makes every job matching its labels queue forever** rather than
      fail — the workflow simply hangs.

      ```bash
      gh api repos/<owner>/<repo>/actions/runners --jq '.runners[] | "\(.id) \(.name) \(.status)"'
      gh api -X DELETE repos/<owner>/<repo>/actions/runners/<id>
      ```

      UI path: Settings → Actions → Runners → ⋯ → Remove runner.

- [ ] **The GitHub Environments and their secrets.** `dev`, `test` and
      `production` and everything in them stay until deleted:
      Settings → Environments → *(each one)* → Delete environment.

- [ ] **Manual RDS snapshots.** Automated backups go with the instance; anything
      you created with `create-db-snapshot` does not, and it keeps billing.

      ```bash
      aws rds describe-db-snapshots --snapshot-type manual \
        --query 'DBSnapshots[].DBSnapshotIdentifier' --output table
      aws rds delete-db-snapshot --db-snapshot-identifier <id>
      ```

- [ ] **CloudWatch log groups.** RDS and SSM may leave `/aws/rds/...` and
      `/aws/ssm/...` groups behind. Storage is cheap but not free.

      ```bash
      aws logs describe-log-groups --query 'logGroups[].logGroupName' --output table
      aws logs delete-log-group --log-group-name <name>
      ```

- [ ] **The GitHub PAT.** Revoke it if you have not already.

- [ ] **Local state.** `terraform.tfstate` still contains the generated
      passwords in cleartext. Delete it once the lab is gone.

---

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Runner never appears in GitHub | PAT missing the `repo` scope, wrong `github_owner`/`github_repo`, or no outbound 443 | `sudo tail -100 /var/log/flyway-runner-bootstrap.log` on the runner. The log names which of the three it was |
| Runner appears then goes **Offline** | The service stopped, or the instance was replaced by `user_data_replace_on_change` | `sudo systemctl status 'actions.runner.*'` and `sudo journalctl -u 'actions.runner.*' -n 100` |
| Jobs queue forever, never start | No online runner matches the labels — usually a stale registration from a destroyed lab | Delete the offline runner (section 7), confirm `runner_labels` still contains `vpc-interna` |
| `terraform destroy` hangs on the VPC or subnet | An ENI left behind by RDS while the instance is still deleting | Wait 10 minutes and re-run `terraform destroy`. If it persists: `aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=<vpc-id>` and delete any `available` ENI |
| MySQL EC2 unreachable from the runner | Bootstrap still running, or it failed | `aws ssm start-session --target <mysql-instance-id>`, then `sudo tail -100 /var/log/flyway-mysql-bootstrap.log` |
| MySQL EC2 not listed in Session Manager | The SSM agent snap did not start | Check `snap services amazon-ssm-agent`; without NAT, confirm the instance really has a public IP |
| `Communications link failure` | MySQL bound to loopback | `grep bind-address /etc/mysql/mysql.conf.d/mysqld.cnf` should read `0.0.0.0`; then `sudo systemctl restart mysql` |
| `Access denied for user` | Network is fine, credentials are not | Re-read the password from Parameter Store. If a GitHub secret was set from a stale value, set it again |
| Connection times out, no error | Security Group | The database group must allow 3306 from the **runner Security Group ID**, not from a CIDR |
| `Table 'x' already exists` on first migrate | Baseline was skipped | Run `flyway baseline` (section 5.5) |
| `Table 'clientes' doesn't exist` on V3 | Baselined at version 1, so `V1` — which creates the tables — was skipped | Baseline at version 0 (section 5.5). On an already-baselined empty schema, `flyway repair` then a fresh baseline |
| `No space left on device` while extracting Flyway | `/tmp` is a ~457 MB tmpfs on `t3.micro` | Extract under `$HOME`; the root volume has ~17 GB free |
| `Validate failed: Detected resolved migration not applied` | `validate` counts pending migrations as failures | Pass `-ignoreMigrationPatterns='*:pending'`, which keeps the checksum check |
| Runner Idle but jobs still run in GitHub's cloud | The workflow says `runs-on: ubuntu-latest` | Use `runs-on: [self-hosted, linux, vpc-interna]` |
| `Error: creating IAM Role: EntityAlreadyExists` | A previous destroy failed partway | Delete the leftover role or change `project_name` |

---

## 9. This is a lab, not production

Every setting below is deliberately unsafe here because the whole environment is
meant to be deleted. None of them should survive into a real deployment.

| Setting here | Why it is safe in a lab | What production needs |
|--------------|-------------------------|-----------------------|
| `skip_final_snapshot = true` | There is nothing worth keeping | `false`. The final snapshot is the last copy that exists after a deletion |
| `deletion_protection = false` | Destroying is the point | `true`. It is the guard against a `destroy` aimed at the wrong workspace |
| `backup_retention_period = 1` | One day of history is more than enough | 7 days minimum, matched to the recovery window the business will accept |
| `multi_az = false` | An AZ outage costs a re-apply | `true` wherever an AZ outage is not an acceptable outage |
| `apply_immediately = true` | No traffic to disturb | `false`, so changes land in the maintenance window |
| EC2 in public subnets (default) | Zero-ingress Security Groups, no service listening publicly | Private subnets behind NAT or VPC endpoints. Set `use_nat_gateway = true` |
| Local Terraform state | One operator, one machine | S3 backend with DynamoDB locking and encryption. See the commented block in `versions.tf` |
| Passwords generated by `random_password` | They live in Parameter Store and die with the lab | Secrets Manager with rotation, or an external secret store |
| PAT baked into `user_data` | Short-lived, revoked after registration | A GitHub App, or a runner registered from a bastion by hand |
| Single runner, no autoscaling | One job at a time is fine | An autoscaling runner group, so one stuck job does not block the queue |
| `db.t4g.micro`, 20 GB | Nothing is stored | Sized against real data volume and IOPS requirements |
| Flyway user granted `DROP` | Migrations need it | Still needed, but paired with backups, approval gates and `-cleanDisabled=true` |

The runbook in [`../docs/aws-multi-environment-setup.md`](../docs/aws-multi-environment-setup.md)
is the version to follow for real infrastructure. This module is how you learn
it first.
