#!/usr/bin/env bash
#
# post-apply.sh
#
# Operator-run script (NOT invoked by CI). Completes the four manual steps that
# remain after every `terraform apply` of the lab in `terraform/`, and verifies
# each one before moving to the next:
#
#   1. Confirm exactly one self-hosted runner is registered and online
#   2. Create the Flyway user on the production RDS instance
#   3. Reload the fifteen GitHub environment secrets from the current state
#   4. Baseline all three databases at version 0
#
# Terraform owns AWS, not GitHub. Environment secrets, the runner registration
# and the protection rules all survive `terraform destroy`, so after a rebuild
# they point at infrastructure that no longer exists. Three of the four steps
# above fail silently when skipped — hence the verification after each one.
#
# Steps 2 and 4 run inside the runner through `aws ssm send-command`, so no
# interactive Session Manager shell is needed. Passwords are read from Parameter
# Store on the instance and are never printed or passed on a command line.
#
# Requirements: terraform, aws CLI (v2, configured), gh (authenticated), python3.
#
# Usage:
#   scripts/post-apply.sh              # run every step
#   scripts/post-apply.sh --check      # verify only, change nothing
#
# Exit codes: non-zero on the first step that fails verification. The script
# stops there rather than continuing on top of a broken prerequisite.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"

CHECK_ONLY=false
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=true

# --- output helpers -------------------------------------------------------

step()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()    { printf '   \033[32mOK\033[0m    %s\n' "$*"; }
fail()  { printf '   \033[31mFALLA\033[0m %s\n' "$*" >&2; }
info()  { printf '         %s\n' "$*"; }

die() { fail "$*"; exit 1; }

# --- prerequisites --------------------------------------------------------

for bin in terraform aws gh python3; do
  command -v "$bin" >/dev/null 2>&1 || die "falta el binario: $bin"
done

[[ -d "$TF_DIR" ]] || die "no existe $TF_DIR"

aws sts get-caller-identity >/dev/null 2>&1 \
  || die "las credenciales de AWS no responden (aws sts get-caller-identity)"
gh auth status >/dev/null 2>&1 \
  || die "gh no esta autenticado (gh auth status)"

# --- read the Terraform state --------------------------------------------

step "0. Leyendo los outputs de Terraform"

cd "$TF_DIR"

tf_out() { terraform output -raw "$1" 2>/dev/null || true; }

RUNNER_ID="$(tf_out runner_instance_id)"
RDS_HOST="$(tf_out rds_endpoint)"
SECRET_CMDS="$(tf_out github_secret_commands)"

# The three RDS-dependent outputs are the tell: when the RDS instance failed to
# create, Terraform cannot resolve them and they come back empty.
[[ -n "$RUNNER_ID" ]] || die "runner_instance_id vacio: el apply no dejo un runner"
[[ -n "$RDS_HOST"  ]] || die "rds_endpoint vacio: el RDS no se creo. Volve a correr 'terraform apply' y lee el error"
[[ -n "$SECRET_CMDS" ]] || die "github_secret_commands vacio: el apply quedo incompleto"

# Terraform is the source of truth for these; nothing is hardcoded here.
REGION="$(python3 -c "import json,sys;d=json.load(sys.stdin);print(d['ssm_session_command']['value'].split('--region ')[1].strip())" < <(terraform output -json))"
PROJECT="$(python3 -c "import json,sys;d=json.load(sys.stdin);print(d['ssm_password_paths']['value']['dev'].split('/')[1])" < <(terraform output -json))"

ok "runner   $RUNNER_ID"
ok "rds      $RDS_HOST"
ok "region   $REGION"
ok "project  $PROJECT"

GH_REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
ok "repo     $GH_REPO"

