# DW de Eventos — guía para el coloquio

## Frase del grano
> **"Cada fila de la tabla de hechos es un evento."**
> Se garantiza con `id_evento INT NOT NULL UNIQUE` en `fact_eventos`: la base
> rechaza una segunda fila para el mismo evento.

## Modelo estrella
Una tabla de hechos al centro (números que se suman) rodeada de dimensiones
(por qué/quién/cuándo se analizan esos números). Las dimensiones se unen a la
fact directo, sin encadenarse entre sí (eso sería copo de nieve).

```
            dim_empresa
                 |
dim_tipo_evento--+--fact_eventos--+--dim_fecha
                 |
          dim_estado_evento
```

| Tabla | Rol | Clave |
|---|---|---|
| `fact_eventos` | hechos, 1 fila por evento | `sk_fact_evento`, FK `sk_*`, `id_evento` |
| `dim_empresa` | quién | `sk_empresa` (negocio: `id_empresa`) |
| `dim_tipo_evento` | qué tipo | `sk_tipo_evento` |
| `dim_fecha` | cuándo: año, mes, día de semana | `sk_fecha` (YYYYMMDD) |
| `dim_estado_evento` | consultado / reservado / cancelado | `sk_estado` |

## Claves subrogadas (`sk_`)
Son claves artificiales (SERIAL) que crea el DW, sin significado de negocio.
La fact se une a las dimensiones con `sk_`, no con los `id_` del sistema operativo.
Por qué:
- **Independencia del origen:** si el sistema operativo cambia o reusa ids, el DW no se rompe.
- **Claves de negocio compuestas:** en el origen un tipo de evento se identifica por
  `(id_empresa, id_tipo_evento)`; en el DW es un solo entero.
- **Joins más livianos** y posibilidad de versionar dimensiones (historia) a futuro.
- Se conserva el `id_` original en la dimensión como clave de negocio para trazabilidad.
- `sk_fecha` es subrogada "legible" (20261114): se puede filtrar sin hacer join.

## `id_evento` en la tabla de hechos (dimensión degenerada)
Es el identificador del evento, pero no tiene tabla dimensión propia: no tiene
atributos descriptivos que analizar (nombre y cliente no se usan para agrupar).
Vive dentro de la fact y sirve para: (1) definir el grano (UNIQUE), (2) volver al
evento original en el sistema operativo, (3) auditar. A esto se le llama
**dimensión degenerada**.

## Medidas
| Medida | Origen | Aditiva |
|---|---|---|
| `cantidad_eventos` | constante 1 (permite `SUM`) | sí |
| `monto_total` | `eventos.monto_total` | sí |
| `monto_servicios` | `SUM(cantidad × precio_unitario)` de `eventos_servicios` | sí |
| `monto_espacios` | `SUM(precio_adicional)` de los espacios del evento | sí |
| `monto_pagado` | `SUM(monto)` de `pagos` con estado `aprobado` | sí |
| `saldo_pendiente` | `monto_total − monto_pagado` | sí |
| `invitados_estimados` | `eventos.cant_invitados_estimada` | sí |
| `invitados_confirmados` | `COUNT` de `invitados` con `confirmado` | sí |
| `cantidad_espacios` / `cantidad_servicios` | `COUNT` de las filas relacionadas | sí |
| `duracion_horas` | `hora_fin − hora_inicio` (+24 h si cruza medianoche) | sí |

Todas son aditivas: se pueden sumar por cualquier dimensión. Un **promedio**
(ticket promedio) no se guarda: se calcula `SUM(monto_total) / SUM(cantidad_eventos)`.
Por eso existe `cantidad_eventos`.

## Cómo se baja todo al nivel de un evento
Pagos, servicios, espacios e invitados son tablas "muchos por evento". Si se
hiciera `JOIN` directo, un evento con 3 servicios y 2 pagos saldría 6 veces y
las sumas quedarían infladas (**fan-out**). Por eso cada tabla se **resume
primero** con `GROUP BY id_evento` (CTE `srv`, `esp`, `pag`, `inv`) y recién
después se une con `LEFT JOIN` a `eventos`. `COALESCE(..., 0)` cubre eventos sin
servicios/pagos.

## Duración
`duracion_horas` sale de `hora_fin − hora_inicio`. Night Bar cierra de madrugada
(22:00 → 04:00), así que si `hora_fin <= hora_inicio` se suman 24 horas; si no,
daría negativa. Ej.: 22:00→04:00 = 6 h.

## Supuestos a confirmar con tu compañero
1. **Invitados (confirmado contra Supabase el 2026-11-19):** la tabla
   `public.invitados` ya existe (`id_invitado, id_empresa, id_evento, nombre,
   apellido, telefono, confirmado`). El script no la crea: solo lee `id_evento`
   y `confirmado`. El DW **no modifica nada** del esquema `public`.
2. **"Factura" = eventos `reservado`.** `consultado` es solo una consulta y
   `cancelado` no genera ingreso (columna `cuenta_como_ingreso`).
3. **"Pagado" = pagos con estado `aprobado`.**
4. `dim_fecha` cubre 2024–2032; ampliar el rango si hace falta.

## Cómo ejecutarlo (con la base ya migrada a Supabase)
1. Conectarse a la base en pgAdmin (las credenciales las tiene tu compañero).
2. Query Tool → abrir y ejecutar `01_dw_eventos.sql` (crea el esquema `dw` y carga).
   La última consulta debe mostrar `eventos_origen = filas_fact` y `total_origen = total_dw`.
3. Ejecutar `02_consultas.sql` para las preguntas de negocio.
4. Para recargar después de nuevos eventos, volver a correr `01_dw_eventos.sql`
   (borra y recrea `dw`; las tablas operativas no se tocan).
