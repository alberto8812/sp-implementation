# Cuatro conflictos entre ramas, y cómo se resuelven

Guion de presentación. Cada escenario parte del repositorio tal como está hoy:

```
sql/V1__baseline_schema.sql
sql/V2__create_sp_get_cliente.sql
sql/V3__add_telefono_clientes.sql
sql/R__sp_actualizar_pedido.sql
```

Dos personas salen de `main` al mismo tiempo, cada una en su rama, y trabajan sin
saber lo que hace la otra. Eso es lo normal, no la excepción.

La idea que atraviesa los cuatro casos:

> **Git solo ve texto. Flyway ve el orden y el estado de la base.
> Hay conflictos que git grita, y hay conflictos que git no puede ver.**

De los cuatro escenarios, dos los detecta git al mergear y dos pasan el merge
sin una sola advertencia. Los segundos son los peligrosos.

---

## Escenario 1 — Dos personas editan el mismo stored procedure

**Tipo:** conflicto de texto. Git lo detecta.

### Situación

Negocio pide dos cosas la misma semana, a dos personas distintas:

- A Ana: que un pedido entregado pueda marcarse como `devuelto`.
- A Luis: que exista el estado `en_bodega` para pedidos que llegaron al depósito.

Los dos cambios viven en el mismo archivo y, peor, en la misma línea: la lista de
estados válidos de `R__sp_actualizar_pedido.sql`.

### Las dos ramas

Rama `feat/estado-devuelto` (Ana):

```sql
IF p_estado NOT IN ('pendiente', 'procesando', 'enviado',
                    'entregado', 'cancelado', 'devuelto') THEN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Estado inválido para pedido';
END IF;
```

Rama `feat/estado-en-bodega` (Luis):

```sql
IF p_estado NOT IN ('pendiente', 'procesando', 'en_bodega',
                    'enviado', 'entregado', 'cancelado') THEN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Estado inválido para pedido';
END IF;
```

### Qué pasa

Ana mergea primero, sin problemas. Luis actualiza su rama contra `main` y git se
detiene:

```
CONFLICT (content): Merge conflict in sql/R__sp_actualizar_pedido.sql
Automatic merge failed; fix conflicts and then commit the result.
```

El archivo queda así:

```sql
<<<<<<< HEAD
IF p_estado NOT IN ('pendiente', 'procesando', 'enviado',
                    'entregado', 'cancelado', 'devuelto') THEN
=======
IF p_estado NOT IN ('pendiente', 'procesando', 'en_bodega',
                    'enviado', 'entregado', 'cancelado') THEN
>>>>>>> feat/estado-en-bodega
```

### Cómo se resuelve

La trampa es pensar que hay que **elegir** una de las dos versiones. No hay que
elegir: los dos cambios son correctos y no se contradicen. La resolución es
quedarse con ambos estados.

```sql
IF p_estado NOT IN ('pendiente', 'procesando', 'en_bodega', 'enviado',
                    'entregado', 'cancelado', 'devuelto') THEN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Estado inválido para pedido';
END IF;
```

Y también hay que conservar la regla que Ana agregó más abajo en el archivo, que
git probablemente mergeó sin conflicto porque está en otro bloque:

```sql
IF p_estado = 'devuelto' AND v_estado_actual <> 'entregado' THEN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Solo se puede devolver un pedido entregado';
END IF;
```

Después del merge, el archivo tiene un checksum nuevo. Flyway lo vuelve a
ejecutar en los tres ambientes y el procedure queda con las dos reglas.

### A destacar

Este es el conflicto **fácil**. Git lo marca, se ve en la pantalla, y el archivo
no llega a `main` hasta que alguien lo resuelve. Un `R__` puede editarse cuantas
veces haga falta: se reemplaza entero, así que resolver el conflicto es
literalmente escribir la versión final del procedure.

---

## Escenario 2 — Dos ramas crean la misma versión `V4__`

