-- =====================================================================
-- Preguntas de negocio como funciones del esquema dw  +  verificacion
-- de las respuestas contra la base operativa.
--
-- Requiere haber ejecutado antes 01_dw_eventos.sql (crea el esquema dw).
-- Es re-ejecutable (CREATE OR REPLACE).
--
-- Por que FUNCTION y no PROCEDURE: en PostgreSQL un PROCEDURE no devuelve
-- filas (se usa para ejecutar acciones, como la carga: CALL dw.sp_cargar_dw()).
-- Para "llamar a una pregunta y ver su tabla" se usa una funcion que
-- devuelve tabla: SELECT * FROM dw.p1_facturacion_empresa_mes();
--
-- Uso:
--   SELECT * FROM dw.p1_facturacion_empresa_mes();
--   SELECT * FROM dw.p2_ingresos_por_tipo_evento();
--   SELECT * FROM dw.p3a_eventos_por_dia_semana();
--   SELECT * FROM dw.p3b_eventos_por_mes();
--   SELECT * FROM dw.p4_cobrado_vs_pendiente();
--   SELECT * FROM dw.fn_control_preguntas();   -- las respuestas vs el origen
-- =====================================================================

-- 1) ¿Cuánto factura cada empresa por mes?   ("factura" = estado reservado)
CREATE OR REPLACE FUNCTION dw.p1_facturacion_empresa_mes()
RETURNS TABLE (empresa TEXT, anio_mes TEXT, facturacion NUMERIC, eventos BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT e.nombre::TEXT, f.anio_mes::TEXT,
           SUM(h.monto_total), SUM(h.cantidad_eventos)
    FROM dw.fact_eventos h
    JOIN dw.dim_empresa e        ON e.sk_empresa = h.sk_empresa
    JOIN dw.dim_fecha f          ON f.sk_fecha   = h.sk_fecha
    JOIN dw.dim_estado_evento s  ON s.sk_estado  = h.sk_estado
    WHERE s.cuenta_como_ingreso
    GROUP BY e.nombre, f.anio_mes
    ORDER BY e.nombre, f.anio_mes;
$$;

-- 2) ¿Qué tipos de evento generan más ingresos y cuál es el ticket promedio?
CREATE OR REPLACE FUNCTION dw.p2_ingresos_por_tipo_evento()
RETURNS TABLE (tipo_evento TEXT, eventos BIGINT, ingresos NUMERIC, ticket_promedio NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT t.nombre::TEXT,
           SUM(h.cantidad_eventos),
           SUM(h.monto_total),
           ROUND(SUM(h.monto_total) / SUM(h.cantidad_eventos), 2)
    FROM dw.fact_eventos h
    JOIN dw.dim_tipo_evento t   ON t.sk_tipo_evento = h.sk_tipo_evento
    JOIN dw.dim_estado_evento s ON s.sk_estado = h.sk_estado
    WHERE s.cuenta_como_ingreso
    GROUP BY t.nombre
    ORDER BY SUM(h.monto_total) DESC;
$$;

-- 3a) ¿Qué días de la semana concentran más eventos?  (excluye cancelados)
CREATE OR REPLACE FUNCTION dw.p3a_eventos_por_dia_semana()
RETURNS TABLE (dia_semana SMALLINT, nombre_dia TEXT, eventos BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT f.dia_semana, f.nombre_dia::TEXT, SUM(h.cantidad_eventos)
    FROM dw.fact_eventos h
    JOIN dw.dim_fecha f         ON f.sk_fecha = h.sk_fecha
    JOIN dw.dim_estado_evento s ON s.sk_estado = h.sk_estado
    WHERE s.estado <> 'cancelado'
    GROUP BY f.dia_semana, f.nombre_dia
    ORDER BY SUM(h.cantidad_eventos) DESC, f.dia_semana;
$$;

-- 3b) ¿Qué meses concentran más eventos?  (excluye cancelados)
CREATE OR REPLACE FUNCTION dw.p3b_eventos_por_mes()
RETURNS TABLE (mes SMALLINT, nombre_mes TEXT, eventos BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT f.mes, f.nombre_mes::TEXT, SUM(h.cantidad_eventos)
    FROM dw.fact_eventos h
    JOIN dw.dim_fecha f         ON f.sk_fecha = h.sk_fecha
    JOIN dw.dim_estado_evento s ON s.sk_estado = h.sk_estado
    WHERE s.estado <> 'cancelado'
    GROUP BY f.mes, f.nombre_mes
    ORDER BY SUM(h.cantidad_eventos) DESC, f.mes;
$$;

-- 4) ¿Cuánto le falta cobrar a cada empresa? (cobrado vs pendiente)
CREATE OR REPLACE FUNCTION dw.p4_cobrado_vs_pendiente()
RETURNS TABLE (empresa TEXT, total_a_cobrar NUMERIC, cobrado NUMERIC,
               pendiente NUMERIC, pct_cobrado NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT e.nombre::TEXT,
           SUM(h.monto_total),
           SUM(h.monto_pagado),
           SUM(h.saldo_pendiente),
           ROUND(100 * SUM(h.monto_pagado) / NULLIF(SUM(h.monto_total), 0), 1)
    FROM dw.fact_eventos h
    JOIN dw.dim_empresa e       ON e.sk_empresa = h.sk_empresa
    JOIN dw.dim_estado_evento s ON s.sk_estado  = h.sk_estado
    WHERE s.cuenta_como_ingreso
    GROUP BY e.nombre
    ORDER BY SUM(h.saldo_pendiente) DESC;
$$;

-- ---------------------------------------------------------------------
-- Verificación de las RESPUESTAS contra la base operativa (consigna 5).
-- Para cada pregunta se compara el total que devuelve la consulta del DW
-- con el mismo total calculado directo sobre public.*.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dw.fn_control_preguntas()
RETURNS TABLE (nro INT, control TEXT, valor_origen NUMERIC, valor_dw NUMERIC,
               diferencia NUMERIC, resultado TEXT)
LANGUAGE sql STABLE AS $$
WITH c (nro, control, valor_origen, valor_dw) AS (
  VALUES
  (1, 'P1 facturacion total = SUM monto_total de eventos reservados',
      (SELECT COALESCE(SUM(monto_total), 0) FROM public.eventos WHERE estado = 'reservado'),
      (SELECT COALESCE(SUM(facturacion), 0) FROM dw.p1_facturacion_empresa_mes())),
  (2, 'P1 cantidad de eventos = eventos reservados',
      (SELECT COUNT(*) FROM public.eventos WHERE estado = 'reservado')::NUMERIC,
      (SELECT COALESCE(SUM(eventos), 0) FROM dw.p1_facturacion_empresa_mes())::NUMERIC),
  (3, 'P2 ingresos por tipo = SUM monto_total de eventos reservados',
      (SELECT COALESCE(SUM(monto_total), 0) FROM public.eventos WHERE estado = 'reservado'),
      (SELECT COALESCE(SUM(ingresos), 0) FROM dw.p2_ingresos_por_tipo_evento())),
  (4, 'P2 cantidad de eventos = eventos reservados',
      (SELECT COUNT(*) FROM public.eventos WHERE estado = 'reservado')::NUMERIC,
      (SELECT COALESCE(SUM(eventos), 0) FROM dw.p2_ingresos_por_tipo_evento())::NUMERIC),
  (5, 'P3a eventos por dia de semana = eventos no cancelados',
      (SELECT COUNT(*) FROM public.eventos WHERE estado <> 'cancelado')::NUMERIC,
      (SELECT COALESCE(SUM(eventos), 0) FROM dw.p3a_eventos_por_dia_semana())::NUMERIC),
  (6, 'P3b eventos por mes = eventos no cancelados',
      (SELECT COUNT(*) FROM public.eventos WHERE estado <> 'cancelado')::NUMERIC,
      (SELECT COALESCE(SUM(eventos), 0) FROM dw.p3b_eventos_por_mes())::NUMERIC),
  (7, 'P4 total a cobrar = SUM monto_total de eventos reservados',
      (SELECT COALESCE(SUM(monto_total), 0) FROM public.eventos WHERE estado = 'reservado'),
      (SELECT COALESCE(SUM(total_a_cobrar), 0) FROM dw.p4_cobrado_vs_pendiente())),
  (8, 'P4 cobrado = pagos aprobados de eventos reservados',
      (SELECT COALESCE(SUM(p.monto), 0)
         FROM public.pagos p
         JOIN public.eventos ev ON ev.id_evento = p.id_evento
        WHERE p.estado = 'aprobado' AND ev.estado = 'reservado'),
      (SELECT COALESCE(SUM(cobrado), 0) FROM dw.p4_cobrado_vs_pendiente())),
  (9, 'P4 cobrado + pendiente = total a cobrar',
      (SELECT COALESCE(SUM(total_a_cobrar), 0) FROM dw.p4_cobrado_vs_pendiente()),
      (SELECT COALESCE(SUM(cobrado + pendiente), 0) FROM dw.p4_cobrado_vs_pendiente()))
)
SELECT nro, control, valor_origen, valor_dw, valor_dw - valor_origen,
       CASE WHEN valor_origen = valor_dw THEN 'OK' ELSE 'FALLA' END
FROM c
ORDER BY nro;
$$;