# Values that must match terraform.tfvars.
SCHEMA="$(grep -E '^\s*db_schema_name' terraform.tfvars | cut -d'"' -f2)"
FLYWAY_USER="$(grep -E '^\s*flyway_db_user' terraform.tfvars | cut -d'"' -f2)"
MASTER_USER="$(grep -E '^\s*db_master_username' terraform.tfvars | cut -d'"' -f2)"
: "${SCHEMA:?no se pudo leer db_schema_name de terraform.tfvars}"
: "${FLYWAY_USER:?no se pudo leer flyway_db_user de terraform.tfvars}"
: "${MASTER_USER:?no se pudo leer db_master_username de terraform.tfvars}"

FLYWAY_VERSION=10.20.1

# --- run a script on the runner through SSM -------------------------------
#
# Sends a shell script to the runner and blocks until it finishes, then prints
# its stdout. The script text never reaches a command line, so nothing it
# contains is visible in the instance's process list.

ssm_run() {
  local label="$1" script="$2" timeout="${3:-600}"
  local tmp cid status

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  printf '%s' "$script" > "$tmp/script.sh"
  python3 -c "
import json,sys
json.dump({'commands': open(sys.argv[1]).read().split('\n')}, open(sys.argv[2],'w'))
" "$tmp/script.sh" "$tmp/params.json"

  cid="$(aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$RUNNER_ID" \
    --document-name AWS-RunShellScript \
    --comment "$label" \
    --timeout-seconds "$timeout" \
    --parameters "file://$tmp/params.json" \
    --query Command.CommandId --output text)"

  local waited=0
  while true; do
    status="$(aws ssm get-command-invocation --region "$REGION" \
      --command-id "$cid" --instance-id "$RUNNER_ID" \
      --query Status --output text 2>/dev/null || echo Pending)"
    [[ "$status" != "Pending" && "$status" != "InProgress" ]] && break
    (( waited += 5 ))
    (( waited > timeout )) && die "$label: se agoto el tiempo de espera"
    sleep 5
  done

  aws ssm get-command-invocation --region "$REGION" \
    --command-id "$cid" --instance-id "$RUNNER_ID" \
    --query StandardOutputContent --output text

  if [[ "$status" != "Success" ]]; then
    aws ssm get-command-invocation --region "$REGION" \
      --command-id "$cid" --instance-id "$RUNNER_ID" \
      --query StandardErrorContent --output text >&2
    die "$label: el comando remoto termino en $status"
  fi
}

# --- 1. runner registration ----------------------------------------------

step "1. Runner autoalojado"

RUNNERS="$(gh api "repos/$GH_REPO/actions/runners" \
  --jq '.runners[] | "\(.id)\t\(.name)\t\(.status)"')"

if [[ -z "$RUNNERS" ]]; then
  fail "no hay ningun runner registrado"
  info "el arranque tarda 2-3 min despues del apply. Si no aparece:"
  info "  aws ssm start-session --target $RUNNER_ID --region $REGION"
  info "  sudo tail -100 /var/log/flyway-runner-bootstrap.log"
  exit 1
fi

printf '%s\n' "$RUNNERS" | while IFS=$'\t' read -r id name status; do
  info "$id  $name  $status"
done

ONLINE="$(printf '%s\n' "$RUNNERS" | grep -c 'online$' || true)"
TOTAL="$(printf '%s\n' "$RUNNERS" | wc -l | tr -d ' ')"

# A registered-but-offline runner does not make jobs fail. It makes them queue
# forever: GitHub matches the labels, assigns the job and waits.
if [[ "$TOTAL" -gt 1 ]]; then
  fail "hay $TOTAL runners registrados. Los offline sobraron de un lab anterior"
  info "borralos: gh api -X DELETE repos/$GH_REPO/actions/runners/<id>"
  info "un runner offline con estas labels encola los jobs para siempre, sin error"
  exit 1
fi
[[ "$ONLINE" -eq 1 ]] || die "el runner esta registrado pero no esta online"

ok "un runner, online"

# --- 2. Flyway user on RDS ------------------------------------------------

step "2. Usuario $FLYWAY_USER en el RDS"

if $CHECK_ONLY; then
  info "--check: se omite la creacion"