**Tipo:** colisión de versión. **Git no lo detecta.**

### Situación

La última migración versionada en `main` es `V3__`. Ana y Luis, cada uno por su
lado, miran el directorio, ven que el número siguiente es el 4, y lo usan.

### Las dos ramas

Rama `feat/columna-actualizado-en` (Ana) crea:

```sql
-- sql/V4__add_actualizado_en_pedidos.sql
ALTER TABLE pedidos
    ADD COLUMN actualizado_en DATETIME NULL DEFAULT NULL;
```

Rama `feat/tabla-historial` (Luis) crea:

```sql
-- sql/V4__create_historial_pedidos.sql
CREATE TABLE historial_pedidos (
    id INT PRIMARY KEY AUTO_INCREMENT,
    pedido_id INT NOT NULL,
    estado_nuevo VARCHAR(20) NOT NULL,
    registrado_en DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_historial_pedido
        FOREIGN KEY (pedido_id) REFERENCES pedidos(id)
);
```

### Qué pasa

**Git mergea las dos ramas sin una sola advertencia.** Son dos archivos con
nombres distintos; para git no hay nada que resolver. `main` queda con dos
archivos que declaran ser la versión 4.

El error aparece recién cuando Flyway intenta ordenar las migraciones:

```
ERROR: Found more than one migration with version 4
Offenders:
-> sql/V4__add_actualizado_en_pedidos.sql (SQL)
-> sql/V4__create_historial_pedidos.sql (SQL)
```

Flyway no aplica nada. No es que aplique una y falle en la otra: se niega a
empezar. Las tres bases quedan intactas.

### El detalle que hay que mostrar en la presentación

El Pull Request de Luis estaba **en verde** cuando lo abrió. El check
`Migrations run from an empty schema` pasó, porque en ese momento `main` todavía
no tenía el `V4__` de Ana. El conflicto no existía cuando se corrieron los
checks; nació en el instante del merge de Ana.

Por eso el ruleset de `main` exige que la rama esté actualizada contra `main`
antes de mergear. Eso obliga a que los checks se vuelvan a correr sobre la
combinación real, y ahí sí sale rojo.

### Cómo se resuelve

Luis actualiza su rama contra `main` y renombra su archivo:

```bash
git mv sql/V4__create_historial_pedidos.sql \
       sql/V5__create_historial_pedidos.sql
```

Renombrar es seguro **porque la migración todavía no se aplicó en ningún
ambiente**. Si ya se hubiera aplicado, renombrarla sería exactamente el error del
caso 7 de [`ejemplos-de-cambios.md`](ejemplos-de-cambios.md): Flyway guarda el
nombre y el checksum de lo que ejecutó, y cualquier diferencia rompe la
validación.

La regla práctica: **el número de versión se elige contra `main` actualizado, no
contra la copia local que uno tiene abierta hace tres días.**

### La alternativa que elimina el problema

En vez de numeración secuencial, usar marca de tiempo:

```
sql/V20260908_1030__add_actualizado_en_pedidos.sql
sql/V20260908_1447__create_historial_pedidos.sql
```

Dos personas no eligen el mismo minuto. El costo es que los nombres son más
largos y el orden ya no se lee de un vistazo. Es una decisión de equipo, pero
conviene tomarla antes de que haya cincuenta migraciones, no después.

---

## Escenario 3 — Una rama cambia la tabla, la otra cambia lo que la usa

**Tipo:** dependencia cruzada. **Git no lo detecta.**

### Situación

Reportes pidió una vista con pedidos y datos del cliente. Luis la crea. En
paralelo, Ana está normalizando nombres de columnas y renombra `clientes.email` a
`clientes.correo`.

Ninguno de los dos toca el archivo del otro.

### Las dos ramas

Rama `feat/vista-pedidos-completos` (Luis) crea:

