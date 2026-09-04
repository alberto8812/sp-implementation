# Siete cambios típicos y cómo se hacen

Guía de referencia para el equipo, y guion para presentar la adopción de Flyway.

Cada caso responde tres preguntas: qué archivo se toca, por qué ese y no otro, y
qué hace el pipeline cuando llega el push.

La regla que resuelve el 95% de las dudas:

> **Objetos que se reemplazan enteros → `R__`.
> Cambios que se acumulan sobre lo anterior → `V__`.**

Un stored procedure se puede reemplazar completo: se borra el viejo y se crea el
nuevo. Una tabla no — tiene datos adentro, así que solo se le pueden sumar
cambios uno arriba del otro, y cada uno depende del anterior.

---

## Caso 1 — Modificar la lógica de un stored procedure existente

**Situación.** Negocio pide que un pedido entregado se pueda marcar como
`devuelto`, pero solo si efectivamente fue entregado.

**Archivo.** Se edita el que ya existe:

```
sql/R__sp_actualizar_pedido.sql
```

No se crea ningún archivo nuevo. Ese archivo se va a seguir editando durante
toda la vida del procedure.

**El cambio.**

```sql
IF p_estado NOT IN ('pendiente', 'procesando', 'enviado',
                    'entregado', 'cancelado', 'devuelto') THEN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Estado inválido para pedido';
END IF;

IF p_estado = 'devuelto' AND v_estado_actual <> 'entregado' THEN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Solo se puede devolver un pedido entregado';
END IF;
```

**Qué hace el pipeline.** Detecta que el checksum del archivo cambió y vuelve a
ejecutarlo: dev, después test, después espera aprobación para producción.

**A destacar.** `pedidos.estado` es `VARCHAR(20)`, así que el valor nuevo entra
sin tocar la estructura de la tabla. Este cambio no necesita ninguna migración
`V__`. Es un cambio de lógica puro.

---

## Caso 2 — Crear un stored procedure nuevo

**Situación.** Hace falta un procedure que devuelva los pedidos de un cliente.

**Archivo.** Uno nuevo, con el prefijo `R__` y el nombre exacto del procedure:

```
sql/R__sp_pedidos_por_cliente.sql
```

**El contenido.**

```sql
DROP PROCEDURE IF EXISTS sp_pedidos_por_cliente;

DELIMITER //

CREATE PROCEDURE sp_pedidos_por_cliente(IN p_cliente_id INT)
BEGIN
    SELECT id, estado, creado_en
    FROM pedidos
    WHERE cliente_id = p_cliente_id
    ORDER BY creado_en DESC;
END //

DELIMITER ;
```

**Qué hace el pipeline.** Lo aplica en los tres ambientes, en orden, con
aprobación en producción.

**A destacar.** El `DROP ... IF EXISTS` de la primera línea no es una precaución
opcional: es lo que hace que el archivo se pueda ejecutar mil veces con el mismo
resultado. MySQL 8 no tiene `CREATE OR REPLACE PROCEDURE`, así que el patrón es
siempre borrar y volver a crear.

---

## Caso 3 — Agregar una columna a una tabla

**Situación.** Hay que guardar la fecha de la última modificación de cada pedido.

**Archivo.** Uno nuevo, versionado, con el número siguiente al último que exista:

```
sql/V4__add_actualizado_en_pedidos.sql
```

**El contenido.**

```sql
ALTER TABLE pedidos
    ADD COLUMN actualizado_en DATETIME NULL DEFAULT NULL;
```

**Qué hace el pipeline.** Lo aplica una vez por ambiente y lo registra en
`flyway_schema_history`. No lo vuelve a mirar nunca más.

**A destacar.** Este archivo **no se edita nunca más después de aplicado**. Un
`ALTER TABLE ... ADD COLUMN` ejecutado dos veces falla con
`Duplicate column name`. Si mañana esa columna tiene que cambiar de tipo, es un
`V5__` nuevo.

---

## Caso 4 — Crear una tabla nueva

**Situación.** Hay que registrar el historial de cambios de estado de cada
pedido.

**Archivo.**

```
sql/V5__create_historial_pedidos.sql
```

**El contenido.**

```sql
CREATE TABLE historial_pedidos (
    id INT PRIMARY KEY AUTO_INCREMENT,
    pedido_id INT NOT NULL,
    estado_anterior VARCHAR(20),
    estado_nuevo VARCHAR(20) NOT NULL,
    registrado_en DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_historial_pedido
        FOREIGN KEY (pedido_id) REFERENCES pedidos(id)
);
```

**Qué hace el pipeline.** Igual que el caso 3: una vez por ambiente, registrado,
y nunca más.

**A destacar.** El orden numérico importa. `V5__` se aplica después de `V4__`,
siempre, en todos los ambientes. Y todas las versionadas se aplican **antes**
que cualquier `R__`, porque un procedure normalmente consulta tablas que tienen
que existir primero.

