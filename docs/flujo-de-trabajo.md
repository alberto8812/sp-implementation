# Flujo de trabajo del equipo

Cómo se trabaja con las migraciones: qué rama, qué revisa la máquina, qué revisa
una persona, y en qué orden llega el cambio a cada ambiente.

Este documento es la convención del equipo. Lo que describe no depende de que
alguien se acuerde: está hecho cumplir por reglas configuradas en GitHub.

---

## El ciclo completo

```
1. rama corta desde main
2. el desarrollador edita el SQL y lo prueba en su MySQL local
3. abre un Pull Request
        ↓
   🤖 dos checks automáticos
        ❌ rojo  →  el botón de Merge queda deshabilitado
        ✅ verde →  se habilita
        ↓
4. review humano del SQL
5. merge a main
        ↓
6. dev aplica          (automático)
7. test aplica         (automático, solo si dev pasó)
8. producción espera aprobación de una persona
```

Tres puertas antes de que un cambio quede en producción: la máquina verifica que
el SQL funciona, una persona verifica que hace lo correcto, y una segunda
persona autoriza el despliegue final.

---

## Ramas

### Una sola rama larga: `main`

Los ambientes **no son ramas**. Son etapas de promoción del mismo commit.

El commit que se aplicó en dev es exactamente el mismo que llega a test y el
mismo que llega a producción. Bit por bit. Por eso lo que pasa en test predice
lo que va a pasar en producción — si dev fuera una rama distinta, tendría código
que producción no tiene y dejaría de predecir nada.

### Una rama corta por cambio

Nace de `main`, vive uno o dos días, entra por PR, y se borra.

**No una rama por sprint.** Una rama de sprint junta quince cambios y los suelta
todos juntos al final: cuando algo falla hay que averiguar cuál de los quince
fue, y los conflictos se acumulan dos semanas antes de resolverse.

Nombre sugerido: `feature/`, `fix/` o `chore/` más una descripción corta.

```
feature/sp-devolucion-pedidos
fix/validacion-estado-invalido
```

### Por qué NO una rama por ambiente

Es lo que casi todos los equipos intentan primero, y con migraciones de base de
datos se rompe.

Los números de versión de Flyway son una **secuencia global de la base de
datos**, no de la rama:

```
rama-A  →  crea V4__add_columna_telefono.sql
rama-B  →  crea V4__create_tabla_facturas.sql
```

Git no ve conflicto: son archivos con nombres distintos. Pero cuando las dos
llegan a la misma base:

```
ERROR: Found more than one migration with version 4
```

Y si `dev` tiene migraciones que `test` todavía no tiene, y alguien crea otra
versión desde `test`, quedan dos ambientes con historiales incompatibles. Ese
problema no se arregla con git — se arregla a mano en la base.

**Una rama da versiones paralelas del código. La base de datos no tiene
versiones paralelas.** Hay un solo `flyway_schema_history` por ambiente, y una
sola línea de tiempo.

---

## Numeración de las migraciones versionadas

Para que dos personas no elijan el mismo número, las migraciones `V__` nuevas se
nombran con **fecha y hora**, no con un correlativo:

```
V20260904_1030__add_columna_telefono.sql
V20260904_1145__create_tabla_facturas.sql
```

Dos personas no generan el mismo timestamp al minuto, así que la colisión
desaparece por construcción. De paso, el nombre dice cuándo se creó la
migración.

Convive sin problema con los correlativos que ya existen: Flyway ordena
numéricamente, y `20260904...` es mayor que `3`.

La alternativa —coordinar los números en un canal de chat— funciona con tres
personas. Con ocho, no.

---

## Dos personas tocando el mismo procedure

Es un archivo de texto en git. Dos personas lo editan en ramas distintas y git
frena con un **conflicto de merge**.

| | Copias sueltas en una carpeta compartida | Con git |
|---|---|---|
| A guarda su versión | ✅ | ✅ |
| B guarda encima | ✅ **pisa a A, en silencio** | ❌ **conflicto, se frena** |
| Alguien se entera | cuando algo falla en producción | en el momento del merge |

El conflicto no es el problema: es la solución. Es la herramienta avisando que
dos personas cambiaron lo mismo. Y como se resuelve dentro del PR, el resultado
queda revisado antes de tocar ninguna base.

La forma de tener pocos conflictos es tener ramas cortas. Una rama de dos días
casi nunca choca; una de dos semanas choca siempre.

---

## Los dos checks automáticos

Definidos en `.github/workflows/pr-check.yml`. Corren en runners de GitHub, no
en el self-hosted: no tocan ninguna base real, así que diez PRs se validan en
paralelo sin pelearse por un runner ni depender de AWS.

