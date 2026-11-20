-- =====================================================================
-- DATA WAREHOUSE DE EVENTOS  (modelo estrella)  -  PostgreSQL / Supabase
--
-- ESTRUCTURA DEL SCRIPT
--   Parte 1: crea el esquema `dw` y las tablas (una sola vez; es seguro
--            volver a correrla, no borra nada).
--   Parte 2: crea la funcion de control dw.fn_control_totales() (consigna 5)
--            y el procedimiento almacenado dw.sp_cargar_dw() (consigna 6).
--   Parte 3: ejecuta la carga con CALL y muestra los controles.
--
-- Para actualizar el DW en cualquier momento basta con:
--     CALL dw.sp_cargar_dw();
-- Para ver los controles contra la base operativa cuando se quiera:
--     SELECT * FROM dw.fn_control_totales();
--
-- GRANO: una fila de fact_eventos = un evento.
--
--                    dim_empresa
--                         |
--   dim_tipo_evento --- fact_eventos --- dim_fecha
--                         |
--                    dim_estado_evento
--
-- Requisito: el esquema operativo (public) ya tiene la tabla `invitados`
-- (id_invitado, id_empresa, id_evento, nombre, apellido, telefono,
-- confirmado). El DW solo lee public.*, no crea ni modifica nada ahi.
--
-- Nota: CREATE TABLE IF NOT EXISTS no modifica tablas ya creadas. Si se
-- cambia el diseno del DW, borrar antes el esquema: DROP SCHEMA dw CASCADE;
-- =====================================================================

-- =====================================================================
-- PARTE 1. Esquema y tablas (se crean una sola vez)
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS dw;

CREATE TABLE IF NOT EXISTS dw.dim_empresa (
    sk_empresa  SERIAL PRIMARY KEY,           -- subrogada: la usa la fact
    id_empresa  INT          NOT NULL UNIQUE, -- clave de negocio (origen)
    nombre      VARCHAR(150) NOT NULL,
    cuit        VARCHAR(13)  NOT NULL,
    estado      VARCHAR(10)
);

CREATE TABLE IF NOT EXISTS dw.dim_tipo_evento (
    sk_tipo_evento  SERIAL PRIMARY KEY,
    id_empresa      INT           NOT NULL,   -- los tipos son por empresa
    id_tipo_evento  INT           NOT NULL,
    nombre          VARCHAR(100)  NOT NULL,
    precio_base     NUMERIC(10,2) NOT NULL,
    UNIQUE (id_empresa, id_tipo_evento)
);

CREATE TABLE IF NOT EXISTS dw.dim_estado_evento (
    sk_estado  SERIAL PRIMARY KEY,
    estado     VARCHAR(30) NOT NULL UNIQUE,   -- consultado / reservado / cancelado
    cuenta_como_ingreso BOOLEAN NOT NULL      -- solo 'reservado' factura
);

CREATE TABLE IF NOT EXISTS dw.dim_fecha (
    sk_fecha         INT PRIMARY KEY,         -- YYYYMMDD (subrogada legible)
    fecha            DATE        NOT NULL UNIQUE,
    anio             SMALLINT    NOT NULL,
    trimestre        SMALLINT    NOT NULL,
    mes              SMALLINT    NOT NULL,    -- 1..12
    nombre_mes       VARCHAR(12) NOT NULL,
    anio_mes         CHAR(7)     NOT NULL,    -- '2026-11' (ordena bien)
    dia_mes          SMALLINT    NOT NULL,
    dia_semana       SMALLINT    NOT NULL,    -- 1=lunes .. 7=domingo (ISO)
    nombre_dia       VARCHAR(12) NOT NULL,
    es_fin_de_semana BOOLEAN     NOT NULL
);