---

## Caso 5 — Un cambio que necesita los dos tipos

**Situación.** Cada vez que cambia el estado de un pedido hay que dejar registro
en `historial_pedidos`.

**Archivos.** Dos, y en este orden:

```
sql/V5__create_historial_pedidos.sql     ← la tabla (caso 4)
sql/R__sp_actualizar_pedido.sql          ← el procedure que la escribe
```

**El cambio en el procedure.**

```sql
INSERT INTO historial_pedidos (pedido_id, estado_anterior, estado_nuevo)
VALUES (p_pedido_id, v_estado_actual, p_estado);

UPDATE pedidos
SET estado = p_estado
WHERE id = p_pedido_id;
```

**Qué hace el pipeline.** Primero `V5__` crea la tabla, después el `R__`
recreado la usa. En un solo push, en un solo run.

**A destacar.** Esto es lo que hoy se hace en dos pasos manuales, en dos momentos
distintos, y a veces en distinto orden según el ambiente. Acá el orden es una
propiedad de la herramienta, no algo que alguien tenga que recordar.

---

## Caso 6 — Crear o modificar una vista

**Situación.** Reportes necesita una vista de pedidos con los datos del cliente.

**Archivo.** Repetible, porque una vista se reemplaza entera:

```
sql/R__v_pedidos_completos.sql
```

**El contenido.**

```sql
CREATE OR REPLACE VIEW v_pedidos_completos AS
SELECT p.id,
       p.estado,
       p.creado_en,
       c.nombre  AS cliente_nombre,
       c.email   AS cliente_email
FROM pedidos p
JOIN clientes c ON c.id = p.cliente_id;
```

**Qué hace el pipeline.** Cada vez que el archivo cambie, la vista se redefine
en los tres ambientes.

**A destacar.** Las vistas sí tienen `CREATE OR REPLACE` en MySQL, así que no
hace falta el `DROP` previo. Mismo criterio que un procedure: se reemplaza
entera, va en `R__`.

---

## Caso 7 — Alguien edita una migración ya aplicada

**Situación.** Un desarrollador necesita que `clientes.telefono` acepte 30
caracteres en vez de 20. Abre `V3__add_telefono_clientes.sql`, cambia el `20`
por `30`, y pushea. Es el reflejo natural de quien viene de editar archivos
sueltos.

**Qué hace el pipeline.**

```
ERROR: Validate failed: Migrations have failed validation
Migration checksum mismatch for migration version 3
```

El job de **dev falla**. `test` y `production` quedan en `skipped`. Ninguna base
se tocó.

**Por qué.** `V3__` ya se ejecutó en los tres ambientes. Editarlo no reaplica
nada — el `ALTER TABLE` original ya corrió. Lo único que cambia es el archivo,
que a partir de ahí **miente** sobre lo que hay en la base. Flyway guarda el
checksum de lo que aplicó y compara.

**La forma correcta.** Un archivo nuevo:

```sql
-- sql/V6__widen_telefono_clientes.sql
ALTER TABLE clientes MODIFY COLUMN telefono VARCHAR(30);
```

**A destacar — este es el caso más importante de los siete.** Hoy este error no
se detecta. La migración queda editada, alguien la aplica de nuevo en un
ambiente y no en otro, y los ambientes quedan distintos sin que nadie se entere
hasta que algo falla en producción. Con Flyway el pipeline se detiene antes de
tocar la primera base.

---

## Resumen

| Caso | Qué se toca | Tipo | ¿Se edita después? |
|------|-------------|------|--------------------|
| 1 | Lógica de un SP existente | `R__` | Sí, siempre el mismo archivo |
| 2 | SP nuevo | `R__` nuevo | Sí, de ahí en adelante |
| 3 | Columna nueva | `V__` nuevo | **Nunca** |
| 4 | Tabla nueva | `V__` nuevo | **Nunca** |
| 5 | Tabla + SP juntos | `V__` + `R__` | Solo el `R__` |
| 6 | Vista | `R__` | Sí |
| 7 | Editar un `V__` aplicado | — | El pipeline lo bloquea |

### El ciclo, en cualquiera de los casos

```
editar el archivo  →  commit  →  push
        ↓
      dev aplica
        ↓
      test aplica   (solo si dev pasó)
        ↓
   producción espera aprobación de una persona
        ↓
      aplica, y queda registrado quién aprobó y cuándo
```

### Lo que queda registrado

- **En git:** quién cambió qué, cuándo, y con qué justificación en el mensaje de
  commit. `git log sql/R__sp_actualizar_pedido.sql` cuenta la historia completa
  de ese procedure.
- **En la base de datos:** la tabla `flyway_schema_history` de cada ambiente, con
  una fila por cada aplicación, su checksum y su fecha.
- **En GitHub:** quién aprobó cada despliegue a producción, cuándo, y con qué
  comentario.
