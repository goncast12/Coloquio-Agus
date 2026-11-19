# Qué se hizo en esta sesión (y cómo funciona por dentro)

Este documento describe **solo los cambios de esta sesión**: qué investigué, qué
archivos creé, qué probé y cómo funciona cada pieza técnica.

---

## 1. Resumen

| Qué | Dónde |
|---|---|
| Se crearon 3 archivos nuevos | `Proyecto-Api/database/dw/` |
| No se modificó ningún archivo existente del proyecto | — |
| No se hizo ningún commit de git | — |
| Se probó en un Postgres descartable (ya eliminado) | contenedor `dwtest` |
| No se tocó Supabase ni el Postgres real del proyecto | — |

Archivos creados:

1. `01_dw_eventos.sql`: crea el esquema `dw` (dimensiones + hechos) y carga los datos.
2. `02_consultas.sql`: las consultas que responden las preguntas de negocio.
3. `EXPLICACION.md`: guía de conceptos para el coloquio.
4. `CAMBIOS_SESION.md`: este documento.

---

## 2. Investigación previa

Antes de escribir nada tuve que averiguar de dónde salen los datos, porque el DW
se construye a partir de las tablas operativas.

1. **Busqué el esquema.** En `~/Escritorio/Proyecto-Api/database/init.sql` está el
   esquema de la base operativa (empresas, clientes, tipos_evento, espacios,
   servicios, eventos, eventos_espacios, eventos_servicios, pagos).
2. **Leí las migraciones** (`migraciones/001` a `007`) para saber qué cambió
   después del `init.sql`. Importa la **005**, que agrega `empresas.estado`.
3. **Busqué en el código del Backend** los valores reales de dos campos:
   - `eventos.estado` → `consultado`, `reservado`, `cancelado`
     (`Backend/src/schemas/eventos.schemas.js`).
   - `pagos.estado` → la seña se guarda como `aprobado`
     (`Backend/src/services/eventos.service.js`).
4. **Busqué "invitados"** y confirmé que **no existe una tabla de invitados**. Solo
   está `eventos.cant_invitados_estimada`. Es el único hueco entre lo que pedía la
   consigna (`invitados_confirmados`) y lo que hay en la base. Se explica en la
   sección 5.

### Claves del esquema operativo que condicionan el diseño

- **Es multi-tenant con claves compuestas.** Casi todas las tablas llevan
  `id_empresa`, y las FK son compuestas, por ejemplo
  `FOREIGN KEY (id_empresa, id_tipo_evento)`. Por eso `tipos_evento` y `espacios`
  se unen por **dos columnas**, no por una.
- **El dinero es `NUMERIC`.** Evita errores de redondeo de `float`. El DW usa el
  mismo tipo.
- **`eventos.id_evento` es `SERIAL` global.** No se repite entre empresas, así que
  alcanza como identificador del evento en la fact.

---

## 3. `01_dw_eventos.sql`: qué hace, paso a paso

Se ejecuta de arriba a abajo. Cada bloque está numerado en el archivo.

### Bloque 0: eliminado (2026-11-19)

Antes había un `CREATE TABLE IF NOT EXISTS public.invitados`. Se **borró** porque
Supabase ya tiene esa tabla (ver sección 9). Ahora el script **no toca nada de
`public`**: solo lo lee. En su lugar quedó un comentario de requisito en el
encabezado.

### Bloque 1: esquema limpio

```sql
DROP SCHEMA IF EXISTS dw CASCADE;
CREATE SCHEMA dw;
```

- Un **esquema** es una carpeta de tablas dentro de la misma base. Usar `dw`
  separa el DW de las tablas operativas (`public`) sin necesitar otra base.
- `DROP ... CASCADE` borra el esquema y todo lo que contiene. Esto hace el script
  **idempotente**: se puede correr 100 veces y siempre queda igual, porque cada
  corrida reconstruye todo. Es una carga **full refresh**: simple, y correcta
  mientras el volumen sea chico.
- **Cuidado:** `dw` se borra completo en cada ejecución. Si alguien agrega tablas
  a mano dentro de `dw`, se pierden.

### Bloque 2: dimensiones

Una dimensión es una tabla de "descripciones" por las que se agrupa o filtra.
Cada una tiene:

- **`sk_*`**: clave subrogada, `SERIAL PRIMARY KEY` (entero autoincremental que
  genera el DW). La fact apunta a esto.
- **`id_*`**: la clave de negocio original, guardada como atributo normal.

