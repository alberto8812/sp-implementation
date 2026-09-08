# Ciclo del lab: destruir y volver a levantar

Este documento cubre un solo escenario: ya tuviste el lab funcionando, lo diste
de baja con `terraform destroy`, y ahora querés volver a tenerlo operativo.

Es un procedimiento distinto del primer despliegue. El `README.md` de
`terraform/` explica cómo se construye el lab desde cero y por qué cada pieza
está donde está. Esto es la versión corta y repetible, con los valores reales
del proyecto ya puestos.

## Por qué existe este documento

Terraform es dueño de AWS. No es dueño de GitHub.

Todo lo que vive del lado de GitHub —los secrets de los environments, la
registración del runner, las reglas de protección— **sobrevive intacto a un
`terraform destroy`**. El siguiente `apply` levanta infraestructura nueva:
contraseñas nuevas generadas por `random_password`, un endpoint de RDS nuevo,
una instancia de runner nueva. GitHub no se entera de nada de eso y no tiene
forma de enterarse.

El resultado es un repositorio que *parece* configurado y apunta a una
infraestructura que ya no existe.

De las cuatro tareas manuales que quedan después de cada `apply`, tres fallan
en silencio si te las salteás. Esa es la razón de la lista de verificación.

---

## Valores del proyecto

| Concepto | Valor |
|----------|-------|
| Repositorio | `alberto8812/sp-implementation` |
| Región | `us-east-1` |
| `project_name` | `flyway-demo` |
| Schema | `flyway_demo` |
| Usuario de Flyway | `flyway_app` |
| Usuario maestro de RDS | `flyway_admin` |
| Labels del runner | `self-hosted, linux, vpc-interna` |

Las IPs privadas de dev y test se han mantenido estables entre despliegues
(`10.42.4.20` y `10.42.19.21`), porque el CIDR de la VPC y el orden de las
subnets no cambian. **El endpoint del RDS sí cambia en cada `apply`.** No lo
copies de una sesión anterior: leelo siempre de `terraform output`.

---

## Parte 1 — Dar de baja el lab

### 1.1 Destruir la infraestructura

```bash
cd terraform
terraform destroy
```

Tarda entre cinco y diez minutos, y casi todo ese tiempo es el RDS borrándose.

### 1.2 Borrar la registración del runner

**Este paso no es opcional.** Es el único de toda la limpieza que, si lo
omitís, rompe el lab siguiente.

```bash
gh api repos/alberto8812/sp-implementation/actions/runners \
  --jq '.runners[] | "\(.id)  \(.name)  \(.status)"'

gh api -X DELETE repos/alberto8812/sp-implementation/actions/runners/<id>
```

Terraform borra la instancia EC2, pero la registración queda viva en GitHub con
estado `offline`. Un runner registrado pero offline no hace que los jobs
fallen: hace que **queden encolados indefinidamente**. GitHub ve un runner con
las labels correctas, le asigna el trabajo y espera. El workflow se queda en
*Queued* sin un solo mensaje de error.

Es el fallo más caro del lab justamente porque no se parece a un fallo.

### 1.3 Limpieza de costos

Nada de esto rompe el lab siguiente, pero todo sigue facturando.

```bash
# Snapshots manuales de RDS. Los automáticos se van con la instancia; estos no.
aws rds describe-db-snapshots --snapshot-type manual --region us-east-1 \
  --query 'DBSnapshots[].DBSnapshotIdentifier' --output table
aws rds delete-db-snapshot --db-snapshot-identifier <id>

# Log groups huérfanos de RDS y SSM.
aws logs describe-log-groups --region us-east-1 \
  --query 'logGroups[?starts_with(logGroupName, `/aws/rds`) || starts_with(logGroupName, `/aws/ssm`)].logGroupName' \
  --output table
aws logs delete-log-group --log-group-name <nombre>
```

Revocá también el PAT de GitHub. Vas a necesitar uno nuevo para el próximo
`apply` de todas formas.

### 1.4 Lo que NO hay que tocar

