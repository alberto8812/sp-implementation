# Flyway + GitHub Actions + Aurora MySQL (RDS) — Demo

This repository demonstrates a Flyway-based SQL migration pipeline running
against a dedicated **non-production/test** Aurora MySQL (RDS) instance,
triggered by GitHub Actions. Stored procedures (`sp_get_cliente`,
`sp_actualizar_pedido`) are example/stand-in objects used only to show the
versioned-vs-repeatable migration mechanism — they are not real production
SPs.

## Repository layout

```
sql/                                  Flyway migrations
  V1__baseline_schema.sql             Versioned: clientes/pedidos tables
  V2__create_sp_get_cliente.sql       Versioned: example SP (never edit after apply)
  R__sp_actualizar_pedido.sql         Repeatable: example SP (live-demo edit target)
flyway.conf.example                   Committed template (placeholder values)
flyway.conf                           Local only, gitignored — fill in real test-RDS values
.github/workflows/flyway-migrate.yml  CI: info -> migrate -> info
scripts/sg-allow-actions.sh           Operator script: open RDS SG to GitHub Actions IPs
scripts/sg-revoke-actions.sh          Operator script: close-out counterpart
```

## 1. Local setup

1. Copy the template and fill in real values for your dedicated test RDS instance:
   ```
   cp flyway.conf.example flyway.conf
   ```
   Edit `flyway.conf` — `flyway.url`, `flyway.user`, `flyway.password`.
   `flyway.conf` is gitignored; never commit it with real credentials.

2. Install the Flyway CLI locally (same version pinned in CI — see below).

3. Validate and inspect before touching CI:
   ```
   flyway -configFiles=flyway.conf validate
   flyway -configFiles=flyway.conf info
   ```

4. Run the migration against the test RDS instance:
   ```
   flyway -configFiles=flyway.conf migrate
   ```
   Confirm `flyway_schema_history` shows `V1`, `V2`, and `R__...` each applied
   once.

5. Idempotence check — re-run unchanged:
   ```
   flyway -configFiles=flyway.conf migrate
   ```
   Expect "no migrations to apply", no new history rows.

6. Live-edit rehearsal — append `, actualizado_en = NOW()` to the `UPDATE`
   statement in `sql/R__sp_actualizar_pedido.sql`, then re-run `migrate`.
   Confirm the repeatable SP re-applies and a new `R__` row with a different
   checksum appears in `flyway_schema_history`. Revert the edit (or commit it
   deliberately) before proceeding.

## 2. Flyway CLI version

Pinned version: **10.20.1** (Flyway 10.x stable line), referenced both in
`.github/workflows/flyway-migrate.yml` (`FLYWAY_VERSION` env var) and as the
version you should install locally for parity.

To bump it later: update `FLYWAY_VERSION` in the workflow file to a newer
released Flyway 10.x/11.x version, re-validate locally against the test RDS
instance first, then update this section.

## 3. GitHub repository secrets (manual, one-time)

In the GitHub repo: **Settings → Secrets and variables → Actions → New
repository secret**. Add all five:

| Secret | Value |
|---|---|
| `RDS_HOST` | Test Aurora MySQL (RDS) endpoint hostname |
| `RDS_PORT` | Usually `3306` |
| `RDS_DB` | Target schema/database name |
| `RDS_USER` | DB user with migration privileges on the test schema |
| `RDS_PASSWORD` | DB user password |

These are consumed by `.github/workflows/flyway-migrate.yml` as
`FLYWAY_URL` / `FLYWAY_USER` / `FLYWAY_PASSWORD` environment variables —
never as CLI flags, never printed in logs.

**Verify**: once all five secrets are set, trigger the workflow manually via
**Actions → Flyway Migrate → Run workflow** (`workflow_dispatch`) and confirm
a green run before relying on push-triggered runs.

## 4. Security Group IP-range restriction (demo-window only)

The RDS Security Group's inbound rule on port 3306 must be scoped to GitHub
Actions' published IP ranges — never `0.0.0.0/0`. This is handled by two
operator-run scripts (not invoked by CI, so AWS credentials never touch
GitHub):

```
export SG_ID=sg-xxxxxxxxxxxxxxxxx
export PREFIX_LIST_NAME=github-actions-demo

# Right before the live demo push:
./scripts/sg-allow-actions.sh

# ... run the demo ...

# Immediately after:
./scripts/sg-revoke-actions.sh
```

`sg-allow-actions.sh` fetches `https://api.github.com/meta`, filters to
IPv4 entries, validates each against a strict CIDR regex, loads them into an
AWS managed prefix list, and adds one ingress rule referencing that prefix
list. It prints the validated entry count and **aborts non-zero, applying
nothing**, if any entry is malformed or if the count would exceed a safe
threshold (default 55, under AWS's default 60-rule-per-Security-Group
quota — override with `MAX_SG_RULE_ENTRIES` only after you've deliberately
resolved the quota, e.g. via an AWS increase or a curated subset).

`sg-revoke-actions.sh` removes the ingress rule and deletes the prefix list.

Requires the `aws` CLI configured with credentials/region, plus `curl` and
`jq`.

## 5. Pre-push secret scan

Before the first push, confirm no plaintext RDS credentials ever entered
git history:

```
git log -p | grep -iE 'RDS_PASSWORD|password' || echo "No matches found"
git status   # flyway.conf must NOT appear as tracked/staged
```

## 6. Live demo script

1. Show `git log` — clean history, `.gitignore` committed from the start,
   no credentials ever present.
2. Run `scripts/sg-allow-actions.sh` to open the temporary SG rule scoped to
   GitHub Actions IP ranges.
3. Edit `sql/R__sp_actualizar_pedido.sql` live (append
   `, actualizado_en = NOW()` to the `UPDATE`).
4. Commit and push to `main`.
5. Watch the `Flyway Migrate` Action run: `info` (before) → `migrate` →
   `info` (after).
6. Show `flyway_schema_history` — the repeatable SP has a new row with an
   updated checksum; the versioned migrations (`V1`, `V2`) are untouched.
7. Trigger the workflow a second time (`workflow_dispatch`, no changes) to
   show idempotence — `migrate` reports nothing to apply, no new history
   rows.
8. Close out: run `scripts/sg-revoke-actions.sh`, confirm the ingress rule
   and prefix list are gone, and rotate `RDS_PASSWORD` in GitHub Secrets.

## Non-goals

Production hardening, self-hosted runners, multi-environment targets,
automated secret rotation, and Docker-based Flyway execution are out of
scope for this demo.