```sql
-- sql/R__v_pedidos_completos.sql
CREATE OR REPLACE VIEW v_pedidos_completos AS
SELECT p.id,
       p.estado,
       p.creado_en,
       c.nombre AS cliente_nombre,
       c.email  AS cliente_email
FROM pedidos p
JOIN clientes c ON c.id = p.cliente_id;
```

Rama `refactor/renombrar-email` (Ana) crea:

```sql
-- sql/V4__rename_email_a_correo.sql
ALTER TABLE clientes
    RENAME COLUMN email TO correo;
```

### Qué pasa

Git mergea las dos ramas sin conflicto: son archivos distintos, líneas distintas,
directorios idénticos. `main` queda aparentemente sano.

Flyway aplica en orden — primero todas las versionadas, después todas las
repetibles — y revienta en la vista:

```
ERROR: Migration R__v_pedidos_completos.sql failed
SQL State  : 42S22
Error Code : 1054
Message    : Unknown column 'c.email' in 'field list'
```

Dev queda parado. `test` y `production` quedan en `skipped`.

### Por qué esto es más grave de lo que parece

Si el orden hubiera sido el inverso —la vista mergeada y aplicada antes que el
rename— el pipeline habría fallado igual, pero **en la corrida siguiente**, con
el commit de otra persona señalado como culpable. El daño no lo produce quien
rompe: lo paga quien pasa después.

Y si en vez de una vista fuera un stored procedure que solo se ejecuta cuando un
cliente hace una devolución, el error no aparece en el despliegue. Aparece un
martes a la tarde, en producción, con un cliente esperando.

### Cómo se resuelve

Los dos cambios son un solo cambio. Se resuelven juntos, en un solo Pull
Request:

```
sql/V4__rename_email_a_correo.sql     ← la estructura
sql/R__v_pedidos_completos.sql        ← y todo lo que la lee
```

Con la vista corregida:

```sql
CREATE OR REPLACE VIEW v_pedidos_completos AS
SELECT p.id,
       p.estado,
       p.creado_en,
       c.nombre AS cliente_nombre,
       c.correo AS cliente_email
FROM pedidos p
JOIN clientes c ON c.id = p.cliente_id;
```

Quien mergee segundo tiene que actualizar su rama contra `main`, correr el check
localmente, y arreglar lo que se rompió antes de pedir el merge.

### A destacar

Antes de buscar el número de versión libre, hay una pregunta que vale más:
**¿quién más lee esta columna?**

```bash
rg -n 'email' sql/
```

Un `grep` de diez segundos sobre `sql/` responde algo que git nunca va a
responder solo. Y con Flyway al menos existe un lugar único donde buscar: todo el
SQL vive en el repositorio. Con los procedures sueltos en SharePoint, esa búsqueda
no se puede hacer.

---

## Escenario 4 — Una rama edita el procedure, la otra lo renombra

**Tipo:** conflicto modificado/borrado. Git lo detecta, pero de forma confusa.

### Situación

Ana decide que `sp_actualizar_pedido` tiene un nombre poco claro y lo renombra a
`sp_cambiar_estado_pedido`. Luis, en paralelo, le agrega una validación al
procedure viejo.

### Las dos ramas

Rama `refactor/renombrar-sp` (Ana):

```bash
git mv sql/R__sp_actualizar_pedido.sql \
       sql/R__sp_cambiar_estado_pedido.sql
```

Y dentro del archivo cambia el nombre del procedure, más una migración que borra
el viejo de la base:

```sql
-- sql/V4__drop_sp_actualizar_pedido.sql
DROP PROCEDURE IF EXISTS sp_actualizar_pedido;
```

Rama `fix/validar-pedido-inexistente` (Luis) edita `R__sp_actualizar_pedido.sql`
y agrega el control de pedido inexistente.

### Qué pasa

Ana mergea primero. Luis actualiza su rama y git responde con un mensaje que
confunde a mucha gente:

