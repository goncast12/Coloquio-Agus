-- =====================================================================
-- Preguntas de negocio que responde el DW  (esquema dw)
-- "Factura" = eventos con estado 'reservado' (cuenta_como_ingreso).
-- =====================================================================

-- 1) ¿Cuánto factura cada empresa por mes?
SELECT e.nombre AS empresa, f.anio_mes,
       SUM(h.monto_total) AS facturacion,
       SUM(h.cantidad_eventos) AS eventos
FROM dw.fact_eventos h
JOIN dw.dim_empresa e        ON e.sk_empresa = h.sk_empresa
JOIN dw.dim_fecha f          ON f.sk_fecha   = h.sk_fecha
JOIN dw.dim_estado_evento s  ON s.sk_estado  = h.sk_estado
WHERE s.cuenta_como_ingreso
GROUP BY e.nombre, f.anio_mes
ORDER BY e.nombre, f.anio_mes;

-- 2) ¿Qué tipos de evento generan más ingresos y cuál es el ticket promedio?
SELECT t.nombre AS tipo_evento,
       SUM(h.cantidad_eventos)                         AS eventos,
       SUM(h.monto_total)                              AS ingresos,
       ROUND(SUM(h.monto_total) / SUM(h.cantidad_eventos), 2) AS ticket_promedio
FROM dw.fact_eventos h
JOIN dw.dim_tipo_evento t   ON t.sk_tipo_evento = h.sk_tipo_evento
JOIN dw.dim_estado_evento s ON s.sk_estado = h.sk_estado
WHERE s.cuenta_como_ingreso
GROUP BY t.nombre
ORDER BY ingresos DESC;

-- 3a) ¿Qué días de la semana concentran más eventos?
SELECT f.dia_semana, f.nombre_dia, SUM(h.cantidad_eventos) AS eventos
FROM dw.fact_eventos h
JOIN dw.dim_fecha f         ON f.sk_fecha = h.sk_fecha
JOIN dw.dim_estado_evento s ON s.sk_estado = h.sk_estado
WHERE s.estado <> 'cancelado'
GROUP BY f.dia_semana, f.nombre_dia
ORDER BY eventos DESC;

-- 3b) ¿Qué meses concentran más eventos?
SELECT f.mes, f.nombre_mes, SUM(h.cantidad_eventos) AS eventos
FROM dw.fact_eventos h
JOIN dw.dim_fecha f         ON f.sk_fecha = h.sk_fecha
JOIN dw.dim_estado_evento s ON s.sk_estado = h.sk_estado
WHERE s.estado <> 'cancelado'
GROUP BY f.mes, f.nombre_mes
ORDER BY eventos DESC;

-- 4) ¿Cuánto le falta cobrar a cada empresa? (cobrado vs pendiente)
SELECT e.nombre AS empresa,
       SUM(h.monto_total)     AS total_a_cobrar,
       SUM(h.monto_pagado)    AS cobrado,
       SUM(h.saldo_pendiente) AS pendiente,
       ROUND(100 * SUM(h.monto_pagado) / NULLIF(SUM(h.monto_total), 0), 1) AS pct_cobrado
FROM dw.fact_eventos h
JOIN dw.dim_empresa e       ON e.sk_empresa = h.sk_empresa
JOIN dw.dim_estado_evento s ON s.sk_estado  = h.sk_estado
WHERE s.cuenta_como_ingreso
GROUP BY e.nombre
ORDER BY pendiente DESC;