| Dimensión | Particularidad |
|---|---|
| `dim_empresa` | `id_empresa` es `UNIQUE`. Un tenant = una fila. |
| `dim_tipo_evento` | Clave de negocio **compuesta**: `UNIQUE (id_empresa, id_tipo_evento)`, porque cada empresa tiene su catálogo ("Cumple" de la empresa 5 ≠ "Cumple" de la 6). |
| `dim_estado_evento` | Tabla chica de 3 filas con `cuenta_como_ingreso` (TRUE solo para `reservado`). Deja la regla "qué factura" en un solo lugar, en vez de repetir `WHERE estado = 'reservado'` por todos lados. |
| `dim_fecha` | Calendario. Ver explicación técnica abajo. |

#### Cómo se genera `dim_fecha`

```sql
FROM generate_series('2024-01-01'::DATE, '2032-12-31'::DATE, '1 day') AS d
```

- `generate_series` devuelve una fila por día entre dos fechas (≈ 3.280 filas).
- `sk_fecha = to_char(d,'YYYYMMDD')::INT` convierte 2026-11-14 en el entero
  `20261114`. Es una subrogada "legible": ordena cronológicamente y permite filtrar
  sin hacer join.
- `EXTRACT(ISODOW FROM d)` da el día de semana **ISO**: 1=lunes … 7=domingo. (El
  `DOW` común va de 0=domingo a 6, que es menos cómodo.)
- Los nombres en español salen de un `ARRAY[...]` indexado por el número:
  `(ARRAY['Enero',...])[EXTRACT(MONTH FROM d)]`. **Los arrays de Postgres empiezan
  en 1**, no en 0, por eso funciona directo con mes (1–12) e ISODOW (1–7).
- `anio_mes` (`'2026-11'`) existe para agrupar y ordenar por mes-año sin armar
  `anio*100+mes`.

> **Limitación:** si hay un evento fuera de 2024–2032 el insert de la fact falla
> por violación de FK (ver sección 6).

### Bloque 3: tabla de hechos `dw.fact_eventos`

- `sk_fact_evento`: subrogada propia de la fila.
- `id_evento INT NOT NULL UNIQUE`: **dimensión degenerada** y a la vez
  **garantía del grano**. El `UNIQUE` impide dos filas del mismo evento.
- Cuatro FK a dimensiones: `sk_empresa`, `sk_tipo_evento`, `sk_fecha`, `sk_estado`.
  Esas FK obligan a que cada hecho tenga su dimensión.
- Las 11 medidas. `cantidad_eventos` vale siempre 1: así "contar eventos" es
  `SUM(cantidad_eventos)`, igual que cualquier otra medida, y los promedios se
  calculan como cociente de sumas.
- Tres índices sobre las FK (`sk_empresa`, `sk_tipo_evento`, `sk_fecha`) porque
  las consultas agrupan por esas columnas.

### Bloque 4: ETL (carga)

**ETL** = Extract, Transform, Load. Acá es todo SQL: se extrae de `public`, se
transforma en el `SELECT` y se carga con `INSERT ... SELECT`.

Las dimensiones se cargan primero (la fact necesita sus `sk_` ya creadas).

#### La carga de la fact y por qué usa CTEs

Esta es la parte más importante.

**El problema (fan-out).** Un evento tiene muchos servicios, muchos pagos, muchos
espacios. Si se hace:

```sql
FROM eventos e
JOIN eventos_servicios s ON ...   -- 3 filas
JOIN pagos p ON ...               -- 2 filas
```

el evento sale **3 × 2 = 6 veces**, y `SUM(monto_total)` queda multiplicado por 6.

**La solución.** Reducir cada tabla "muchos" a **una fila por evento** *antes* de
unirla:

```sql
WITH srv AS (SELECT id_evento, COUNT(*), SUM(cantidad*precio_unitario) ... GROUP BY id_evento),
     esp AS (...), pag AS (...), inv AS (...)
SELECT ... FROM eventos ev LEFT JOIN srv ... LEFT JOIN pag ...
```

Cada CTE (`WITH`) produce como máximo una fila por `id_evento`, así que los
`LEFT JOIN` ya no multiplican nada. **El grano queda en una fila por evento.**

Detalle de cada CTE:

| CTE | Cálculo | Nota |
|---|---|---|
| `srv` | `COUNT(*)` y `SUM(cantidad * precio_unitario)` | Es la cantidad de **líneas** de servicio (no `SUM(cantidad)`). El monto sí multiplica por cantidad. |
| `esp` | `COUNT(*)` y `SUM(precio_adicional)` | `eventos_espacios` no guarda precio, así que se une a `espacios` con `USING (id_empresa, id_espacio)` (join por las dos columnas de la clave compuesta). |
| `pag` | `SUM(monto) WHERE estado='aprobado'` | Un pago rechazado o pendiente no cuenta como cobrado. |
| `inv` | `COUNT(*) FILTER (WHERE confirmado)` | `FILTER` cuenta solo las filas que cumplen la condición; equivale a `SUM(CASE WHEN ... THEN 1 ELSE 0 END)`. |

**`LEFT JOIN` + `COALESCE(x, 0)`.** Un evento sin ningún pago no aparece en `pag`.
Con `INNER JOIN` desaparecería de la fact. Con `LEFT JOIN` se conserva y las
columnas de `pag` vienen `NULL`; `COALESCE(NULL, 0)` las convierte en 0.

**`saldo_pendiente = monto_total − monto_pagado`**, calculado con el
`COALESCE` ya aplicado.

**Los joins a dimensiones** (`dim_empresa`, `dim_tipo_evento`, `dim_estado_evento`)
son `INNER JOIN` y es donde se "traducen" los `id_` de negocio a `sk_`. En
`dim_tipo_evento` se une por `(id_empresa, id_tipo_evento)`.

**`sk_fecha`** se calcula con la misma fórmula que en la dimensión
(`to_char(fecha_evento,'YYYYMMDD')::INT`), sin necesidad de un join extra.

#### Cálculo de `duracion_horas`

```sql
ROUND(EXTRACT(EPOCH FROM
      (ev.hora_fin - ev.hora_inicio)
      + CASE WHEN ev.hora_fin <= ev.hora_inicio THEN INTERVAL '24 hours'
             ELSE INTERVAL '0' END) / 3600.0, 2)
```

1. En Postgres, `TIME - TIME` da un `INTERVAL` (ej. `04:00 - 22:00 = -18:00:00`).
2. Si el evento termina "al día siguiente" (fin ≤ inicio), el resultado es
   negativo. El `CASE` le suma 24 h: `-18 h + 24 h = 6 h`.
3. `EXTRACT(EPOCH FROM intervalo)` devuelve los **segundos** totales.
4. Se divide por `3600.0` (el `.0` fuerza división decimal, no entera) y se
   redondea a 2 decimales.

> Un evento de exactamente 24 h (inicio = fin) se interpreta como 24 h, no como 0.

### Bloque 5: control de calidad

```sql
SELECT COUNT(*) origen, COUNT(*) fact, SUM(monto_total) origen, SUM(monto_total) dw
```

Compara cantidad de filas y suma de `monto_total` entre el origen y el DW.
Deben ser iguales. Si no lo son, se perdió o se duplicó algo.

---

## 4. `02_consultas.sql`: cómo se arma cada consulta

Todas siguen la misma forma de estrella:

```
fact  JOIN  dimensiones (por sk_)  WHERE filtros  GROUP BY atributos  ORDER BY
```

| Pregunta | Agrupa por | Medida |
|---|---|---|
| Facturación por empresa y mes | `dim_empresa.nombre`, `dim_fecha.anio_mes` | `SUM(monto_total)` |
| Ingresos y ticket promedio por tipo | `dim_tipo_evento.nombre` | `SUM(monto_total)` y `SUM(monto_total)/SUM(cantidad_eventos)` |
| Días de la semana con más eventos | `dia_semana, nombre_dia` | `SUM(cantidad_eventos)` |
| Meses con más eventos | `mes, nombre_mes` | `SUM(cantidad_eventos)` |
| Cobrado vs pendiente por empresa | `dim_empresa.nombre` | `SUM(monto_pagado)`, `SUM(saldo_pendiente)` |

Puntos técnicos:

- **Ticket promedio = suma de montos / suma de eventos**, y no un `AVG()` sobre
  una columna guardada. Un promedio no se puede sumar ni re-agrupar: promediar
  promedios da mal. Guardando `cantidad_eventos = 1` se calcula bien a cualquier
  nivel (por tipo, por mes, por empresa).
- **`NULLIF(SUM(monto_total), 0)`** en `pct_cobrado` evita "división por cero":
  si el total es 0, `NULLIF` devuelve `NULL` y el porcentaje queda `NULL` en vez
  de dar error.
- **Filtros distintos según la pregunta:**
  - Dinero (facturación, ticket, cobrado) → solo `cuenta_como_ingreso`
    (= `reservado`).
  - Concentración de eventos (días y meses) → `estado <> 'cancelado'`, porque un
    evento consultado también ocupa demanda, y uno cancelado no.