Los tres environments (`dev`, `test`, `production`) y sus reglas de protección
—revisores requeridos, `production` restringido a la rama `main`— sobreviven al
`destroy`, y eso juega a favor: es configuración que no hay que rehacer.

Los quince secrets también sobreviven, pero esos sí quedan inservibles. Se
recargan en el paso 2.4.

---

## Parte 2 — Volver a levantar el lab

Cuatro pasos manuales después del `apply`. El orden importa: cada uno depende
del anterior.

### 2.0 PAT nuevo y `terraform apply`

Creá un personal access token **classic** con scope `repo` únicamente
(GitHub → Settings → Developer settings → Personal access tokens → Tokens
classic). Una semana de expiración sobra: se usa una sola vez, en el arranque
del runner.

Copialo en `terraform/terraform.tfvars` como `github_pat`, y desplegá:

```bash
cd terraform
terraform apply
```

Unos doce minutos, dominados por el RDS.

> `terraform apply` devuelve el control apenas AWS reporta los recursos
> creados. El registro del runner y la instalación de MySQL siguen ocurriendo
> dentro de las instancias durante dos o tres minutos más.

**Verificación.** Antes de seguir, confirmá que el `apply` terminó completo:

```bash
terraform output
```

Tienen que aparecer `rds_endpoint`, `rds_port` y `github_secret_commands`. Si
esos tres faltan, el RDS no se creó y los outputs que dependen de él no se
pudieron resolver. Volvé a correr `terraform apply` y leé el error.

### 2.1 Confirmar el runner

En el navegador: **Settings → Actions → Runners**. Tiene que aparecer
`flyway-demo-runner` en **Idle**, con las labels `self-hosted, linux,
vpc-interna`.

Por línea de comandos:

```bash
gh api repos/alberto8812/sp-implementation/actions/runners \
  --jq '.runners[] | "\(.id)  \(.name)  \(.status)"'
```

**Tiene que haber exactamente uno, en `online`.** Si aparece más de uno, quedó
una registración vieja del paso 1.2 sin borrar.

Si no aparece ninguno después de cinco minutos:

```bash
aws ssm start-session --target "$(terraform output -raw runner_instance_id)" --region us-east-1
# dentro de la instancia:
sudo tail -100 /var/log/flyway-runner-bootstrap.log
```

El log nombra cuál de las tres causas habituales fue: el PAT sin scope `repo`,
el par `github_owner`/`github_repo` equivocado, o la instancia sin salida a
internet por el 443. Nunca imprime el token.

### 2.2 Crear el usuario de Flyway en el RDS

Los hosts de dev y test crean su propio usuario durante el arranque, porque el
script de bootstrap corre en la misma máquina que la base. RDS no tiene una
máquina donde correr nada. Por eso este paso es manual, y por eso es el único.

```bash
aws ssm start-session --target "$(terraform output -raw runner_instance_id)" --region us-east-1
```

Ya dentro del runner:

```bash
PROJECT=flyway-demo
REGION=us-east-1
SCHEMA=flyway_demo
FLYWAY_USER=flyway_app
RDS_HOST=<pegar el valor de: terraform output -raw rds_endpoint>

MASTER_PW="$(aws ssm get-parameter --region "$REGION" \
  --name "/$PROJECT/production/rds_master_password" \
  --with-decryption --query Parameter.Value --output text)"

FLYWAY_PW="$(aws ssm get-parameter --region "$REGION" \
  --name "/$PROJECT/production/db_password" \
  --with-decryption --query Parameter.Value --output text)"

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

Dos decisiones deliberadas en ese bloque:

- **El archivo `.rds.cnf` en modo 600.** Si la contraseña se pasa como
  `-p$PASSWORD`, queda visible en la lista de procesos para cualquiera que
  ejecute `ps` en esa máquina. El archivo temporal evita eso, y `shred` lo
  elimina después.
- **El `GRANT` acotado a un solo schema.** Sin `GRANT ALL`, sin `*.*`, sin
  `SUPER`. Es el permiso mínimo con el que Flyway funciona de verdad.

**Verificación.** Sin salir del runner, comprobá los tres ambientes:

```bash
for ENV in dev test production; do
  H="$(aws ssm get-parameter --region "$REGION" --name "/$PROJECT/$ENV/db_host" --query Parameter.Value --output text)"
  P="$(aws ssm get-parameter --region "$REGION" --name "/$PROJECT/$ENV/db_password" --with-decryption --query Parameter.Value --output text)"
  echo -n "$ENV: "
  mysql -h "$H" -u "$FLYWAY_USER" -p"$P" -e "SELECT 1;" >/dev/null 2>&1 && echo OK || echo FALLA