CREATE TABLE IF NOT EXISTS dw.fact_eventos (
    sk_fact_evento  SERIAL PRIMARY KEY,
    -- Dimension degenerada: el id del evento viaja en la fact para
    -- poder volver al origen (no tiene tabla dimension propia).
    id_evento       INT NOT NULL UNIQUE,      -- UNIQUE = garantiza el grano
    -- Claves subrogadas a las dimensiones
    sk_empresa      INT NOT NULL REFERENCES dw.dim_empresa (sk_empresa),
    sk_tipo_evento  INT NOT NULL REFERENCES dw.dim_tipo_evento (sk_tipo_evento),
    sk_fecha        INT NOT NULL REFERENCES dw.dim_fecha (sk_fecha),
    sk_estado       INT NOT NULL REFERENCES dw.dim_estado_evento (sk_estado),
    -- Medidas
    cantidad_eventos       INT           NOT NULL DEFAULT 1,  -- siempre 1: permite SUM()
    monto_total            NUMERIC(12,2) NOT NULL,
    monto_servicios        NUMERIC(12,2) NOT NULL,
    monto_espacios         NUMERIC(12,2) NOT NULL,
    monto_pagado           NUMERIC(12,2) NOT NULL,
    saldo_pendiente        NUMERIC(12,2) NOT NULL,            -- monto_total - monto_pagado
    invitados_estimados    INT           NOT NULL,
    invitados_confirmados  INT           NOT NULL,
    cantidad_espacios      INT           NOT NULL,
    cantidad_servicios     INT           NOT NULL,
    duracion_horas         NUMERIC(5,2)  NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_fact_empresa ON dw.fact_eventos (sk_empresa);
CREATE INDEX IF NOT EXISTS ix_fact_tipo    ON dw.fact_eventos (sk_tipo_evento);
CREATE INDEX IF NOT EXISTS ix_fact_fecha   ON dw.fact_eventos (sk_fecha);

-- =====================================================================
-- PARTE 2. Verificacion (consigna 5) y procedimiento de carga (consigna 6)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 2.1 Control de totales contra la base operativa
--     Cada fila compara un valor calculado DIRECTO sobre public.* contra
--     el mismo valor leido del DW. Resultado OK solo si son iguales.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dw.fn_control_totales()
RETURNS TABLE (nro INT, control TEXT, valor_origen NUMERIC, valor_dw NUMERIC,
               diferencia NUMERIC, resultado TEXT)
LANGUAGE sql STABLE AS $$
WITH c (nro, control, valor_origen, valor_dw) AS (
  VALUES
  -- Dimensiones: misma cantidad de filas que el origen
  (1, 'Empresas (filas)',
      (SELECT COUNT(*) FROM public.empresas)::NUMERIC,
      (SELECT COUNT(*) FROM dw.dim_empresa)::NUMERIC),
  (2, 'Tipos de evento (filas)',
      (SELECT COUNT(*) FROM public.tipos_evento)::NUMERIC,
      (SELECT COUNT(*) FROM dw.dim_tipo_evento)::NUMERIC),

  -- Grano: un evento = una fila de la fact
  (3, 'Eventos = filas de la fact (grano)',
      (SELECT COUNT(*) FROM public.eventos)::NUMERIC,
      (SELECT COUNT(*) FROM dw.fact_eventos)::NUMERIC),
  (4, 'Eventos distintos en la fact (sin duplicados)',
      (SELECT COUNT(*) FROM public.eventos)::NUMERIC,
      (SELECT COUNT(DISTINCT id_evento) FROM dw.fact_eventos)::NUMERIC),

  -- Eventos por estado (detecta estados que el DW no reconoce)
  (5, 'Eventos consultado',
      (SELECT COUNT(*) FROM public.eventos WHERE estado = 'consultado')::NUMERIC,
      (SELECT COUNT(*) FROM dw.fact_eventos f JOIN dw.dim_estado_evento s USING (sk_estado)
        WHERE s.estado = 'consultado')::NUMERIC),
  (6, 'Eventos reservado',
      (SELECT COUNT(*) FROM public.eventos WHERE estado = 'reservado')::NUMERIC,
      (SELECT COUNT(*) FROM dw.fact_eventos f JOIN dw.dim_estado_evento s USING (sk_estado)
        WHERE s.estado = 'reservado')::NUMERIC),
  (7, 'Eventos cancelado',
      (SELECT COUNT(*) FROM public.eventos WHERE estado = 'cancelado')::NUMERIC,
      (SELECT COUNT(*) FROM dw.fact_eventos f JOIN dw.dim_estado_evento s USING (sk_estado)
        WHERE s.estado = 'cancelado')::NUMERIC),

  -- Medidas en dinero: la suma del DW debe igualar la suma del origen
  (8, 'SUM monto_total',
      (SELECT COALESCE(SUM(monto_total), 0) FROM public.eventos),
      (SELECT COALESCE(SUM(monto_total), 0) FROM dw.fact_eventos)),
  (9, 'SUM monto_servicios (cantidad x precio_unitario)',
      (SELECT COALESCE(SUM(cantidad * precio_unitario), 0) FROM public.eventos_servicios),
      (SELECT COALESCE(SUM(monto_servicios), 0) FROM dw.fact_eventos)),
  (10, 'SUM monto_espacios (precio_adicional)',
      (SELECT COALESCE(SUM(e.precio_adicional), 0)
         FROM public.eventos_espacios ee
         JOIN public.espacios e ON e.id_empresa = ee.id_empresa AND e.id_espacio = ee.id_espacio),
      (SELECT COALESCE(SUM(monto_espacios), 0) FROM dw.fact_eventos)),
  (11, 'SUM monto_pagado (pagos aprobados)',
      (SELECT COALESCE(SUM(monto), 0) FROM public.pagos WHERE estado = 'aprobado'),
      (SELECT COALESCE(SUM(monto_pagado), 0) FROM dw.fact_eventos)),
  (12, 'SUM saldo_pendiente (monto_total - aprobado)',
      (SELECT COALESCE(SUM(monto_total), 0) FROM public.eventos)
        - (SELECT COALESCE(SUM(monto), 0) FROM public.pagos WHERE estado = 'aprobado'),
      (SELECT COALESCE(SUM(saldo_pendiente), 0) FROM dw.fact_eventos)),

  -- Medidas en cantidades
  (13, 'SUM cantidad_servicios',
      (SELECT COUNT(*) FROM public.eventos_servicios)::NUMERIC,
      (SELECT COALESCE(SUM(cantidad_servicios), 0) FROM dw.fact_eventos)::NUMERIC),
  (14, 'SUM cantidad_espacios',
      (SELECT COUNT(*) FROM public.eventos_espacios)::NUMERIC,
      (SELECT COALESCE(SUM(cantidad_espacios), 0) FROM dw.fact_eventos)::NUMERIC),
  (15, 'SUM invitados_estimados',
      (SELECT COALESCE(SUM(cant_invitados_estimada), 0) FROM public.eventos)::NUMERIC,
      (SELECT COALESCE(SUM(invitados_estimados), 0) FROM dw.fact_eventos)::NUMERIC),
  (16, 'SUM invitados_confirmados',
      (SELECT COUNT(*) FROM public.invitados WHERE confirmado)::NUMERIC,
      (SELECT COALESCE(SUM(invitados_confirmados), 0) FROM dw.fact_eventos)::NUMERIC),
  (17, 'Eventos con duracion_horas fuera de (0, 24] (debe ser 0)',
      0::NUMERIC,
      (SELECT COUNT(*) FROM dw.fact_eventos
        WHERE duracion_horas <= 0 OR duracion_horas > 24)::NUMERIC),

  -- Por empresa: cuantas empresas tienen un monto distinto al origen
  (18, 'Empresas con monto_total distinto al origen (debe ser 0)',
      0::NUMERIC,
      (SELECT COUNT(*) FROM (
          SELECT id_empresa, SUM(monto_total) AS m FROM public.eventos GROUP BY id_empresa) o
        FULL JOIN (
          SELECT de.id_empresa, SUM(f.monto_total) AS m
            FROM dw.fact_eventos f JOIN dw.dim_empresa de USING (sk_empresa)
           GROUP BY de.id_empresa) d USING (id_empresa)
        WHERE o.m IS DISTINCT FROM d.m)::NUMERIC),
  (19, 'Empresas con monto_pagado distinto al origen (debe ser 0)',
      0::NUMERIC,
      (SELECT COUNT(*) FROM (
          SELECT id_empresa, SUM(monto) AS m FROM public.pagos
           WHERE estado = 'aprobado' GROUP BY id_empresa) o
        FULL JOIN (
          SELECT de.id_empresa, SUM(NULLIF(f.monto_pagado, 0)) AS m
            FROM dw.fact_eventos f JOIN dw.dim_empresa de USING (sk_empresa)
           GROUP BY de.id_empresa) d USING (id_empresa)
        WHERE o.m IS DISTINCT FROM d.m)::NUMERIC),
  -- Por mes: cuantos meses tienen un monto distinto al origen
  (20, 'Meses con monto_total distinto al origen (debe ser 0)',
      0::NUMERIC,
      (SELECT COUNT(*) FROM (
          SELECT to_char(fecha_evento, 'YYYY-MM') AS anio_mes, SUM(monto_total) AS m
            FROM public.eventos GROUP BY 1) o
        FULL JOIN (
          SELECT fe.anio_mes, SUM(f.monto_total) AS m
            FROM dw.fact_eventos f JOIN dw.dim_fecha fe USING (sk_fecha)
           GROUP BY fe.anio_mes) d USING (anio_mes)
        WHERE o.m IS DISTINCT FROM d.m)::NUMERIC)
)
SELECT nro, control, valor_origen, valor_dw, valor_dw - valor_origen,
       CASE WHEN valor_origen = valor_dw THEN 'OK' ELSE 'FALLA' END
FROM c
ORDER BY nro;
$$;


-- ---------------------------------------------------------------------
-- 2.2 Procedimiento almacenado de carga
--     Carga TODO el DW desde public.* con INSERT ... SELECT. Orden:
--     primero dimensiones, despues hechos. Al final corre los 20 controles:
--     si alguno da FALLA lanza una excepcion y la transaccion entera se
--     revierte (el DW queda como estaba antes de la corrida).
--     Es repetible: CALL dw.sp_cargar_dw();
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE dw.sp_cargar_dw()
LANGUAGE plpgsql AS $$
DECLARE
    v_fallas  INT;
    v_detalle TEXT;
BEGIN
    -- Vaciar (full refresh). Un solo TRUNCATE porque la fact referencia a
    -- las dimensiones; RESTART IDENTITY reinicia las claves sk_.
    TRUNCATE dw.fact_eventos, dw.dim_fecha, dw.dim_estado_evento,
             dw.dim_tipo_evento, dw.dim_empresa RESTART IDENTITY;

    -- 5.1 DIMENSIONES ---------------------------------------------------
    INSERT INTO dw.dim_empresa (id_empresa, nombre, cuit, estado)
    SELECT id_empresa, nombre, cuit, estado FROM public.empresas;

    INSERT INTO dw.dim_tipo_evento (id_empresa, id_tipo_evento, nombre, precio_base)
    SELECT id_empresa, id_tipo_evento, nombre, precio_base FROM public.tipos_evento;

    INSERT INTO dw.dim_estado_evento (estado, cuenta_como_ingreso) VALUES
        ('consultado', FALSE),
        ('reservado',  TRUE),
        ('cancelado',  FALSE);

    INSERT INTO dw.dim_fecha
    SELECT to_char(d, 'YYYYMMDD')::INT,
           d::DATE,
           EXTRACT(YEAR FROM d),
           EXTRACT(QUARTER FROM d),
           EXTRACT(MONTH FROM d),
           (ARRAY['Enero','Febrero','Marzo','Abril','Mayo','Junio','Julio',
                  'Agosto','Septiembre','Octubre','Noviembre','Diciembre'])[EXTRACT(MONTH FROM d)::INT],
           to_char(d, 'YYYY-MM'),
           EXTRACT(DAY FROM d),
           EXTRACT(ISODOW FROM d),
           (ARRAY['Lunes','Martes','Miércoles','Jueves','Viernes','Sábado','Domingo'])[EXTRACT(ISODOW FROM d)::INT],
           EXTRACT(ISODOW FROM d) IN (6, 7)
    FROM generate_series('2024-01-01'::DATE, '2032-12-31'::DATE, '1 day') AS d;

    -- 5.2 HECHOS --------------------------------------------------------
    -- Cada tabla relacionada (servicios, espacios, pagos, invitados) se
    -- resume ANTES en un CTE con un GROUP BY id_evento. Si se hiciera JOIN
    -- directo, un evento con 3 servicios y 2 pagos aparecería 6 veces y las
    -- sumas saldrían infladas. Así queda exactamente 1 fila por evento.
    INSERT INTO dw.fact_eventos (
        id_evento, sk_empresa, sk_tipo_evento, sk_fecha, sk_estado,
        cantidad_eventos, monto_total, monto_servicios, monto_espacios,
        monto_pagado, saldo_pendiente, invitados_estimados, invitados_confirmados,
        cantidad_espacios, cantidad_servicios, duracion_horas)
    WITH srv AS (
        SELECT id_evento,
               COUNT(*)                          AS cantidad_servicios,
               SUM(cantidad * precio_unitario)   AS monto_servicios
        FROM public.eventos_servicios GROUP BY id_evento
    ), esp AS (
        SELECT ee.id_evento,
               COUNT(*)                          AS cantidad_espacios,
               SUM(e.precio_adicional)           AS monto_espacios
        FROM public.eventos_espacios ee
        JOIN public.espacios e USING (id_empresa, id_espacio)
        GROUP BY ee.id_evento
    ), pag AS (
        SELECT id_evento, SUM(monto) AS monto_pagado
        FROM public.pagos
        WHERE estado = 'aprobado'               -- solo lo efectivamente cobrado
        GROUP BY id_evento
    ), inv AS (
        SELECT id_evento, COUNT(*) FILTER (WHERE confirmado) AS confirmados
        FROM public.invitados GROUP BY id_evento
    )
    SELECT ev.id_evento,
           de.sk_empresa,
           dt.sk_tipo_evento,
           to_char(ev.fecha_evento, 'YYYYMMDD')::INT,
           ds.sk_estado,
           1,
           ev.monto_total,
           COALESCE(srv.monto_servicios, 0),
           COALESCE(esp.monto_espacios, 0),
           COALESCE(pag.monto_pagado, 0),
           ev.monto_total - COALESCE(pag.monto_pagado, 0),
           ev.cant_invitados_estimada,
           COALESCE(inv.confirmados, 0),
           COALESCE(esp.cantidad_espacios, 0),
           COALESCE(srv.cantidad_servicios, 0),
           -- Night Bar cierra de madrugada: si la hora de fin es menor o igual
           -- a la de inicio el evento cruza medianoche (+24 h).
           ROUND(EXTRACT(EPOCH FROM
                 (ev.hora_fin - ev.hora_inicio)
                 + CASE WHEN ev.hora_fin <= ev.hora_inicio THEN INTERVAL '24 hours'
                        ELSE INTERVAL '0' END) / 3600.0, 2)
    FROM public.eventos ev
    JOIN dw.dim_empresa     de ON de.id_empresa = ev.id_empresa
    JOIN dw.dim_tipo_evento dt ON dt.id_empresa = ev.id_empresa AND dt.id_tipo_evento = ev.id_tipo_evento
    JOIN dw.dim_estado_evento ds ON ds.estado = ev.estado
    LEFT JOIN srv ON srv.id_evento = ev.id_evento
    LEFT JOIN esp ON esp.id_evento = ev.id_evento
    LEFT JOIN pag ON pag.id_evento = ev.id_evento
    LEFT JOIN inv ON inv.id_evento = ev.id_evento;

    -- 5.3 VERIFICACION --------------------------------------------------
    SELECT COUNT(*),
           string_agg(control || ' (origen=' || valor_origen || ', dw=' || valor_dw || ')', '; ')
      INTO v_fallas, v_detalle
      FROM dw.fn_control_totales()
     WHERE resultado = 'FALLA';

    IF v_fallas > 0 THEN
        RAISE EXCEPTION 'Carga revertida: fallaron % control(es): %', v_fallas, v_detalle;
    END IF;

    RAISE NOTICE 'DW cargado y verificado: % eventos, todos los controles OK.',
                 (SELECT COUNT(*) FROM dw.fact_eventos);
END;
$$;


-- =====================================================================
-- PARTE 3. Ejecutar la carga y mostrar los controles (todos deben dar OK)
-- =====================================================================
CALL dw.sp_cargar_dw();

SELECT * FROM dw.fn_control_totales();

-- ---------------------------------------------------------------------
-- OPCIONAL: programar la recarga automatica (Supabase tiene pg_cron).
-- Primero habilitar la extension en Database > Extensions > pg_cron.
-- Ejemplo: todos los dias a las 03:00.
-- ---------------------------------------------------------------------
-- SELECT cron.schedule('recarga-dw', '0 3 * * *', 'CALL dw.sp_cargar_dw()');