```
CONFLICT (modify/delete): sql/R__sp_actualizar_pedido.sql deleted in HEAD
and modified in fix/validar-pedido-inexistente.
Version fix/validar-pedido-inexistente of sql/R__sp_actualizar_pedido.sql
left in tree.
```

Git no puede decidir solo. Dejó el archivo de Luis en el árbol de trabajo, tal
cual, y espera instrucciones.

### La resolución equivocada

La salida rápida, y la que sale mal:

```bash
git add sql/R__sp_actualizar_pedido.sql   # "listo, me quedo con el mío"
```

Resultado: `main` termina con **los dos archivos**. El repositorio recrea
`sp_actualizar_pedido` en cada corrida —porque el `R__` viejo sigue ahí— justo
después de que `V4__` lo borró. Quedan dos procedures vivos con la misma lógica y
distinto nombre, y nadie sabe cuál llama la aplicación.

Peor: `V4__` ya se aplicó, así que borrar el procedure de nuevo no es opción
directa.

### Cómo se resuelve

Aceptar el borrado y **portar el cambio al archivo nuevo**:

```bash
git rm sql/R__sp_actualizar_pedido.sql
```

Y llevar la validación de Luis a `sql/R__sp_cambiar_estado_pedido.sql`, adentro
del procedure con el nombre nuevo. Un solo procedure, con las dos mejoras.

### A destacar

Este conflicto es el argumento más concreto a favor de las ramas cortas. Ana y
Luis no se pisaron por hacer algo mal: se pisaron porque las dos ramas vivieron
demasiado. Una rama que dura horas casi nunca produce un modify/delete; una que
dura dos semanas lo produce sola.

Y hay una segunda lección: **un rename es un cambio de dos piezas.** El archivo
en git y el objeto en la base son cosas distintas. Renombrar el archivo no
renombra el procedure; hace falta el `V__` que borra el viejo. Si solo se renombra
el archivo, la base se queda con el procedure anterior para siempre.

---

## Resumen

| # | Escenario | ¿Git lo ve? | ¿Quién lo atrapa? | Riesgo |
|---|-----------|-------------|-------------------|--------|
| 1 | Dos ediciones al mismo `R__` | Sí | Git, al mergear | Bajo |
| 2 | Dos `V4__` distintos | **No** | El check de PR, si la rama está actualizada | Medio |
| 3 | `V__` cambia lo que un `R__` usa | **No** | El pipeline en dev — o nadie, si el objeto no se ejecuta | **Alto** |
| 4 | Editar vs. renombrar | Sí, confuso | Git, pero se resuelve mal fácil | Medio |

### Lo que reduce los cuatro

1. **Ramas cortas.** Salir de `main`, un cambio, Pull Request, merge. Horas, no
   semanas. Los escenarios 2 y 4 casi desaparecen.
2. **Actualizar contra `main` antes de pedir el merge.** Es lo que convierte el
   escenario 2 de "sorpresa en producción" a "check rojo en el PR".
3. **Buscar quién usa lo que se está cambiando** antes de tocar una tabla.
   `rg -n 'nombre_de_columna' sql/` cubre el escenario 3.
4. **Los cambios acoplados van en un solo Pull Request.** Si la tabla y el
   procedure que la lee cambian juntos, se mergean juntos.

### Lo que hay que dejar dicho

Ninguno de estos cuatro conflictos es nuevo. Los cuatro ya pasan hoy, con los
procedures sueltos en SharePoint. La diferencia es que hoy pasan **en silencio**:
nadie ve el conflicto porque no hay merge, no hay historial y no hay checks. El
primero que se entera es quien encuentra la base rota.

Flyway más Pull Requests no elimina los conflictos. Los vuelve **visibles**, y
los mueve al momento más barato para resolverlos: antes de tocar la primera base.

Los casos de un solo desarrollador están en
[`ejemplos-de-cambios.md`](ejemplos-de-cambios.md). Los bugs y su corrección, en
[`escenarios-de-bug.md`](escenarios-de-bug.md).