else
  # dev and test create this user in their own bootstrap, because that script
  # runs on the database host. RDS has no host to run anything on.
  ssm_run "crear $FLYWAY_USER en RDS" "
set -eu
export HOME=/root
MASTER_PW=\"\$(aws ssm get-parameter --region '$REGION' --name '/$PROJECT/production/rds_master_password' --with-decryption --query Parameter.Value --output text)\"
FLYWAY_PW=\"\$(aws ssm get-parameter --region '$REGION' --name '/$PROJECT/production/db_password' --with-decryption --query Parameter.Value --output text)\"

# Mode-600 defaults file: passing -p\$PASSWORD would expose it in the process list.
umask 077
cat > \"\$HOME/.rds.cnf\" <<EOF
[client]
host=$RDS_HOST
user=$MASTER_USER
password=\$MASTER_PW
EOF

mysql --defaults-extra-file=\"\$HOME/.rds.cnf\" <<SQL
CREATE USER IF NOT EXISTS '$FLYWAY_USER'@'%' IDENTIFIED BY '\$FLYWAY_PW';
ALTER USER '$FLYWAY_USER'@'%' IDENTIFIED BY '\$FLYWAY_PW';

GRANT SELECT, INSERT, UPDATE, DELETE,
      CREATE, ALTER, DROP, INDEX, REFERENCES,
      CREATE ROUTINE, ALTER ROUTINE, EXECUTE,
      CREATE VIEW, SHOW VIEW, TRIGGER
  ON \\\`$SCHEMA\\\`.* TO '$FLYWAY_USER'@'%';

FLUSH PRIVILEGES;
SQL

shred -u \"\$HOME/.rds.cnf\"
echo 'usuario creado'
" 300 | sed 's/^/         /'
fi

# Verification: reachability plus credentials, on all three environments.
CONN="$(ssm_run "verificar conectividad" "
set -u
for ENV in dev test production; do
  H=\"\$(aws ssm get-parameter --region '$REGION' --name \"/$PROJECT/\$ENV/db_host\" --query Parameter.Value --output text)\"
  P=\"\$(aws ssm get-parameter --region '$REGION' --name \"/$PROJECT/\$ENV/db_password\" --with-decryption --query Parameter.Value --output text)\"
  if mysql -h \"\$H\" -u '$FLYWAY_USER' -p\"\$P\" -e 'SELECT 1;' >/dev/null 2>&1; then
    echo \"\$ENV OK\"
  else
    echo \"\$ENV FALLA\"
  fi
done
" 180)"

printf '%s\n' "$CONN" | while read -r env res; do
  [[ -z "$env" ]] && continue
  [[ "$res" == "OK" ]] && ok "$env responde" || fail "$env no responde"
done

if printf '%s' "$CONN" | grep -q FALLA; then
  info "si el comando cuelga en vez de fallar, es un Security Group"
  info "si dice 'Access denied', la red esta bien y solo fallan las credenciales"
  exit 1
fi

# --- 3. GitHub environment secrets ---------------------------------------

step "3. Secrets de los tres environments"

if $CHECK_ONLY; then
  info "--check: no se recargan"
else
  # Each password is piped straight from Parameter Store into `gh secret set`,
  # so it never becomes a literal in the shell history.
  printf '%s' "$SECRET_CMDS" | bash
fi

MISSING=0
for env in dev test production; do
  COUNT="$(gh secret list --env "$env" --json name --jq 'length' 2>/dev/null || echo 0)"
  if [[ "$COUNT" -ne 5 ]]; then
    fail "$env tiene $COUNT secrets, se esperaban 5"
    MISSING=1
  else
    ok "$env: 5 secrets"
  fi
done
[[ "$MISSING" -eq 0 ]] || die "faltan secrets. Revisa que los tres environments existan en Settings -> Environments"

if ! $CHECK_ONLY; then
  info "confirma las fechas con: gh secret list --env production"
  info "los quince deben decir 'less than a minute ago'"
fi

# --- 4. Baseline ----------------------------------------------------------

step "4. Baseline de las tres bases"

if $CHECK_ONLY; then
  info "--check: no se ejecuta baseline"
else
  # Baseline at version 0, not 1. V1__baseline_schema.sql is the migration that
  # creates `clientes` and `pedidos`; baselining at 1 marks it as applied, so
  # migrate skips it and V3 fails with "Table 'clientes' doesn't exist".
  #
  # Extract under $HOME, not /tmp: on a t3.micro /tmp is a ~457 MB tmpfs sized
  # from RAM, the tarball bundles a full JRE, and tar leaves truncated jars
  # behind with only a "No space left on device" buried in its output.
  ssm_run "baseline" "
set -eu
export HOME=/root
export PATH=\"\$HOME/flyway/flyway-$FLYWAY_VERSION:\$PATH\"
mkdir -p \"\$HOME/flyway\" \"\$HOME/nosql\"

if [ ! -x \"\$HOME/flyway/flyway-$FLYWAY_VERSION/flyway\" ]; then
  curl -sSL -o \"\$HOME/flyway.tar.gz\" \\
    'https://repo1.maven.org/maven2/org/flywaydb/flyway-commandline/$FLYWAY_VERSION/flyway-commandline-$FLYWAY_VERSION-linux-x64.tar.gz'
  tar -xzf \"\$HOME/flyway.tar.gz\" -C \"\$HOME/flyway\"
fi

for ENV in dev test production; do
  H=\"\$(aws ssm get-parameter --region '$REGION' --name \"/$PROJECT/\$ENV/db_host\" --query Parameter.Value --output text)\"
  P=\"\$(aws ssm get-parameter --region '$REGION' --name \"/$PROJECT/\$ENV/db_password\" --with-decryption --query Parameter.Value --output text)\"
  flyway -url=\"jdbc:mysql://\$H:3306/$SCHEMA\" \\
         -user='$FLYWAY_USER' -password=\"\$P\" \\
         -locations=filesystem:\"\$HOME/nosql\" \\
         -cleanDisabled=true \\
         -baselineVersion=0 \\
         -baselineDescription='Before Flyway adoption' \\
         baseline 2>&1 | grep -Ei 'baselined|ERROR|already' || true
done
" 600 | sed 's/^/         /'
fi

# Verification: read the history table, not Flyway's own message.
HIST="$(ssm_run "verificar baseline" "
set -u
for ENV in dev test production; do
  H=\"\$(aws ssm get-parameter --region '$REGION' --name \"/$PROJECT/\$ENV/db_host\" --query Parameter.Value --output text)\"
  P=\"\$(aws ssm get-parameter --region '$REGION' --name \"/$PROJECT/\$ENV/db_password\" --with-decryption --query Parameter.Value --output text)\"
  V=\"\$(mysql -N -B -h \"\$H\" -u '$FLYWAY_USER' -p\"\$P\" '$SCHEMA' -e \\
    \"SELECT CONCAT(version,'/',type) FROM flyway_schema_history WHERE installed_rank=1;\" 2>/dev/null)\"
  echo \"\$ENV \${V:-SIN_HISTORIAL}\"
done
" 180)"

printf '%s\n' "$HIST" | while read -r env val; do
  [[ -z "$env" ]] && continue
  [[ "$val" == "0/BASELINE" ]] && ok "$env: baseline version 0" || fail "$env: $val"
done
if printf '%s\n' "$HIST" | grep -qE 'SIN_HISTORIAL|1/BASELINE'; then
  fail "alguna base no quedo con baseline en la version 0"
  info "baseline en 1 saltea V1__baseline_schema.sql y V3 falla con \"Table 'clientes' doesn't exist\""
  exit 1
fi

# --- done -----------------------------------------------------------------

if $CHECK_ONLY; then
  step "Verificacion completa"
  info "no se modifico nada. Los cuatro puntos estan en orden"
else
  step "Listo"
  info "runner online, usuario en RDS, 15 secrets recargados, 3 baselines en version 0"
  info "prueba end-to-end: pushea un cambio bajo sql/ a main y segui el workflow"
fi