- **Ordenar por mes** se hace con `anio_mes` (`'2026-11'`), que ordena bien como
  texto; en 3b se usa `mes` numérico en el `ORDER BY ... DESC` por cantidad.

---

## 5. La decisión sobre `invitados_confirmados`

> **Actualización 2026-11-19:** esta decisión quedó obsoleta. El esquema real de
> Supabase sí tiene `invitados`, así que el bloque 0 se eliminó (sección 9). Lo
> de abajo es el razonamiento original, conservado como historia.

La consigna pide resumir "invitados" a nivel evento, pero **en la base no existe
esa tabla**. Opciones que consideré:

1. Poner `invitados_confirmados = 0` fijo. Es honesto pero la medida queda inútil.
2. Preguntarte antes de seguir.
3. **Crear `public.invitados` si no existe** y dejar el ETL listo. *(Elegida.)*

Elegí la 3 porque deja el DW funcionando y es fácil de cambiar. Pero es un
**supuesto** que hay que alinear con tu compañero: si en Supabase ya hay una
tabla de invitados, hay que borrar el bloque 0 y adaptar el CTE `inv`. Mientras
la tabla esté vacía, `invitados_confirmados` da 0 para todos los eventos (no es un
error).

---

## 6. Cómo se probó

No había `psql` instalado, pero sí Docker con la imagen `postgres:16-alpine`.

1. Levanté un contenedor **nuevo y aislado** llamado `dwtest` (sin publicar
   puertos, para no chocar con nada). **No toqué** los contenedores del
   proyecto (`proyecto-api-postgres-1`, backends, nginx).
2. Cargué `init.sql` y la migración `005` (porque `init.sql` es anterior a la
   005 y el DW usa `empresas.estado`).
3. Cargué datos de prueba que armé a mano (guardados en el scratchpad de la
   sesión, no en el proyecto): 2 empresas, 4 eventos (uno que cruza medianoche,
   uno cancelado), servicios con cantidad > 1, un pago **rechazado** y
   3 invitados (2 confirmados).
4. Ejecuté `01_dw_eventos.sql` **dos veces** (la segunda con invitados) para
   comprobar que es re-ejecutable.
5. Verifiqué a mano los valores de la fact. Ejemplo del evento 1:
   - Servicios: 1×500 + 3×100 = **800** ✔
   - Espacios: 200 + 300 = **500** ✔
   - Pagado: 500 + 300 = **800** (el rechazado de 999 no suma) ✔
   - Saldo: 2000 − 800 = **1200** ✔
   - Duración: 22:00→04:00 = **6.00** ✔
   - Invitados confirmados: **2** de 3 ✔
6. Corrí las 5 consultas y los resultados fueron coherentes.
7. Eliminé el contenedor `dwtest`.

**Un error durante la prueba:** la primera vez falló porque mis datos de prueba
usaban `empresas.estado`, que no está en `init.sql`. No era un bug del DW sino de
mi entorno de prueba: apliqué la migración 005 y siguió bien.

**Qué NO se probó:** no se corrió contra Supabase real ni con datos reales. Solo
con datos chicos de prueba. Tampoco se probó rendimiento con volumen grande.

---

## 7. Limitaciones y riesgos conocidos

Cosas que el script hace de una forma que puede sorprender con datos reales:

1. **Eventos con `estado` desconocido desaparecen en silencio.** El join a
   `dim_estado_evento` es `INNER`: si algún evento tuviera un estado distinto de
   `consultado/reservado/cancelado`, no entraría a la fact. El control del bloque 5
   lo mostraría (`eventos_origen ≠ filas_fact`), pero no frena la carga.
2. **Fechas fuera de 2024–2032** hacen fallar el insert por FK. Se arregla
   ampliando el rango en `generate_series`.
3. **`saldo_pendiente` puede ser negativo** si se pagó de más. No se le aplicó
   `GREATEST(..., 0)` a propósito, para no esconder el dato; se puede cambiar.
4. **`monto_total` viene tal cual del origen.** No se recalcula, así que no está
   garantizado que sea igual a `precio_base + espacios + servicios`.
5. **Eventos cancelados con seña cobrada** no aparecen en la consulta de
   cobrado/pendiente (filtra por `reservado`). Si hay plata cobrada en eventos
   cancelados, esa consulta no la muestra.
6. **Full refresh:** las `sk_` se regeneran en cada corrida (los `SERIAL`
   vuelven a empezar). Está bien porque la fact se recarga junta con las
   dimensiones, pero significa que **una `sk_` no es estable entre corridas**: no
   hay que guardarla fuera del DW.