### 1. `Applied migrations are not edited`

Falla si el PR **modifica, renombra o borra** un archivo `sql/V*`. Agregar uno
nuevo es normal y no falla.

Cuando falla, el mensaje dice qué hacer:

```
A versioned migration was modified, renamed or deleted:
sql/V3__add_telefono_clientes.sql

Versioned migrations are immutable. Their checksum is recorded in every
environment that already applied them, so editing one makes the file
disagree with the database.

Add a new migration instead, for example:
  sql/V20260904_1328__describe_the_change.sql
```

**Este es el check más valioso de los dos**, y el menos obvio. El SQL editado
suele ser perfectamente válido — el problema no es el SQL, es que ese archivo ya
se aplicó en los tres ambientes y ahora dice algo distinto de lo que hay en las
bases. No lo detecta un linter, ni un test, ni una revisión humana apurada: el
diff se ve razonable.

### 2. `Migrations run from an empty schema`

Levanta un MySQL 8 descartable —un contenedor que vive solo mientras dura el
job, se destruye al terminar, no está en AWS y no cuesta nada— y corre **todas
las migraciones desde una base vacía**, en orden.

Después corre `migrate` una segunda vez y exige que no aplique nada. Una
migración que se aplica dos veces no es idempotente y provocaría diferencias
entre ambientes.

Detecta:

| | |
|---|---|
| Errores de sintaxis SQL | Un `DELIMITER` mal puesto, una coma de más |
| Migraciones que no corren desde cero | Un `V__` que asume una tabla que nadie creó |
| Orden roto | Un procedure que consulta una tabla creada en un `V__` posterior |
| Falta de idempotencia | Un `R__` sin su `DROP ... IF EXISTS` |

Probar **desde una base vacía** es lo que hace valioso este check. Las bases de
dev y test ya tienen todo aplicado, así que ahí esos errores no aparecen —
aparecen el día que alguien monta un ambiente nuevo.

---

## Las reglas en GitHub

Un workflow que falla no sirve de nada si igual se puede mergear. La regla que
lo ata está en **Settings → Rules → Rulesets**, sobre `main`:

| Regla | Valor | Qué evita |
|-------|-------|-----------|
| Target branches | rama por defecto (`main`) | Sin esto el ruleset no aplica a nada |
| Bypass list | **vacía** | Que alguien —incluido el dueño del repo— se saltee la regla |
| Restrict deletions | ☑ | Que se borre `main` |
| Require a pull request before merging | ☑ | Push directo a `main` |
| Required approvals | **1** en equipo, 0 trabajando solo | Que un cambio entre sin que nadie lo lea |
| Require status checks to pass | ☑ con los dos checks | Mergear con los checks en rojo |
| Block force pushes | ☑ | Que se reescriba la historia |

Los checks se agregan por su **nombre exacto**:

```
Applied migrations are not edited
Migrations run from an empty schema
```

Un check requerido cuyo nombre no coincide con ninguno real queda esperando para
siempre y bloquea todos los PRs sin dar explicación. Conviene seleccionarlos de
la lista que ofrece GitHub —aparecen después de que el workflow corrió una
vez— en vez de escribirlos a mano.

---

## Reglas para el equipo

1. **`main` es la única rama larga.** Los ambientes son etapas, no ramas.
2. **Una rama por cambio**, de uno o dos días. Nunca por sprint.
3. **Todo entra por PR.** No hay push directo a `main`.
4. **Las `V__` se nombran con timestamp**, nunca con correlativo.
5. **Las `R__` se editan libremente.** Un conflicto se resuelve en el PR, como
   cualquier otro archivo.
6. **Nadie toca una base a mano.** Si un cambio no está en `sql/`, no existe.

La sexta es la que cuesta y la que sostiene a las otras cinco. El día que
alguien arregla algo directamente en una base, `flyway_schema_history` deja de
reflejar la realidad y se pierde la garantía de que los ambientes son
comparables.

---

## Dónde queda registrado cada cambio

- **En git** — quién cambió qué, cuándo, y por qué en el mensaje del commit.
  `git log sql/R__sp_actualizar_pedido.sql` cuenta la historia completa de ese
  procedure.
- **En el Pull Request** — la discusión, la revisión y el resultado de los dos
  checks.
- **En cada base de datos** — la tabla `flyway_schema_history`, con una fila por
  cada aplicación, su checksum y su fecha.
- **En GitHub Actions** — quién aprobó cada despliegue a producción, cuándo y
  con qué comentario.
