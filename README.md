# Flyway + GitHub Actions + MySQL — stored procedures bajo control de versiones

Hoy los stored procedures se editan a mano y se archivan como copias sueltas en
SharePoint. No hay historial, no hay rastro de autor ni de fecha, y existe un
riesgo real de aplicar la copia equivocada. Este repositorio es la respuesta
concreta: las migraciones viven en git, un pipeline las aplica en un orden fijo
sobre tres ambientes, y producción espera la aprobación de una persona
designada.

`sp_get_cliente` y `sp_actualizar_pedido` son ejemplos usados para demostrar el
mecanismo. No son procedures reales de producción.

## Por dónde empezar

| Si querés | Leé |
|-----------|-----|
| Saber cómo trabaja el equipo día a día — ramas, PRs, checks | [`docs/flujo-de-trabajo.md`](docs/flujo-de-trabajo.md) |
| Ver ejemplos resueltos de los siete tipos de cambio más comunes | [`docs/ejemplos-de-cambios.md`](docs/ejemplos-de-cambios.md) |
| Levantar un lab desechable en AWS y practicar el ciclo completo | [`terraform/README.md`](terraform/README.md) |
| Repetir exactamente la corrida que se verificó, con sus correcciones | [`docs/lab-walkthrough.md`](docs/lab-walkthrough.md) |
| Adoptar esto sobre infraestructura que ya existe | [`docs/aws-multi-environment-setup.md`](docs/aws-multi-environment-setup.md) |

## Estructura del repositorio

```
sql/                                  Migraciones de Flyway
  V1__baseline_schema.sql             Versionada: tablas clientes/pedidos
  V2__create_sp_get_cliente.sql       Versionada: SP de ejemplo
  V3__add_telefono_clientes.sql       Versionada: agrega clientes.telefono
  R__sp_actualizar_pedido.sql         Repetible: SP de ejemplo, se edita en el mismo archivo
.github/workflows/
  pr-check.yml                        En cada PR: inmutabilidad + migrate desde cero
  flyway-migrate.yml                  Orquestador: dev -> test -> production
  flyway-run.yml                      Reutilizable: un ambiente por invocación
terraform/                            Lab desechable en AWS (VPC, 2x EC2, RDS, runner)
docs/                                 Runbook de adopción y walkthrough del lab
flyway.conf.example                   Plantilla versionada (valores de ejemplo)
flyway.conf                           Solo local, ignorado por git
scripts/                              Obsoleto — ver "Retirado" más abajo
```

## Versionadas vs. repetibles

Esta es la distinción sobre la que se apoya todo lo demás.

**`R__` — repetible. Acá van los stored procedures.** Un archivo por procedure,
editado en el mismo lugar tantas veces como haga falta. Flyway detecta que el
checksum cambió y lo vuelve a aplicar. El prefijo va en el *nombre del archivo*;
el procedure conserva su propio nombre, y quien lo consume sigue usando
`CALL sp_actualizar_pedido(...)` sin cambios.

MySQL 8 no tiene `CREATE OR REPLACE PROCEDURE`, así que una migración repetible
empieza con `DROP PROCEDURE IF EXISTS`. Eso es lo que hace que volver a
ejecutarla sea seguro.

**`V__` — versionada. Acá van los cambios estructurales.** Nunca se editan
después de aplicadas: un `ALTER TABLE` que ya corrió no puede volver a correr.
El siguiente cambio es un archivo nuevo. El paso `validate` del pipeline lo
impone: si editás una `V__` ya aplicada, la corrida se detiene en dev y deja
test y producción intactos.

## El pipeline

Nada llega a `main` sin verificar. Cada pull request que toca `sql/` ejecuta dos
jobs en runners de GitHub — no interviene ninguna base de datos real, así que
los PRs validan en paralelo:

| Check | Qué detecta |
|-------|-------------|
| `Applied migrations are not edited` | Una `V__` modificada, renombrada o borrada. Su checksum ya quedó registrado en todos los ambientes que la aplicaron, así que editarla hace que el archivo deje de coincidir con la base |
| `Migrations run from an empty schema` | Errores de sintaxis, orden roto y migraciones que no son idempotentes — se verifica contra un MySQL descartable y luego se vuelve a correr para probar que la segunda pasada no aplica nada |

Un ruleset sobre `main` exige que ambos pasen, de modo que una migración rota no
se puede mergear. Ver [`docs/flujo-de-trabajo.md`](docs/flujo-de-trabajo.md)
para el modelo de ramas completo y la configuración del ruleset.

Una vez mergeado:

