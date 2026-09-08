# Dos bugs en producción, y cómo se corrigen

Guion de presentación. La pregunta que responden los dos escenarios es la misma:

> **Hay un error en la base. ¿Qué archivo toco?**

Y la respuesta depende de una sola cosa: si el objeto roto **se reemplaza entero**
o si el cambio **ya quedó grabado en la base**. Los dos casos se ven parecidos
desde afuera y se corrigen de forma opuesta.

---

## Bug 1 — El procedure dice que sí y no hizo nada

**Tipo:** bug de lógica en un objeto reemplazable (`R__`).
**Corrección:** se edita el archivo que ya existe.

### Cómo aparece

Soporte abre un ticket: un operador marcó como `enviado` el pedido 8842. La
pantalla mostró la confirmación. Tres días después el pedido seguía en
`pendiente`.

No hay error en ningún log. La aplicación llamó al procedure, el procedure no
falló, y la aplicación mostró éxito.

### Dónde está el bug

En `sql/R__sp_actualizar_pedido.sql`:

```sql
SELECT estado INTO v_estado_actual FROM pedidos WHERE id = p_pedido_id;

IF v_estado_actual = 'entregado' AND p_estado = 'cancelado' THEN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'No se puede cancelar un pedido ya entregado';
END IF;

UPDATE pedidos
SET estado = p_estado
WHERE id = p_pedido_id;
```

El pedido 8842 no existe — el operador se equivocó en un dígito. Entonces:

1. El `SELECT ... INTO` no encuentra fila. `v_estado_actual` queda en `NULL`.
2. Las comparaciones contra `NULL` no dan verdadero, así que ninguna validación
   dispara.
3. El `UPDATE` no encuentra fila y afecta **cero filas**. Eso no es un error en
   MySQL: es un `UPDATE` perfectamente exitoso que no cambió nada.
4. El procedure termina limpio. La aplicación no tiene forma de saber que no pasó
   nada.

El bug no es una excepción tragada. Es una operación que **nunca informa que no
se aplicó**.

### Cómo se reproduce antes de tocar nada

Contra la base local:

```sql
CALL sp_actualizar_pedido(99999, 'enviado');
-- Query OK, 0 rows affected
```

Cero error. Ese "Query OK" es el bug entero.

### La corrección

`R__` significa repetible: el objeto se borra y se vuelve a crear en cada
corrida. Así que se edita **el mismo archivo de siempre**, `R__sp_actualizar_pedido.sql`.
No se crea ningún archivo nuevo.

```sql
SELECT estado INTO v_estado_actual FROM pedidos WHERE id = p_pedido_id;

IF v_estado_actual IS NULL THEN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'El pedido no existe';
END IF;

IF v_estado_actual = 'entregado' AND p_estado = 'cancelado' THEN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'No se puede cancelar un pedido ya entregado';
END IF;
```

### El ciclo completo

```
git switch -c fix/pedido-inexistente main
# editar sql/R__sp_actualizar_pedido.sql
git commit -m "fix: rechazar la actualización de un pedido que no existe"
# Pull Request → dos checks en verde → review → merge
```

El pipeline detecta el checksum nuevo, vuelve a ejecutar el archivo en dev,
después en test, y espera aprobación humana para producción. En
`flyway_schema_history` aparece una fila nueva del mismo `R__`, con su checksum y
su fecha; las filas anteriores quedan como estaban.

### A destacar

Este bug se corrige rápido y **sin dejar deuda**, porque un stored procedure no
tiene estado propio. Borrarlo y recrearlo no pierde nada. Por eso los `R__` se
editan siempre en el mismo archivo, y por eso `git log` de ese archivo cuenta la
historia completa del procedure:

```bash
git log --oneline sql/R__sp_actualizar_pedido.sql
```

Eso —quién lo cambió, cuándo, y por qué— es exactamente lo que hoy no existe con
las copias sueltas en SharePoint.

---

## Bug 2 — La columna quedó chica y ya está en producción

**Tipo:** error estructural en una migración versionada ya aplicada.
**Corrección:** un archivo nuevo. El original no se toca.

### Cómo aparece

Se agregó el monto total a los pedidos hace tres semanas:

```sql
-- sql/V4__add_total_pedidos.sql   (YA APLICADO en dev, test y producción)
ALTER TABLE pedidos
    ADD COLUMN total DECIMAL(5,2) NOT NULL DEFAULT 0.00;
```

`DECIMAL(5,2)` son cinco dígitos en total, dos de ellos decimales. El máximo que
entra es **999.99**.

Funcionó tres semanas porque los pedidos de prueba eran chicos. Hoy entró un
pedido de 1.250,00 y la aplicación devuelve:

```
Error Code: 1264
Out of range value for column 'total' at row 1
```

Producción rechaza el pedido. El cliente no puede comprar.

### El reflejo que hay que frenar

