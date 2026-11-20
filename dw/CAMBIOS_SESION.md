# Data Warehouse de eventos: guía técnica para estudiar

Este documento explica **qué hace el DW, cómo está armado por dentro y por qué se
tomó cada decisión**. Está pensado para estudiarlo de arriba a abajo antes del
coloquio. Complementa a `EXPLICACION.md` (que es el resumen de conceptos en una
página): acá está el detalle técnico y un ejemplo con números.

**Índice**

1. [Qué es y qué responde](#1-qué-es-y-qué-responde)
2. [Qué hay en este repo](#2-qué-hay-en-este-repo)
3. [De dónde salen los datos](#3-de-dónde-salen-los-datos)
4. [El modelo: tablas del DW](#4-el-modelo-tablas-del-dw)
5. [El script `01_dw_eventos.sql`, paso a paso](#5-el-script-01_dw_eventossql-paso-a-paso)
6. [Ejemplo completo con números](#6-ejemplo-completo-con-números)
7. [Las consultas de `02_consultas.sql`](#7-las-consultas-de-02_consultassql)
8. [Decisiones y supuestos de negocio](#8-decisiones-y-supuestos-de-negocio)
9. [Cómo se verificó que funciona](#9-cómo-se-verificó-que-funciona)
10. [Limitaciones conocidas](#10-limitaciones-conocidas)
11. [Cómo ejecutarlo en pgAdmin](#11-cómo-ejecutarlo-en-pgadmin)
12. [Preguntas probables del coloquio](#12-preguntas-probables-del-coloquio)
13. [Historial de cambios](#13-historial-de-cambios)

---

## 1. Qué es y qué responde

Un **Data Warehouse (DW)** es una copia de los datos operativos reorganizada para
**analizar** (sumar, agrupar, comparar) en vez de para **operar** (crear un
evento, registrar un pago). La base operativa está pensada para escribir rápido y
sin duplicar datos; el DW está pensado para que las preguntas de negocio se
respondan con consultas simples.

Este DW está sobre PostgreSQL (Supabase). Vive en un esquema aparte llamado `dw`,
dentro de la misma base, y se alimenta de las tablas operativas del esquema
`public`.

**Preguntas de negocio que responde:**

1. ¿Cuánto factura cada empresa por mes?
2. ¿Qué tipos de evento generan más ingresos y cuál es el ticket promedio?
3. ¿Qué días de la semana y qué meses concentran más eventos?
4. ¿Cuánto le falta cobrar a cada empresa (cobrado vs pendiente)?

**El grano.** El grano es lo que representa una fila de la tabla de hechos. Es la
decisión más importante de un DW y se define primero:

> **"Cada fila de la tabla de hechos es un evento."**

Todo lo demás (medidas, dimensiones) se decide a partir de eso. Si el grano fuera
"un pago" o "un servicio contratado", el modelo sería otro.

**Modelo estrella.** Una tabla de hechos al centro (los números que se suman),
rodeada de dimensiones (por qué criterio se agrupan o filtran esos números). Las
dimensiones se unen directo a la fact y **no se encadenan entre sí** (si se
encadenaran sería un "copo de nieve").

```
                 dim_empresa
                      |
dim_tipo_evento ---- fact_eventos ---- dim_fecha
                      |
                dim_estado_evento
```

---

## 2. Qué hay en este repo

| Archivo | Para qué sirve |
|---|---|
| `00_seed_empresas_demo.sql` | **Opcional, va antes de todo.** Agrega 6 empresas demo con 84 eventos para que el DW tenga datos que comparar. |
| `01_dw_eventos.sql` | **Se ejecuta después del seed.** Crea el esquema `dw` (4 dimensiones y la fact) y carga los datos desde `public`. Termina con un control de calidad. |
| `02_consultas.sql` | Una consulta por cada pregunta de negocio. Se ejecuta después. |
| `EXPLICACION.md` | Resumen de conceptos para el coloquio (grano, estrella, `sk_`, dimensión degenerada, medidas). |
| `CAMBIOS_SESION.md` | Este documento: el detalle técnico completo. |

El script solo **lee** de `public`. No crea, modifica ni borra nada ahí. Lo único
que escribe es el esquema `dw`.

---

## 3. De dónde salen los datos

El DW se construye a partir de la base operativa de la API de eventos
(multi-tenant: varias empresas comparten las mismas tablas). Tablas que lee:

| Tabla operativa | Qué aporta al DW |
|---|---|
| `empresas` | Dimensión empresa |
| `tipos_evento` | Dimensión tipo de evento |
| `eventos` | Una fila de hechos por evento: fecha, horas, estado, `monto_total`, invitados estimados |
| `eventos_servicios` | Monto y cantidad de servicios contratados |
| `eventos_espacios` + `espacios` | Monto y cantidad de espacios (el precio está en `espacios.precio_adicional`) |
| `pagos` | Monto cobrado |
| `invitados` | Cantidad de invitados confirmados |

**Dos características del esquema operativo condicionan el diseño:**

- **Claves compuestas por empresa.** Casi todas las tablas llevan `id_empresa` y las
  FK son compuestas, por ejemplo `FOREIGN KEY (id_empresa, id_tipo_evento)`. Cada
  empresa tiene su propio catálogo: el "Cumpleaños" de la empresa 5 no es el de la
  6. Por eso `tipos_evento` y `espacios` se unen por **dos columnas**.
- **El dinero es `NUMERIC`**, no `float`, para evitar errores de redondeo. El DW usa
  el mismo tipo.
- `eventos.id_evento` es un `SERIAL` global: no se repite entre empresas, así que
  alcanza para identificar el evento en la fact.

**Valores reales de `estado`** (confirmados contra Supabase, todo en minúscula y
sin tildes):

- `eventos.estado`: `consultado`, `reservado`, `cancelado`.
- `pagos.estado`: `aprobado` (así registra el backend la seña).

---

## 4. El modelo: tablas del DW

### Claves subrogadas (`sk_`) y claves de negocio (`id_`)

Cada dimensión tiene dos claves:

- **`sk_*` (subrogada):** un entero autoincremental (`SERIAL`) que genera el DW.
  No significa nada en el negocio. **La fact apunta a esta.**
- **`id_*` (de negocio):** el identificador original del sistema operativo, que se
  guarda como un atributo más para poder volver al origen.

Por qué se usan subrogadas en lugar de las claves originales:

- **Independencia del origen:** si el sistema operativo reutiliza o cambia ids, el
  DW no se rompe.
- **Simplifican claves compuestas:** un tipo de evento en el origen se identifica
  por `(id_empresa, id_tipo_evento)`; en el DW es un solo entero (`sk_tipo_evento`).
- **Joins más livianos** (una columna entera en vez de dos).
- **Permiten versionar** una dimensión a futuro (guardar historia).

### Las dimensiones

| Dimensión | Qué describe | Clave subrogada | Clave de negocio | Atributos |
|---|---|---|---|---|
| `dim_empresa` | Quién | `sk_empresa` | `id_empresa` (UNIQUE) | `nombre`, `cuit`, `estado` |
| `dim_tipo_evento` | Qué tipo de evento | `sk_tipo_evento` | `(id_empresa, id_tipo_evento)` (UNIQUE) | `nombre`, `precio_base` |
| `dim_estado_evento` | En qué estado está | `sk_estado` | `estado` (UNIQUE) | `cuenta_como_ingreso` |
| `dim_fecha` | Cuándo | `sk_fecha` (YYYYMMDD) | `fecha` (UNIQUE) | `anio`, `trimestre`, `mes`, `nombre_mes`, `anio_mes`, `dia_mes`, `dia_semana`, `nombre_dia`, `es_fin_de_semana` |

Particularidades:

- **`dim_estado_evento`** es una tabla de 3 filas. La columna `cuenta_como_ingreso`
  (TRUE solo para `reservado`) deja la regla "qué se considera facturación" en un
  único lugar. Sin ella habría que repetir `WHERE estado = 'reservado'` en cada
  consulta.
- **`dim_fecha`** es un calendario: una fila por día entre 2024-01-01 y 2032-12-31
  (unas 3.280 filas). Se genera con `generate_series`, no se lee del origen.
- **`dia_semana`** usa el estándar ISO: 1 = lunes … 7 = domingo.
- **`anio_mes`** (`'2026-11'`) sirve para agrupar y ordenar por mes-año sin armar
  `anio*100 + mes`.

### La tabla de hechos `fact_eventos`

Una fila por evento. Tiene tres tipos de columnas:

**1. Identificadores**

- `sk_fact_evento`: clave propia de la fila.
- `id_evento INT NOT NULL UNIQUE`: **dimensión degenerada**. Es el identificador
  del evento, pero no tiene tabla dimensión propia porque no tiene atributos
  descriptivos que sirvan para agrupar. Vive dentro de la fact y sirve para
  (1) **garantizar el grano**: el `UNIQUE` hace que la base rechace una segunda
  fila del mismo evento, (2) volver al evento original y (3) auditar.

**2. Claves foráneas a las dimensiones**

`sk_empresa`, `sk_tipo_evento`, `sk_fecha`, `sk_estado`. Las FK obligan a que cada
hecho tenga su dimensión.

**3. Las 11 medidas**

| Medida | De dónde sale |
|---|---|
| `cantidad_eventos` | Constante 1. Permite contar eventos con `SUM()` como cualquier otra medida. |
| `monto_total` | `eventos.monto_total`, tal cual. |
| `monto_servicios` | `SUM(cantidad × precio_unitario)` de `eventos_servicios`. |
| `monto_espacios` | `SUM(precio_adicional)` de los espacios del evento. |
| `monto_pagado` | `SUM(monto)` de los pagos con estado `aprobado`. |
| `saldo_pendiente` | `monto_total − monto_pagado`. |
| `invitados_estimados` | `eventos.cant_invitados_estimada`. |
| `invitados_confirmados` | Cantidad de invitados con `confirmado = TRUE`. |
| `cantidad_espacios` | Cantidad de espacios asignados al evento. |
| `cantidad_servicios` | Cantidad de líneas de servicio del evento. |
| `duracion_horas` | `hora_fin − hora_inicio`, sumando 24 h si el evento cruza la medianoche. |

**Todas las medidas son aditivas:** se pueden sumar por cualquier dimensión. Un
**promedio** no se guarda. Por ejemplo, el ticket promedio se calcula como
`SUM(monto_total) / SUM(cantidad_eventos)`. Un promedio guardado no se puede
re-agrupar (promediar promedios da mal); una suma sí. Esa es la razón de que
exista `cantidad_eventos`.

---

## 5. El script `01_dw_eventos.sql`, paso a paso

Se ejecuta de arriba a abajo y cada bloque está numerado en el archivo.

### Bloque 1: esquema limpio

```sql
DROP SCHEMA IF EXISTS dw CASCADE;
CREATE SCHEMA dw;
```

- Un **esquema** es una carpeta de tablas dentro de la misma base. Usar `dw`
  separa el DW de las tablas operativas (`public`) sin necesitar otra base.
- `DROP ... CASCADE` borra el esquema con todo lo que contiene. Eso hace el script
  **idempotente**: se puede correr cuantas veces se quiera y siempre queda igual,
  porque cada corrida reconstruye todo desde cero. Es una carga **full refresh**:
  simple y correcta mientras el volumen sea chico.
- **Cuidado:** `dw` se borra completo en cada ejecución. Si alguien agrega tablas a
  mano dentro de `dw`, se pierden.

### Bloque 2: crear las dimensiones y la fact

Se crean todas las tablas (vacías). Las dimensiones primero, porque la fact tiene
FK hacia ellas.

### Bloque 3: la fact y sus índices

Se crea `fact_eventos` con sus FK y tres índices (`sk_empresa`, `sk_tipo_evento`,
`sk_fecha`), porque las consultas agrupan y filtran por esas columnas.

### Bloque 4: ETL (carga de datos)

**ETL** = Extract, Transform, Load (extraer, transformar, cargar). Acá todo es SQL:
se extrae de `public`, se transforma dentro del `SELECT` y se carga con
`INSERT ... SELECT`.

**Orden de carga: dimensiones primero, fact al final.** La fact necesita que las
claves `sk_` ya existan para poder "traducir" cada `id_` de negocio a su `sk_`.

1. `dim_empresa` ← `public.empresas`
2. `dim_tipo_evento` ← `public.tipos_evento`
3. `dim_estado_evento` ← 3 filas fijas: `consultado` (no ingreso), `reservado`
   (**ingreso**), `cancelado` (no ingreso)
4. `dim_fecha` ← generada con `generate_series`
5. `fact_eventos` ← `public.eventos` + resúmenes de las tablas relacionadas

#### Cómo se genera `dim_fecha`

```sql
FROM generate_series('2024-01-01'::DATE, '2032-12-31'::DATE, '1 day') AS d
```

- `generate_series` devuelve una fila por día entre dos fechas.
- `sk_fecha = to_char(d, 'YYYYMMDD')::INT` convierte 2026-11-14 en el entero
  `20261114`. Es una subrogada "legible": ordena cronológicamente y permite filtrar
  sin hacer join.
- `EXTRACT(ISODOW FROM d)` da el día de la semana ISO (1 = lunes … 7 = domingo).
- Los nombres en español salen de un `ARRAY[...]` indexado por el número:
  `(ARRAY['Enero', ...])[EXTRACT(MONTH FROM d)]`. Los arrays de Postgres **empiezan
  en 1**, por eso funciona directo con el mes (1 a 12) y el día ISO (1 a 7).

#### La carga de la fact y por qué usa CTEs (lo más importante)

**El problema: fan-out.** Un evento tiene muchos servicios, muchos pagos, muchos
espacios. Si se hace un `JOIN` directo:

```sql
FROM eventos e
JOIN eventos_servicios s ON ...   -- 3 filas
JOIN pagos p ON ...               -- 2 filas
```

el evento sale **3 × 2 = 6 veces** y todas sus sumas quedan multiplicadas por 6.
El grano se rompe: ya no hay una fila por evento.

**La solución.** Reducir cada tabla "muchos" a **una fila por evento** *antes* de
unirla, con un CTE (`WITH`) que hace `GROUP BY id_evento`:

```sql
WITH srv AS (SELECT id_evento, COUNT(*), SUM(cantidad * precio_unitario) ... GROUP BY id_evento),
     esp AS (...), pag AS (...), inv AS (...)
SELECT ... FROM eventos ev LEFT JOIN srv ... LEFT JOIN pag ...
```

Cada CTE produce como máximo una fila por `id_evento`, así que los `LEFT JOIN` ya
no multiplican nada.

| CTE | Cálculo | Detalle |
|---|---|---|
| `srv` | `COUNT(*)` y `SUM(cantidad * precio_unitario)` | La cantidad es de **líneas** de servicio (no `SUM(cantidad)`). El monto sí multiplica por la cantidad. |
| `esp` | `COUNT(*)` y `SUM(precio_adicional)` | `eventos_espacios` no guarda precio, así que se une a `espacios` con `USING (id_empresa, id_espacio)` (join por las dos columnas de la clave compuesta). |
| `pag` | `SUM(monto)` con `WHERE estado = 'aprobado'` | Un pago pendiente o rechazado no cuenta como cobrado. |
| `inv` | `COUNT(*) FILTER (WHERE confirmado)` | `FILTER` cuenta solo las filas que cumplen la condición. Equivale a `SUM(CASE WHEN confirmado THEN 1 ELSE 0 END)`. |

**`LEFT JOIN` + `COALESCE(x, 0)`.** Un evento sin pagos no aparece en el CTE `pag`.
Con `INNER JOIN` desaparecería de la fact. Con `LEFT JOIN` se conserva y las
columnas de `pag` vienen `NULL`; `COALESCE(NULL, 0)` las convierte en 0.

**Joins a las dimensiones.** `dim_empresa`, `dim_tipo_evento` y `dim_estado_evento`
se unen con `INNER JOIN`: ahí se traducen los `id_` de negocio a `sk_`. En
`dim_tipo_evento` el join es por `(id_empresa, id_tipo_evento)`.

**`sk_fecha`** se calcula con la misma fórmula que en la dimensión
(`to_char(fecha_evento, 'YYYYMMDD')::INT`), sin necesidad de un join extra.

#### Cálculo de `duracion_horas`

```sql
ROUND(EXTRACT(EPOCH FROM
      (ev.hora_fin - ev.hora_inicio)
      + CASE WHEN ev.hora_fin <= ev.hora_inicio THEN INTERVAL '24 hours'
             ELSE INTERVAL '0' END) / 3600.0, 2)
```

1. En Postgres, `TIME - TIME` da un `INTERVAL`. Ejemplo: `04:00 - 22:00 = -18:00:00`.
2. Un evento de Night Bar que termina de madrugada tiene fin ≤ inicio, y el
   resultado da negativo. El `CASE` le suma 24 h: `-18 h + 24 h = 6 h`.
3. `EXTRACT(EPOCH FROM intervalo)` devuelve los **segundos** totales.
4. Se divide por `3600.0` (el `.0` fuerza división decimal, no entera) y se redondea
   a 2 decimales.

Un evento con inicio = fin se interpreta como 24 h, no como 0.

### Bloque 5: control de calidad

Compara, entre el origen y el DW, la cantidad de filas y la suma de `monto_total`:

| eventos_origen | filas_fact | total_origen | total_dw |
|---|---|---|---|

Los dos pares deben ser iguales. Si no lo son, se perdió o se duplicó algo. La
causa más probable de que falten filas es un evento con un `estado` que no está
entre los tres de `dim_estado_evento`.

---

## 6. Ejemplo completo con números

Datos de prueba usados para validar el DW: 2 empresas y 5 eventos, armados para
cubrir los casos difíciles. Este ejemplo sirve para **seguir el cálculo a mano**.

### Datos de origen (resumidos)

| Evento | Empresa | Tipo | Fecha | Horario | Estado | `monto_total` |
|---|---|---|---|---|---|---|
| 1 | Night Bar | Cumpleaños | 2026-11-06 (vie) | 22:00 a 04:00 | reservado | 5000 |
| 2 | Night Bar | Corporativo | 2026-11-07 (sáb) | 18:00 a 23:30 | reservado | 3000 |
| 3 | Night Bar | Cumpleaños | 2026-12-04 (vie) | 20:00 a 02:00 | consultado | 1500 |
| 4 | Night Bar | Cumpleaños | 2026-12-12 (sáb) | 21:00 a 03:00 | cancelado | 2000 |
| 5 | Salon Sol | Casamiento | 2026-11-14 (sáb) | 12:00 a 20:00 | reservado | 10000 |

Tablas relacionadas del **evento 1** (el caso de fan-out):

- Servicios: DJ 1 × 500 y Catering 2 × 100.
- Espacios: Terraza (adicional 300) y Barra (adicional 200).
- Pagos: 1000 aprobado, 1500 aprobado y **999 pendiente**.
- Invitados: 3, de los cuales 2 confirmados.

Con un `JOIN` directo, el evento 1 saldría **2 × 2 × 3 = 12 veces**. Con los CTE
sale 1 vez.

### Cómo se calcula la fila del evento 1

| Medida | Cálculo | Resultado |
|---|---|---|
| `monto_servicios` | 1×500 + 2×100 | **700** |
| `monto_espacios` | 300 + 200 | **500** |
| `monto_pagado` | 1000 + 1500 (el pendiente de 999 no suma) | **2500** |
| `saldo_pendiente` | 5000 − 2500 | **2500** |
| `duracion_horas` | 22:00 a 04:00, cruza medianoche: −18 h + 24 h | **6.00** |
| `invitados_confirmados` | 2 de 3 | **2** |
| `cantidad_servicios` / `cantidad_espacios` | líneas de servicio / espacios | **2 / 2** |

### La fact completa resultante

| Evento | `monto_total` | servicios | espacios | pagado | saldo | inv. est. | inv. conf. | cant. esp. | cant. serv. | horas |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 5000 | 700 | 500 | 2500 | 2500 | 50 | 2 | 2 | 2 | 6.00 |
| 2 | 3000 | 0 | 300 | 3000 | 0 | 30 | 0 | 1 | 0 | 5.50 |
| 3 | 1500 | 0 | 0 | 0 | 1500 | 20 | 0 | 0 | 0 | 6.00 |
| 4 | 2000 | 0 | 0 | 500 | 1500 | 40 | 0 | 0 | 0 | 6.00 |
| 5 | 10000 | 800 | 800 | 11000 | **−1000** | 100 | 4 | 1 | 1 | 8.00 |

Casos que muestra esta tabla:

- **Evento 3** no tiene servicios, espacios ni pagos: sigue estando en la fact
  (por el `LEFT JOIN`) con ceros (por el `COALESCE`).
- **Evento 4** está cancelado pero tiene una seña de 500 cobrada.
- **Evento 5** se pagó de más: saldo negativo (se deja visible a propósito).
- **Evento 2** dura 5,5 horas: `23:30 − 18:00`, sin cruzar medianoche.

---

## 7. Las consultas de `02_consultas.sql`

Todas tienen la misma forma de estrella:

```
fact  JOIN  dimensiones (por sk_)  WHERE filtros  GROUP BY atributos  ORDER BY
```

| Pregunta | Agrupa por | Medida | Filtro |
|---|---|---|---|
| 1. Facturación por empresa y mes | `dim_empresa.nombre`, `dim_fecha.anio_mes` | `SUM(monto_total)` | `cuenta_como_ingreso` |
| 2. Ingresos y ticket por tipo de evento | `dim_tipo_evento.nombre` | `SUM(monto_total)` y `SUM(monto_total)/SUM(cantidad_eventos)` | `cuenta_como_ingreso` |
| 3a. Días de la semana con más eventos | `dia_semana`, `nombre_dia` | `SUM(cantidad_eventos)` | `estado <> 'cancelado'` |
| 3b. Meses con más eventos | `mes`, `nombre_mes` | `SUM(cantidad_eventos)` | `estado <> 'cancelado'` |
| 4. Cobrado vs pendiente por empresa | `dim_empresa.nombre` | `SUM(monto_pagado)`, `SUM(saldo_pendiente)` | `cuenta_como_ingreso` |

### Resultados con los datos de prueba

(Se pueden verificar a mano con la tabla de la sección 6.)

**1. Facturación por mes**

| empresa | anio_mes | facturacion | eventos |
|---|---|---|---|
| Night Bar | 2026-11 | 8000 | 2 |
| Salon Sol | 2026-11 | 10000 | 1 |

Night Bar: 5000 (evento 1) + 3000 (evento 2). El consultado y el cancelado quedan
afuera porque no son ingreso.

**2. Ingresos por tipo de evento**

| tipo_evento | eventos | ingresos | ticket_promedio |
|---|---|---|---|
| Casamiento | 1 | 10000 | 10000 |
| Cumpleaños | 1 | 5000 | 5000 |
| Corporativo | 1 | 3000 | 3000 |

**3a. Días de la semana:** sábado 2, viernes 2 (eventos 1, 2, 3 y 5; el cancelado
no cuenta).
**3b. Meses:** noviembre 3, diciembre 1.

**4. Cobrado vs pendiente**

| empresa | total_a_cobrar | cobrado | pendiente | pct_cobrado |
|---|---|---|---|---|
| Night Bar | 8000 | 5500 | 2500 | 68,8 |
| Salon Sol | 10000 | 11000 | −1000 | 110,0 |

Night Bar: cobrado 2500 + 3000; pendiente 2500 + 0. Salon Sol cobró de más.

### Puntos técnicos de las consultas

- **Ticket promedio = suma de montos / suma de eventos**, no un `AVG()` sobre una
  columna guardada. Los promedios no se pueden re-agrupar; las sumas sí. Con
  `cantidad_eventos = 1` el cociente se calcula bien a cualquier nivel.
- **`NULLIF(SUM(monto_total), 0)`** en `pct_cobrado` evita la división por cero: si
  el total es 0 devuelve `NULL` en lugar de dar error.
- **Filtros distintos según la pregunta.** Para dinero (facturación, ticket,
  cobrado) cuentan solo los eventos `reservado`. Para concentración de demanda
  (días y meses) cuentan todos menos los `cancelado`, porque un evento consultado
  también representa demanda.
- **Ordenar por mes** se hace con `anio_mes` (`'2026-11'`), que ordena bien como
  texto.

---

## 8. Decisiones y supuestos de negocio

| Decisión | Por qué |
|---|---|
| "Factura" = eventos `reservado` | `consultado` es solo una consulta sin compromiso y `cancelado` no genera ingreso. Está centralizado en `dim_estado_evento.cuenta_como_ingreso`. |
| "Pagado" = pagos con estado `aprobado` | Es como registra el backend la seña. Los pendientes no se cuentan como cobrados. |
| Concentración de eventos excluye solo `cancelado` | Un evento consultado ocupa demanda; uno cancelado no. |
| `saldo_pendiente` puede ser negativo | No se aplica `GREATEST(..., 0)` para no esconder un pago de más. Es una decisión fácil de cambiar. |
| `monto_total` se copia del origen | No se recalcula como `precio_base + espacios + servicios`, porque el sistema operativo es la fuente de verdad del precio acordado. |
| No hay `dim_cliente` | Ninguna de las 4 preguntas agrupa por cliente y el grano es un evento. Si hiciera falta, se agregaría `dim_cliente` con `sk_cliente`, la FK en la fact y su carga en el ETL. |
| `dim_fecha` cubre 2024–2032 | Alcanza para el uso previsto. Una fecha fuera del rango hace fallar la carga (ver sección 10). |
| Full refresh en cada corrida | Más simple que una carga incremental y suficiente para el volumen actual. |

---

## 9. Cómo se verificó que funciona

### Verificación contra el esquema real de Supabase (2026-11-19)

Desde pgAdmin se exportaron consultas de solo lectura sobre Supabase (columnas,
listado de tablas, conteo de estados) y se compararon con lo que lee el ETL:

| Punto | Resultado |
|---|---|
| `invitados` | Existe en Supabase: `id_invitado, id_empresa, id_evento, nombre, apellido, telefono, confirmado`. El CTE `inv` solo usa `id_evento` y `confirmado`, que existen. |
| `eventos_espacios` | Tiene `id_empresa, id_evento, id_espacio`, lo que usa el ETL. |
| Columnas nuevas | `empresas.descripcion` y `empresas.direccion`, y la tabla `imagenes`. El DW no las usa. |
| Estados | Eventos: `consultado` (2) y `reservado` (2). Pagos: `aprobado` (2). Todos coinciden exactamente con lo que espera el DW. |
| Tablas | Las 13 esperadas: las 9 que usa el DW más `clientes`, `imagenes`, `roles` y `usuarios`. |

### Prueba en un Postgres descartable

1. Se levantó un contenedor `postgres:16-alpine` aislado y descartable (sin publicar
   puertos), y se reconstruyó el esquema real de Supabase en él.
2. Se cargaron los 5 eventos de la sección 6, que cubren los casos borde:
   fan-out (varios servicios, espacios y pagos), cruce de medianoche, evento sin
   hijos, cancelado con seña, pago de más y un pago pendiente que no debe sumar.
3. `01_dw_eventos.sql` se ejecutó **dos veces** sin error (idempotente). El control
   de calidad dio 5 de 5 filas y 21500 de 21500.
4. Las 5 filas de la fact se compararon contra valores calculados a mano con
   `EXCEPT` en ambos sentidos: **0 diferencias**. Los días de la semana se
   contrastaron con Python.
5. Las 5 consultas dieron los resultados de la sección 7, coherentes con el cálculo
   manual.

### Qué no se probó

- **Nunca se corrió contra Supabase real.** Es el paso que falta (sección 11).
- No se compararon los largos de `VARCHAR` de Supabase con los de las dimensiones
  (la consulta exportada no trajo `character_maximum_length`). Riesgo bajo: de
  fallar, sería en la carga de `dim_empresa`.
- No se probó rendimiento con volumen grande. Supabase tiene hoy muy pocos datos
  (4 eventos y 2 pagos), así que las consultas van a devolver pocas filas.

---

## 10. Limitaciones conocidas

1. **Un evento con `estado` desconocido desaparece en silencio.** El join a
   `dim_estado_evento` es `INNER`: si hubiera un estado distinto de
   `consultado`/`reservado`/`cancelado`, el evento no entraría a la fact. El control
   final lo muestra (`eventos_origen ≠ filas_fact`), pero no frena la carga.
2. **Fechas fuera de 2024–2032** hacen fallar el insert por FK. Se arregla
   ampliando el rango en `generate_series`.
3. **`saldo_pendiente` puede ser negativo** si se pagó de más.
4. **`monto_total` viene tal cual del origen**: no está garantizado que sea igual a
   `precio_base + espacios + servicios`.
5. **Los eventos cancelados con seña cobrada** no aparecen en la consulta de cobrado
   vs pendiente (filtra por `reservado`). Esa plata cobrada no se ve ahí.
6. **Las `sk_` no son estables entre corridas.** Con el full refresh los `SERIAL`
   vuelven a empezar. No hay que guardar una `sk_` fuera del DW.
7. **No hay historia (SCD).** Si una empresa cambia de nombre, el DW solo refleja el
   nombre actual.
8. **El DW es una copia, no se actualiza solo.** Hay que volver a ejecutar el script
   para ver eventos nuevos.

---

## 11. Cómo ejecutarlo en pgAdmin

1. Conectarse a la base en pgAdmin.
2. Abrir **Query Tool**, cargar `01_dw_eventos.sql` y ejecutarlo completo (F5).
   Crea el esquema `dw` y carga los datos. El último resultado debe mostrar
   `eventos_origen = filas_fact` y `total_origen = total_dw`.
3. Cargar `02_consultas.sql`. Se puede correr consulta por consulta: seleccionar el
   texto de una y presionar F5.
4. Para actualizar con datos nuevos, volver a ejecutar el paso 2 (borra y recrea
   `dw`; las tablas operativas no se tocan).

Si algo falla, los errores más probables son:

- **"relation public.xxx does not exist"**: falta una tabla operativa. Revisar que
  se esté conectado a la base correcta.
- **Violación de FK en `fact_eventos` por `sk_fecha`**: hay un evento con fecha
  fuera de 2024–2032 (limitación 2).
- **`filas_fact` menor que `eventos_origen`**: hay eventos con un estado
  desconocido (limitación 1). Se detecta con
  `SELECT estado, COUNT(*) FROM eventos GROUP BY estado;`.

---

## 12. Preguntas probables del coloquio

**¿Qué representa una fila de la tabla de hechos?**
Un evento. Lo garantiza `id_evento UNIQUE` en la fact.

**¿Por qué un modelo estrella y no el modelo operativo directo?**
Porque las consultas de análisis quedan simples (fact + dimensiones con joins
directos) y no hay que reconstruir cada vez las relaciones entre eventos, pagos,
servicios y espacios. El DW ya trae todo resumido al nivel de un evento.

**¿Para qué sirven las claves `sk_`?**
Son claves artificiales que genera el DW. Dan independencia del sistema operativo,
reducen una clave compuesta como `(id_empresa, id_tipo_evento)` a un solo entero,
hacen los joins más livianos y permitirían guardar historia de una dimensión.

**¿Qué es `id_evento` en la fact y por qué no tiene dimensión?**
Es una dimensión degenerada: un identificador sin atributos descriptivos propios.
Se deja en la fact para definir el grano, volver al origen y auditar.

**¿Qué es la duración y cómo se calcula?**
`hora_fin − hora_inicio` en horas. Si el evento cruza la medianoche (fin ≤ inicio)
se suman 24 h. Ejemplo: de 22:00 a 04:00 son 6 h.

**¿Por qué las medidas son aditivas y el ticket promedio no se guarda?**
Una medida aditiva se puede sumar por cualquier dimensión. Un promedio no se puede
re-agrupar (el promedio de promedios es incorrecto), así que se calcula como
`SUM(monto_total) / SUM(cantidad_eventos)`. Por eso existe `cantidad_eventos = 1`.

**¿Qué es el fan-out y cómo se evita?**
Si se une un evento con varias tablas "de muchos" (servicios, pagos), el evento se
repite por cada combinación y las sumas se inflan. Se evita resumiendo cada tabla
con `GROUP BY id_evento` en un CTE antes de unirla.

**¿Por qué `LEFT JOIN` y `COALESCE` en la carga de la fact?**
Para no perder los eventos que no tienen pagos, servicios o espacios. El `LEFT JOIN`
los conserva y el `COALESCE` convierte los `NULL` en 0.

**¿Qué estados cuentan como ingreso?**
Solo `reservado`. Está en `dim_estado_evento.cuenta_como_ingreso`.

**¿Qué pasa si se ejecuta el script dos veces?**
Nada malo: el `DROP SCHEMA ... CASCADE` inicial reconstruye todo, así que da el
mismo resultado (es idempotente).

**¿Qué limitaciones tiene?**
Es una carga completa sin historia, no se actualiza sola y solo reconoce tres
estados de evento. Ver sección 10.

---

## 13. Historial de cambios

- **Versión inicial:** esquema `dw`, 4 dimensiones, `fact_eventos`, ETL con CTE y
  las 5 consultas. Probado en un contenedor descartable con datos armados a mano.
- **2026-11-19, verificación contra Supabase:** se comparó el esquema real con el
  que usaba el ETL. Se eliminó del script el bloque que creaba
  `public.invitados`: ya no hace falta porque Supabase tiene esa tabla, y si el
  script se corriera en una base sin ella la habría creado sin la columna
  `apellido`. Desde entonces el script solo lee de `public`. Se repitió la prueba
  completa con el esquema real y no hubo diferencias.
- **2026-11-19, esta reescritura:** se reorganizó este documento como guía de
  estudio, con ejemplo numérico, resultados de las consultas y preguntas del
  coloquio.
- **2026-11-19, datos demo:** se agregó `00_seed_empresas_demo.sql`. Supabase tenía
  muy pocos datos (4 eventos, 2 pagos) y las consultas devolvían 1 o 2 filas. El
  seed crea 6 empresas (CUIT `30-5550xxxx-x`) con 14 eventos cada una (84 en total):
  estados, tipos, meses, pagos aprobados y pendientes variados, eventos sin
  servicios y cancelados con seña. Es idempotente y no toca empresas existentes. Se
  ejecuta **antes** de `01_dw_eventos.sql`. Probado en un contenedor descartable:
  el DW cargó 84 de 84 filas con totales iguales, las 5 consultas devolvieron
  rankings con 6 empresas, y la limpieza (bloque comentado al final) funcionó.
  No se corrió contra Supabase.

### 2026-11-20: procedimientos y verificación completa
- `01_dw_eventos.sql`: el ETL pasó a `dw.sp_cargar_dw()` (procedimiento almacenado, consigna 6).
  Agrega `dw.fn_control_totales()` con 20 controles contra `public.*`; si alguno falla, la carga se revierte.
- Nuevo `03_procedimientos_preguntas.sql`: `dw.p1_...` a `dw.p4_...` (una función por pregunta) y
  `dw.fn_control_preguntas()` que compara cada respuesta con la base operativa (consigna 5).
- Probado en un `postgres:16-alpine` descartable con el seed demo (84 eventos): carga OK, 20/20 y 9/9 controles OK,
  re-ejecución idempotente, y con un evento de estado `anulado` la carga falla y deja el DW intacto.
- No se probó contra Supabase real.

### 2026-11-20 (b): versión combinada de `01_dw_eventos.sql`
- Se combinó la versión de Descargas (estructura con `IF NOT EXISTS`, `::INT` en los subíndices de arrays,
  bloque opcional de `pg_cron`) con los 20 controles de `fn_control_totales()`. `sp_cargar_dw()` revierte si falla alguno.
- Probado en `postgres:16-alpine` descartable: 1ra y 2da corrida OK (20/20), `03` ejecutado dos veces (9/9),
  y con un estado desconocido la carga se revierte dejando la fact con sus 84 filas.
