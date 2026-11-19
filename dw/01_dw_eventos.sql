-- =====================================================================
-- DATA WAREHOUSE DE EVENTOS  (modelo estrella)  -  PostgreSQL / Supabase
-- Se ejecuta completo en pgAdmin (Query Tool). Es re-ejecutable: cada
-- corrida borra y recarga el esquema `dw` desde las tablas operativas.
--
-- GRANO: una fila de fact_eventos = un evento.
--
--                    dim_empresa
--                         |
--   dim_tipo_evento --- fact_eventos --- dim_fecha
--                         |
--                    dim_estado_evento
-- =====================================================================

-- Requisito: el esquema operativo (public) ya tiene la tabla `invitados`
-- (id_invitado, id_empresa, id_evento, nombre, apellido, telefono,
-- confirmado), verificada contra Supabase el 2026-11-19. El DW solo lee
-- public.*, no crea ni modifica nada ahí.

-- ---------------------------------------------------------------------
-- 1. Esquema limpio
-- ---------------------------------------------------------------------
DROP SCHEMA IF EXISTS dw CASCADE;
CREATE SCHEMA dw;

-- ---------------------------------------------------------------------
-- 2. Dimensiones (todas con clave subrogada sk_ + clave de negocio id_)
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_empresa (
    sk_empresa  SERIAL PRIMARY KEY,           -- subrogada: la usa la fact
    id_empresa  INT          NOT NULL UNIQUE, -- clave de negocio (origen)
    nombre      VARCHAR(150) NOT NULL,
    cuit        VARCHAR(13)  NOT NULL,
    estado      VARCHAR(10)
);

CREATE TABLE dw.dim_tipo_evento (
    sk_tipo_evento  SERIAL PRIMARY KEY,
    id_empresa      INT           NOT NULL,   -- los tipos son por empresa
    id_tipo_evento  INT           NOT NULL,
    nombre          VARCHAR(100)  NOT NULL,
    precio_base     NUMERIC(10,2) NOT NULL,
    UNIQUE (id_empresa, id_tipo_evento)
);

CREATE TABLE dw.dim_estado_evento (
    sk_estado  SERIAL PRIMARY KEY,
    estado     VARCHAR(30) NOT NULL UNIQUE,   -- consultado / reservado / cancelado
    cuenta_como_ingreso BOOLEAN NOT NULL      -- solo 'reservado' factura
);

CREATE TABLE dw.dim_fecha (
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

-- ---------------------------------------------------------------------
-- 3. Tabla de hechos
-- ---------------------------------------------------------------------
CREATE TABLE dw.fact_eventos (
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
CREATE INDEX ix_fact_empresa ON dw.fact_eventos (sk_empresa);
CREATE INDEX ix_fact_tipo    ON dw.fact_eventos (sk_tipo_evento);
CREATE INDEX ix_fact_fecha   ON dw.fact_eventos (sk_fecha);

-- ---------------------------------------------------------------------
-- 4. ETL: carga desde las tablas operativas (esquema public)
-- ---------------------------------------------------------------------
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
              'Agosto','Septiembre','Octubre','Noviembre','Diciembre'])[EXTRACT(MONTH FROM d)],
       to_char(d, 'YYYY-MM'),
       EXTRACT(DAY FROM d),
       EXTRACT(ISODOW FROM d),
       (ARRAY['Lunes','Martes','Miércoles','Jueves','Viernes','Sábado','Domingo'])[EXTRACT(ISODOW FROM d)],
       EXTRACT(ISODOW FROM d) IN (6, 7)
FROM generate_series('2024-01-01'::DATE, '2032-12-31'::DATE, '1 day') AS d;

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

-- ---------------------------------------------------------------------
-- 5. Control de calidad (el grano se cumple: 1 fila = 1 evento)
-- ---------------------------------------------------------------------
SELECT (SELECT COUNT(*) FROM public.eventos)   AS eventos_origen,
       (SELECT COUNT(*) FROM dw.fact_eventos)  AS filas_fact,
       (SELECT SUM(monto_total) FROM public.eventos)   AS total_origen,
       (SELECT SUM(monto_total) FROM dw.fact_eventos)  AS total_dw;