El instinto de quien viene de editar archivos sueltos es abrir
`V4__add_total_pedidos.sql`, cambiar `DECIMAL(5,2)` por `DECIMAL(12,2)`, y
pushear. Es el arreglo de una línea. Y está mal.

El Pull Request se pone rojo antes de llegar a `main`:

```
A versioned migration was modified, renamed or deleted:
sql/V4__add_total_pedidos.sql

Add a new migration instead, for example:
  sql/V20260908_1642__describe_the_change.sql
```

Y el ruleset de `main` exige ese check, así que **el botón de Merge queda
deshabilitado**.

El detalle que conviene mostrar en la presentación: el otro check,
`Migrations run from an empty schema`, sale **verde**. El SQL editado es
impecable y corre sin problemas desde una base vacía. El problema nunca fue el
SQL.

### Por qué está mal

`V4__` ya se ejecutó en los tres ambientes. El `ALTER TABLE` de hace tres semanas
ya corrió y no se va a volver a ejecutar nunca. Editar el archivo no cambia ni
una columna: lo único que cambia es que el archivo **empieza a mentir** sobre lo
que hay en la base.

Y Flyway lo detecta, porque guarda el checksum de lo que aplicó:

```
ERROR: Validate failed: Migrations have failed validation
Migration checksum mismatch for migration version 4
-> Applied to database : 1147538214
-> Resolved locally    : -862033109
```

Dev se detiene. `test` y `production` quedan en `skipped`. Ninguna base se tocó.

### La corrección

Un archivo nuevo, con el número siguiente al último que exista:

```sql
-- sql/V5__widen_total_pedidos.sql
ALTER TABLE pedidos
    MODIFY COLUMN total DECIMAL(12,2) NOT NULL DEFAULT 0.00;
```

`MODIFY COLUMN` ensancha la columna sin tocar los datos que ya están: los montos
guardados hasta hoy entran de sobra en el tipo nuevo. Es una operación segura y
no requiere ventana de mantenimiento en una tabla de este tamaño.

`V4__` queda como está, para siempre, contando que en su momento la columna se
creó como `DECIMAL(5,2)`. Eso no es un archivo con un error: es el registro fiel
de lo que se hizo. `V5__` cuenta que después se corrigió, quién lo hizo y cuándo.

### "¿Y si necesito volver atrás?"

Flyway Community no tiene `undo`. Se avanza hacia adelante, siempre.

Y para una base de producción eso es lo correcto, no una limitación. Deshacer un
`ALTER TABLE` que ya corrió no es reversible en general: si el cambio borró datos,
no hay rollback que los devuelva. La corrección de un error en la base **siempre**
es una migración nueva. Flyway hace explícita una regla que ya era cierta.

Si el error fuera al revés —achicar una columna que sí tiene datos que no entran—
la migración correcta necesita dos pasos y una decisión de negocio: qué hacer con
las filas que no entran. Eso ya no es un `fix`, es un cambio con diseño propio.

### A destacar — la parte que se sostiene sola

El equipo va a cometer este error igual. La diferencia no es que Flyway lo evite:
es **dónde se entera**.

| Hoy, sin Flyway | Con el pipeline |
|-----------------|-----------------|
| Alguien edita el script y lo reaplica en un ambiente | El check de PR bloquea el merge |
| Otro ambiente queda sin el cambio | Ninguna base se toca |
| Los ambientes divergen en silencio | El error se ve en el Pull Request |
| Se descubre cuando algo falla en producción | Se descubre antes de tocar la primera base |

---

## Resumen

| | Bug 1 | Bug 2 |
|---|-------|-------|
| **Qué se rompió** | Lógica de un procedure | Tipo de una columna |
| **Tipo de objeto** | Reemplazable | Acumulativo |
| **Archivo** | El mismo `R__` de siempre | Un `V__` **nuevo** |
| **¿Se edita el original?** | Sí, siempre | **Nunca** |
| **Por qué** | El procedure se borra y se recrea entero | El `ALTER` ya corrió; el archivo es historia |
| **Si se hace mal** | — | Checksum mismatch, pipeline detenido |

### La regla, en una línea

> **Si el objeto se reemplaza entero, se edita el archivo.
> Si el cambio ya quedó grabado en la base, se escribe uno nuevo.**

Es la misma regla que decide entre `V__` y `R__` al crear algo. Corregir un bug
no es un caso aparte: es el mismo criterio aplicado a un cambio que salió mal.

### Lo que queda registrado, en los dos casos

- **En git:** el commit del fix, con su mensaje explicando qué se rompió y por qué
  esa fue la corrección.
- **En la base:** una fila nueva en `flyway_schema_history` de cada ambiente, con
  fecha y checksum.
- **En GitHub:** quién revisó el fix, y quién aprobó su despliegue a producción.

Los siete cambios de rutina están en
[`ejemplos-de-cambios.md`](ejemplos-de-cambios.md). Los conflictos entre ramas,
en [`escenarios-de-conflicto.md`](escenarios-de-conflicto.md).