```
push a main (paths: sql/**)
        ↓
      dev        info → validate → migrate → info
        ↓        needs: dev
      test       info → validate → migrate → info
        ↓        needs: test
   production    espera a un reviewer requerido
        ↓
              aprobado → aplica
```

Cuatro líneas sostienen el diseño:

| Línea | Qué aporta |
|-------|------------|
| `runs-on: [self-hosted, linux, vpc-interna]` | Los runners de GitHub no tienen ruta hacia bases de datos privadas |
| `environment: ${{ inputs.environment }}` | Delimita los secrets *y* aplica las reglas de protección del ambiente |
| `needs: test` | Producción es inalcanzable si test falló — el job ni siquiera arranca |
| `FLYWAY_CLEAN_DISABLED: "true"` | `flyway clean` borra todos los objetos del esquema. Acá nada lo necesita |

## Secrets

Cinco por ambiente, delimitados a `dev`, `test` y `production`. No son secrets
de repositorio: un job que declara `environment: dev` no puede leer un secret
guardado en `production`, y eso está impuesto por la plataforma, no sugerido.

| Secret | Valor |
|--------|-------|
| `DB_HOST` | Host o endpoint de RDS de ese ambiente |
| `DB_PORT` | `3306` |
| `DB_NAME` | Esquema que administra Flyway |
| `DB_USER` | Usuario de migración con privilegios mínimos |
| `DB_PASSWORD` | Su contraseña |

Se consumen como variables de entorno `FLYWAY_URL` / `FLYWAY_USER` /
`FLYWAY_PASSWORD` — nunca como flags de CLI, nunca impresas.

`terraform output -raw github_secret_commands` imprime los comandos
`gh secret set` exactos, con cada contraseña canalizada directamente desde
Parameter Store para que nunca quede como literal en el historial de la shell.

## Versión del CLI de Flyway

Fijada en **10.20.1**, en `.github/workflows/flyway-run.yml` (`FLYWAY_VERSION`).
Instalá la misma versión en local para tener paridad.

Para subirla: cambiá `FLYWAY_VERSION`, verificá primero contra una base que no
sea de producción, y después actualizá esta sección.

## Configuración local

```bash
cp flyway.conf.example flyway.conf     # ignorado por git; completá con valores reales
flyway -configFiles=flyway.conf info
flyway -configFiles=flyway.conf migrate
```

Volvé a correr `migrate` sin cambios para confirmar la idempotencia: nada por
aplicar, ninguna fila nueva en el historial.

## Escaneo de secretos antes de un push

```bash
git grep -nIE '(ghp_|github_pat_|AKIA[0-9A-Z]{16})' -- .
git check-ignore -v terraform/terraform.tfvars    # debe coincidir con *.tfvars
git status --short                                # flyway.conf no debe aparecer
```

`terraform.tfvars` contiene un PAT de GitHub y `terraform.tfstate` contiene en
texto plano las contraseñas generadas para las bases. Un secreto pusheado a
GitHub queda comprometido incluso después de borrarlo: permanece en el
historial.

## Guion de la demo

1. `git log sql/R__sp_actualizar_pedido.sql` — quién cambió el procedure, cuándo
   y por qué. Esto es lo que reemplaza a la carpeta de SharePoint.
2. Editar `sql/R__sp_actualizar_pedido.sql` en vivo, commitear, pushear.
3. Mirar la corrida: dev aplica, test aplica, producción se detiene en
   **Waiting for approval**.
4. Aprobar. La corrida registra quién aprobó, cuándo, para qué ambiente y con
   qué comentario — de forma permanente.
5. Mostrar `flyway_schema_history`: la migración repetible tiene una fila nueva
   con un checksum distinto; las versionadas quedaron intactas.
6. Disparar el workflow de nuevo sin cambios para mostrar la idempotencia.
7. Editar una migración `V__` ya aplicada y pushear. La corrida falla en dev por
   checksum mismatch; test y producción se saltean. Este es justamente el fallo
   que hoy pasa desapercibido hasta que los ambientes ya divergieron.

## Retirado

`scripts/sg-allow-actions.sh` y `scripts/sg-revoke-actions.sh` abrían el
Security Group de la base a los rangos de IP publicados por GitHub Actions
durante una demo. Pertenecen al diseño anterior, donde los jobs corrían en
runners de GitHub y tenían que llegar a la base desde internet.

El runner self-hosted volvió eso innecesario: vive dentro de la VPC, los
Security Groups de las bases permiten el 3306 únicamente desde el Security Group
ID del runner, y nunca se abre nada a internet. Los scripts se conservan como
referencia y no forman parte de ningún procedimiento vigente.