7. **No hay historia (SCD).** Si una empresa cambia de nombre, el DW solo
   refleja el nombre actual.
8. **El DW es una copia:** no se actualiza solo. Hay que volver a ejecutar el
   script para ver eventos nuevos.

---

## 8. Cómo reproducirlo / usarlo

1. Conectarse en pgAdmin a la base (credenciales de Supabase, las tiene tu compañero).
2. Query Tool → ejecutar `01_dw_eventos.sql`. Mirar el resultado final: las
   columnas `eventos_origen` / `filas_fact` y `total_origen` / `total_dw` deben
   coincidir.
3. Ejecutar `02_consultas.sql` (se puede correr consulta por consulta
   seleccionando el texto y presionando F5).
4. Para actualizar con datos nuevos, volver a correr el paso 2.

---

## 9. Sesión 2026-11-19: verificación contra el esquema real de Supabase

Mi compañero exportó desde pgAdmin 4 consultas de solo lectura sobre Supabase
(columnas de las tablas, listado de tablas, conteo de estados). Se comparó con
`init.sql` + migraciones y con lo que lee el ETL.

### Resultado de la comparación

| Punto | Resultado |
|---|---|
| `invitados` | **Existe** en Supabase: `id_invitado, id_empresa, id_evento, nombre, apellido (NOT NULL), telefono, confirmado`. El CTE `inv` solo usa `id_evento` y `confirmado`, que existen: **no hizo falta adaptarlo**. |
| `eventos_espacios` | Columnas `id_empresa, id_evento, id_espacio`, iguales a `init.sql` (se pidió una consulta aparte porque faltaba en el primer export). |
| Columnas nuevas | `empresas.email` NOT NULL, `empresas.descripcion`, `empresas.direccion`; tabla nueva `imagenes`. Coinciden con las migraciones 005 a 007. El DW no las usa. |
| Estados | Eventos: `consultado` (2) y `reservado` (2). Pagos: `aprobado` (2). Todos cubiertos por `dim_estado_evento` y por el filtro `'aprobado'`. |
| Tablas | Las 13 esperadas: las 9 del DW más `clientes`, `imagenes`, `roles`, `usuarios`. |

### Cambio hecho

- `01_dw_eventos.sql`: se **eliminó el bloque 0** (`CREATE TABLE IF NOT EXISTS public.invitados`).
  Motivo: ya no hace falta y, si se corriera en una base sin `invitados`, la crearía
  **sin `apellido`**, distinta de la real. Quedó un comentario de requisito en el encabezado.
  El resto del script no cambió.

### Cómo se probó

1. Contenedor descartable `dwtest2` (`postgres:16-alpine`, sin puertos publicados,
   sin tocar los contenedores del proyecto).
2. Esquema real reconstruido: `init.sql` + migraciones 005, 006 y 007, más
   `invitados` con sus columnas reales y los `NOT NULL` que difieren
   (`empresas.email`, `eventos.nombre_homenajeado`, `pagos.id_usuario`, `pagos.concepto`).
   Resultado: las mismas 13 tablas que Supabase.
3. Datos de prueba: 2 empresas, 5 eventos que cubren los casos borde:
   - evento con 2 servicios, 2 espacios y 3 pagos (uno `pendiente`, que no debe sumar): prueba el fan-out;
   - cruce de medianoche (22:00 a 04:00 y 20:00 a 02:00);
   - evento sin servicios, espacios ni pagos;
   - evento `cancelado` con seña cobrada;
   - pago de más (saldo negativo).
4. `01_dw_eventos.sql` corrió **dos veces** sin error (re-ejecutable). Control de
   totales: 5 de 5 filas, 21500 de 21500.
5. Se compararon las 5 filas de la fact contra valores calculados a mano con
   `EXCEPT` en ambos sentidos: **0 diferencias**. Los días de la semana se
   contrastaron con Python.
6. Las 5 consultas de `02_consultas.sql` dieron resultados coherentes con lo
   calculado a mano (por ejemplo Night Bar: 8000 a cobrar, 5500 cobrado, 2500
   pendiente, 68,8 %; Salon Sol: 110 % cobrado por el pago de más).

### Qué sigue sin probarse

- Nunca se corrió contra Supabase real. Falta que mi compañero ejecute
  `01_dw_eventos.sql` en pgAdmin.
- Los largos de `VARCHAR` de Supabase no se compararon (la consulta no trajo
  `character_maximum_length`). Riesgo bajo.
- Supabase tiene hoy solo 4 eventos y 2 pagos, así que las consultas van a
  devolver pocas filas.
