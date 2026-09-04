# Flyway + GitHub Actions + MySQL — stored procedures under version control

Stored procedures are edited by hand and archived as loose copies in
SharePoint. There is no history, no author or date trail, and a real risk of
applying the wrong copy. This repository is the working answer: migrations live
in git, a pipeline applies them in a fixed order across three environments, and
production waits for a named human to approve.

`sp_get_cliente` and `sp_actualizar_pedido` are stand-ins used to demonstrate
the mechanism. They are not real production procedures.

## Where to start

| You want to | Read |
|-------------|------|
| Build a disposable AWS lab and practise the whole cycle | [`terraform/README.md`](terraform/README.md) |
| Repeat the exact run that was verified, including its corrections | [`docs/lab-walkthrough.md`](docs/lab-walkthrough.md) |
| Adopt this on infrastructure that already exists | [`docs/aws-multi-environment-setup.md`](docs/aws-multi-environment-setup.md) |

## Repository layout

```
sql/                                  Flyway migrations
  V1__baseline_schema.sql             Versioned: clientes/pedidos tables
  V2__create_sp_get_cliente.sql       Versioned: example SP
  V3__add_telefono_clientes.sql       Versioned: adds clientes.telefono
  R__sp_actualizar_pedido.sql         Repeatable: example SP, edited in place
.github/workflows/
  flyway-migrate.yml                  Orchestrator: dev -> test -> production
  flyway-run.yml                      Reusable: one environment per call
terraform/                            Disposable AWS lab (VPC, 2x EC2, RDS, runner)
docs/                                 Adoption runbook and lab walkthrough
flyway.conf.example                   Committed template (placeholder values)
flyway.conf                           Local only, gitignored
scripts/                              Obsolete — see "Retired" below
```

## Versioned vs repeatable

This is the distinction everything else rests on.

**`R__` — repeatable. Stored procedures go here.** One file per procedure,
edited in place as often as needed. Flyway notices the checksum changed and
re-applies it. The prefix is on the *file name*; the procedure keeps its own
name, and callers keep using `CALL sp_actualizar_pedido(...)` unchanged.

MySQL 8 has no `CREATE OR REPLACE PROCEDURE`, so a repeatable migration opens
with `DROP PROCEDURE IF EXISTS`. That is what makes re-running it safe.

**`V__` — versioned. Structural change goes here.** Never edited after they are
applied — an `ALTER TABLE` that already ran cannot run again. The next change is
a new file. The pipeline's `validate` step enforces this: edit an applied `V__`
and the run stops at dev, leaving test and production untouched.

## The pipeline

```
push to main (paths: sql/**)
        ↓
      dev        info → validate → migrate → info
        ↓        needs: dev
      test       info → validate → migrate → info
        ↓        needs: test
   production    waits for a required reviewer
        ↓
              approved → applies
```

Four lines carry the design:

| Line | What it buys |
|------|--------------|
| `runs-on: [self-hosted, linux, vpc-interna]` | GitHub-hosted runners have no route to private databases |
| `environment: ${{ inputs.environment }}` | Scopes the secrets *and* applies the environment's protection rules |
| `needs: test` | Production is unreachable if test failed — the job never starts |
| `FLYWAY_CLEAN_DISABLED: "true"` | `flyway clean` drops every object in the schema. Nothing here needs it |

## Secrets

Five per environment, scoped to `dev`, `test` and `production`. Not repository
secrets — a job declaring `environment: dev` cannot read a secret stored in
`production`, and that is enforced, not encouraged.

| Secret | Value |
|--------|-------|
| `DB_HOST` | Host or RDS endpoint for that environment |
| `DB_PORT` | `3306` |
| `DB_NAME` | Schema Flyway owns |
| `DB_USER` | Least-privilege migration user |
| `DB_PASSWORD` | Its password |

They are consumed as `FLYWAY_URL` / `FLYWAY_USER` / `FLYWAY_PASSWORD`
environment variables — never as CLI flags, never printed.

`terraform output -raw github_secret_commands` prints the exact `gh secret set`
commands, with each password piped straight from Parameter Store so it never
becomes a literal in the shell history.

## Flyway CLI version

Pinned to **10.20.1**, in `.github/workflows/flyway-run.yml` (`FLYWAY_VERSION`).
Install the same version locally for parity.

To bump it: change `FLYWAY_VERSION`, verify against a non-production database
first, then update this section.

## Local setup

```bash
cp flyway.conf.example flyway.conf     # gitignored; fill in real values
flyway -configFiles=flyway.conf info
flyway -configFiles=flyway.conf migrate
```

Re-run `migrate` unchanged to confirm idempotence: nothing to apply, no new
history rows.

## Pre-push secret scan

```bash
git grep -nIE '(ghp_|github_pat_|AKIA[0-9A-Z]{16})' -- .
git check-ignore -v terraform/terraform.tfvars    # must match *.tfvars
git status --short                                # flyway.conf must not appear
```

`terraform.tfvars` holds a GitHub PAT and `terraform.tfstate` holds generated
database passwords in cleartext. A secret pushed to GitHub is compromised even
after deletion — it stays in the history.

## Demo script

1. `git log sql/R__sp_actualizar_pedido.sql` — who changed the procedure, when,
   and why. This is what replaces the SharePoint folder.
2. Edit `sql/R__sp_actualizar_pedido.sql` live, commit, push.
3. Watch the run: dev applies, test applies, production stops at
   **Waiting for approval**.
4. Approve. The run records who approved, when, for which environment, and with
   what comment — permanently.
5. Show `flyway_schema_history`: the repeatable migration has a new row with a
   different checksum; the versioned ones are untouched.
6. Trigger the workflow again with no changes to show idempotence.
7. Edit an already-applied `V__` migration and push. The run fails at dev on a
   checksum mismatch; test and production are skipped. This is the failure that
   currently goes undetected until environments have drifted apart.

## Retired

`scripts/sg-allow-actions.sh` and `scripts/sg-revoke-actions.sh` opened the
database Security Group to GitHub Actions' published IP ranges for the duration
of a demo. They belong to the earlier design, where jobs ran on GitHub-hosted
runners and had to reach the database from the internet.

The self-hosted runner made that unnecessary: it sits inside the VPC, the
database Security Groups allow 3306 from the runner's Security Group ID only,
and nothing is ever opened to the internet. The scripts are kept for reference
and are not part of any current procedure.