done
```

Tres `OK` y seguís.

Si alguno **cuelga** en lugar de fallar, es un Security Group. Si dice `Access
denied for user`, la red está bien y solo fallan las credenciales — eso es
progreso, no un problema.

### 2.3 Los environments

Si los conservaste del lab anterior, saltá al paso 2.4.

Si los borraste: **Settings → Environments → New environment**, tres veces,
con los nombres exactos `dev`, `test` y `production` en minúscula.
`flyway-migrate.yml` los referencia literalmente.

Después, la protección de producción — **Settings → Environments → production**:

- **Required reviewers**: al menos una persona
- **Deployment branches and tags**: *Selected branches* → `main`
- **Wait timer**: 0

Los dos primeros importan por razones distintas. Los revisores requeridos son
el freno humano: la migración se detiene en *Waiting for approval* y queda
registrado quién aprobó y cuándo. La restricción de ramas impide que alguien
dispare producción desde una rama cualquiera; sin eso, el revisor termina
aprobando un despliegue que ni siquiera está en `main`.

El temporizador no protege nada. Un reloj no revisa código.

### 2.4 Recargar los quince secrets

Desde tu máquina, no desde el runner: `gh` está autenticado localmente.

```bash
cd terraform
terraform output -raw github_secret_commands | bash
```

**El `| bash` no es opcional.** Sin él, el comando solo *imprime* la lista y no
ejecuta nada, y el resultado es indistinguible de no haber hecho nada.

Cada contraseña viaja desde Parameter Store hasta `gh secret set` por una
tubería, así que nunca se materializa como texto en la terminal ni queda en el
historial del shell.

**Verificación:**

```bash
for e in dev test production; do echo "== $e"; gh secret list --env $e; done
```

Los quince tienen que decir **`less than a minute ago`**.

Mirá la columna `UPDATED`, no la lista de nombres. Los secrets viejos también
están presentes y con el nombre correcto: lo único que los delata es la fecha.
Una comprobación que solo confirma que algo existe no es una comprobación.

> `gh secret set` no imprime nada cuando tiene éxito. El silencio del `| bash`
> es buena señal, no ausencia de trabajo. La confirmación real es la fecha.

### 2.5 Baseline de las tres bases

De vuelta en el runner:

```bash
PROJECT=flyway-demo
REGION=us-east-1
SCHEMA=flyway_demo
FLYWAY_USER=flyway_app
FLYWAY_VERSION=10.20.1

mkdir -p "$HOME/flyway" "$HOME/nosql"
curl -sSL -o "$HOME/flyway.tar.gz" \
  "https://repo1.maven.org/maven2/org/flywaydb/flyway-commandline/${FLYWAY_VERSION}/flyway-commandline-${FLYWAY_VERSION}-linux-x64.tar.gz"
tar -xzf "$HOME/flyway.tar.gz" -C "$HOME/flyway"
export PATH="$HOME/flyway/flyway-${FLYWAY_VERSION}:$PATH"

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

Esperá `Successfully baselined schema with version: 0` tres veces.

**`-baselineVersion=0`, no 1.** `sql/V1__baseline_schema.sql` es la migración
que crea las tablas `clientes` y `pedidos`. Al hacer baseline en la versión 1,
Flyway la marca como ya aplicada y la saltea: las tablas nunca se crean y
`V3__add_telefono_clientes.sql` falla con `Table 'clientes' doesn't exist`.

La versión 1 sería la correcta para una base que **ya contiene** esos objetos
—el caso de adopción real que este lab imita—, pero el lab arranca vacío.

**Extraer bajo `$HOME`, no bajo `/tmp`.** En una instancia `t3.micro`, `/tmp`
es un `tmpfs` dimensionado desde la RAM: unos 457 MB. El tarball incluye un JRE
completo, no entra, y `tar` deja archivos `.jar` truncados con un
`No space left on device` enterrado en su salida. El síntoma posterior parece
un problema de Flyway y es un problema de disco.

**Verificación.** No te quedes con el mensaje de Flyway; leé la tabla:

```bash
for ENV in dev test production; do
  echo "=== $ENV"
  HOST="$(aws ssm get-parameter --region "$REGION" --name "/$PROJECT/$ENV/db_host" --query Parameter.Value --output text)"
  PW="$(aws ssm get-parameter --region "$REGION" --name "/$PROJECT/$ENV/db_password" --with-decryption --query Parameter.Value --output text)"
  mysql -h "$HOST" -u "$FLYWAY_USER" -p"$PW" "$SCHEMA" -e \
    "SELECT installed_rank, version, description, type, success FROM flyway_schema_history ORDER BY installed_rank;"
done
```

Los tres tienen que devolver exactamente una fila:

| installed_rank | version | description | type | success |
|---|---|---|---|---|
| 1 | 0 | Before Flyway adoption | BASELINE | 1 |

---

## Lista de verificación final

Los cinco puntos, en orden. Si alguno falla, no sigas: los que vienen después
dependen de él.

- [ ] `terraform output` muestra `rds_endpoint`, `rds_port` y `github_secret_commands`
- [ ] `gh api .../actions/runners` devuelve **exactamente un** runner en `online`
- [ ] Los tres `mysql ... SELECT 1` responden `OK` desde el runner
- [ ] Los quince secrets dicen `less than a minute ago`
- [ ] Las tres bases devuelven una fila `BASELINE`, versión `0`

---

## Diagnóstico de fallos

| Síntoma | Causa | Solución |
|---------|-------|----------|
| Los jobs quedan en `Queued` para siempre, sin error | Un runner registrado en `offline` de un lab anterior coincide con las labels | Borrarlo: paso 1.2. Confirmar que queda uno solo en `online` |
| `Communications link failure` en producción | `DB_HOST` apunta al endpoint del RDS anterior | Recargar los secrets con la tubería a `bash`: paso 2.4 |
| `Access denied for user` | La contraseña del secret es la que generó un `apply` anterior | Ídem: paso 2.4 |
| Faltan `rds_endpoint` y `github_secret_commands` en los outputs | El RDS no llegó a crearse; los outputs que dependen de él no se resuelven | Volver a correr `terraform apply` y leer el error |
| El runner nunca aparece en GitHub | PAT sin scope `repo`, `github_owner`/`github_repo` mal, o sin salida al 443 | `sudo tail -100 /var/log/flyway-runner-bootstrap.log` en el runner |
| `Table 'clientes' doesn't exist` en la V3 | Baseline hecho en la versión 1, que saltea la V1 creadora de las tablas | Baseline en la versión 0: paso 2.5 |
| `No space left on device` al extraer Flyway | `/tmp` es un tmpfs de ~457 MB en `t3.micro` | Extraer bajo `$HOME` |
| Un `mysql` cuelga en lugar de dar error | Security Group | El grupo de la base debe permitir 3306 desde el **ID del Security Group del runner**, no desde un CIDR |
| Los jobs corren en la nube de GitHub, no en el runner | El workflow dice `runs-on: ubuntu-latest` | Usar `runs-on: [self-hosted, linux, vpc-interna]` |

---

## Documentos relacionados

- [`../terraform/README.md`](../terraform/README.md) — el módulo completo: qué
  construye, cuánto cuesta, y qué decisiones son deliberadamente inseguras
  porque esto es un laboratorio
- [`aws-multi-environment-setup.md`](aws-multi-environment-setup.md) — el
  runbook para adoptar este patrón sobre infraestructura real
- [`flujo-de-trabajo.md`](flujo-de-trabajo.md) — el modelo de ramas y el gate
  de pull request
