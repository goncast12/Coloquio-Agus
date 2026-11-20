-- =====================================================================
-- SEED DE DATOS DEMO PARA EL DW: más empresas, más eventos
--
-- Por qué existe: Supabase tenía muy pocos datos (4 eventos, 2 pagos), así
-- que las 5 consultas del DW devolvían 1 o 2 filas. Este script agrega
-- 6 empresas con ~14 eventos cada una (estados, tipos, meses y pagos
-- variados) para que los rankings, la comparación entre empresas y la
-- estacionalidad se puedan mostrar en el coloquio.
--
-- Orden: ejecutar ESTE script primero, después 01_dw_eventos.sql
-- (que recarga el DW) y por último 02_consultas.sql.
--
-- Es IDEMPOTENTE: una empresa se crea solo si su CUIT no existe, y sus
-- datos hijos se cargan solo en esa misma corrida. Correrlo dos veces no
-- duplica nada. No toca empresas existentes.
--
-- Todas las empresas demo llevan CUIT '30-5550xxxx-x', así se las puede
-- identificar y borrar (ver bloque de limpieza al final, comentado).
--
-- Los eventos son deterministas (sin random()): siempre dan lo mismo.
-- Solo usa estados que el DW reconoce: consultado / reservado / cancelado,
-- y pagos 'aprobado' (cuentan como cobrado) o 'pendiente' (no cuentan).
-- =====================================================================

BEGIN;

DO $$
DECLARE
  -- (nombre, cuit, email, factor de precio del rubro)
  v_empresas  TEXT[][] := ARRAY[
    ['Salón Las Acacias',   '30-55500001-1', 'info@lasacacias.demo',   '1.00'],
    ['Quinta El Ombú',      '30-55500002-2', 'info@elombu.demo',       '1.35'],
    ['Terraza Skyline',     '30-55500003-3', 'info@skyline.demo',      '1.60'],
    ['La Casona Eventos',   '30-55500004-4', 'info@lacasona.demo',     '0.85'],
    ['Club Náutico Lago',   '30-55500005-5', 'info@nauticolago.demo',  '1.20'],
    ['Boulevard Producciones','30-55500006-6','info@boulevard.demo',   '0.70']
  ];
  v_emp       INT;
  v_rol       INT;
  v_usr       INT;
  v_factor    NUMERIC;
  v_ev        INT;
  v_cli       INT;
  v_tipo      INT;
  v_base      NUMERIC;
  v_estado    TEXT;
  v_fecha     DATE;
  v_hi        TIME;
  v_hf        TIME;
  v_inv       INT;
  v_monto     NUMERIC;
  v_pct       NUMERIC;
  i           INT;
  e           INT;
  r           INT;
BEGIN
  FOR e IN 1 .. array_length(v_empresas, 1) LOOP

    -- Si la empresa ya existe (por CUIT o nombre) se saltea completa.
    CONTINUE WHEN EXISTS (
      SELECT 1 FROM empresas
       WHERE cuit = v_empresas[e][2] OR nombre = v_empresas[e][1]);

    v_factor := v_empresas[e][4]::NUMERIC;

    INSERT INTO empresas (nombre, cuit, email, activa, estado)
    VALUES (v_empresas[e][1], v_empresas[e][2], v_empresas[e][3], TRUE, 'activa')
    RETURNING id_empresa INTO v_emp;

    INSERT INTO roles (id_empresa, nombre) VALUES (v_emp, 'Admin')
    RETURNING id_rol INTO v_rol;

    -- Usuario sin contraseña ni Clerk (la migración 004 lo permite): solo
    -- sirve como "quien registró" el evento, no para iniciar sesión.
    INSERT INTO usuarios (id_empresa, id_rol, nombre, apellido, email)
    VALUES (v_emp, v_rol, 'Demo', 'Admin', 'demo' || v_emp || '@demo.local')
    RETURNING id_usuario INTO v_usr;

    -- 8 clientes
    FOR i IN 1 .. 8 LOOP
      INSERT INTO clientes (id_empresa, nombre, apellido, dni, telefono, email)
      VALUES (v_emp,
              (ARRAY['Lucía','Martín','Sofía','Diego','Valentina','Nicolás','Camila','Tomás'])[i],
              (ARRAY['Pérez','Gómez','Rodríguez','Fernández','López','Díaz','Romero','Sosa'])[i],
              (40000000 + v_emp * 1000 + i)::TEXT,
              '351-555' || lpad((v_emp * 10 + i)::TEXT, 4, '0'),
              'cliente' || i || '.emp' || v_emp || '@demo.local');
    END LOOP;

    -- Catálogo: 3 tipos de evento (los precios escalan con el factor del rubro)
    INSERT INTO tipos_evento (id_empresa, nombre, descripcion, precio_base) VALUES
      (v_emp, 'Cumpleaños',  'Cumpleaños y fiestas privadas', round(400000 * v_factor, -3)),
      (v_emp, 'Casamiento',  'Casamientos y civiles',         round(1500000 * v_factor, -3)),
      (v_emp, 'Corporativo', 'Eventos de empresa',            round(800000 * v_factor, -3));

    INSERT INTO espacios (id_empresa, nombre, descripcion, capacidad, precio_adicional) VALUES
      (v_emp, 'Salón principal', 'Incluido',            80, 0),
      (v_emp, 'Terraza',         'Aire libre',          40, round(140000 * v_factor, -3)),
      (v_emp, 'Lounge',          'Sector reservado',    25, round(180000 * v_factor, -3));

    INSERT INTO servicios (id_empresa, nombre, descripcion, precio) VALUES
      (v_emp, 'Barra de tragos', 'Precio por unidad', round(120000 * v_factor, -3)),
      (v_emp, 'Catering',        'Precio por unidad', round(200000 * v_factor, -3)),
      (v_emp, 'DJ',              'Precio por unidad', round(95000  * v_factor, -3));

    -- 14 eventos por empresa, repartidos en 2026 (feb a dic) con día de
    -- semana y mes variados. Reparto: ~57% reservado, ~28% consultado,
    -- ~14% cancelado.
    FOR i IN 1 .. 14 LOOP
      v_fecha  := DATE '2026-02-01' + ((i * 23 + e * 11) % 320);
      v_estado := CASE WHEN (i + e) % 7 IN (0, 3)      THEN 'cancelado'
                       WHEN (i + e) % 7 IN (1, 4)      THEN 'consultado'
                       ELSE                                 'reservado' END;
      -- Un tipo distinto según i, para que ningún tipo domine en todas las empresas
      v_tipo   := (SELECT id_tipo_evento FROM tipos_evento
                    WHERE id_empresa = v_emp
                    ORDER BY id_tipo_evento
                    OFFSET ((i + e) % 3) LIMIT 1);
      v_cli    := (SELECT id_cliente FROM clientes
                    WHERE id_empresa = v_emp
                    ORDER BY id_cliente
                    OFFSET (i % 8) LIMIT 1);
      -- Mezcla de horarios; algunos cruzan la medianoche
      v_hi     := (ARRAY['12:00','18:00','20:00','21:00','22:00'])[1 + (i % 5)]::TIME;
      v_hf     := (ARRAY['18:00','23:30','02:00','03:00','04:00'])[1 + (i % 5)]::TIME;
      v_inv    := 30 + ((i * 17 + e * 7) % 90);

      -- nombre_homenajeado: en la base real (Supabase) la columna es NOT NULL
      INSERT INTO eventos (id_empresa, id_cliente, id_tipo_evento, id_usuario, nombre,
                           nombre_homenajeado,
                           fecha_evento, hora_inicio, hora_fin,
                           cant_invitados_estimada, estado, monto_total)
      VALUES (v_emp, v_cli, v_tipo, v_usr,
              'Evento demo ' || e || '-' || i,
              (ARRAY['Lucía','Martín','Sofía','Diego','Valentina','Nicolás','Camila','Tomás'])[1 + (i % 8)],
              v_fecha, v_hi, v_hf, v_inv, v_estado, 0)
      RETURNING id_evento INTO v_ev;

      -- Espacios: cada evento usa 1 o 2 (el principal siempre)
      INSERT INTO eventos_espacios (id_empresa, id_evento, id_espacio)
      SELECT v_emp, v_ev, id_espacio FROM espacios
       WHERE id_empresa = v_emp
         AND (nombre = 'Salón principal'
              OR (i % 3 = 0 AND nombre = 'Terraza')
              OR (i % 4 = 0 AND nombre = 'Lounge'));

      -- Servicios: según i, 0 a 3 servicios con cantidades distintas
      INSERT INTO eventos_servicios (id_empresa, id_evento, id_servicio, cantidad, precio_unitario)
      SELECT v_emp, v_ev, s.id_servicio, 1 + ((i + s.id_servicio) % 3), s.precio
        FROM servicios s
       WHERE s.id_empresa = v_emp
         AND (   (i % 4 = 1 AND s.nombre = 'DJ')
              OR (i % 4 = 2 AND s.nombre IN ('DJ', 'Catering'))
              OR (i % 4 = 3));                                 -- i % 4 = 0: sin servicios

      -- monto_total = precio base + espacios + servicios (así es coherente)
      SELECT t.precio_base
             + COALESCE((SELECT SUM(es.precio_adicional)
                           FROM eventos_espacios ee
                           JOIN espacios es USING (id_empresa, id_espacio)
                          WHERE ee.id_evento = v_ev), 0)
             + COALESCE((SELECT SUM(cantidad * precio_unitario)
                           FROM eventos_servicios WHERE id_evento = v_ev), 0)
        INTO v_monto
        FROM tipos_evento t WHERE t.id_tipo_evento = v_tipo;

      UPDATE eventos SET monto_total = v_monto WHERE id_evento = v_ev;

      -- Pagos
      IF v_estado = 'reservado' THEN
        -- Seña del 30%
        INSERT INTO pagos (id_empresa, id_evento, id_usuario, monto, metodo_pago, concepto, estado, fecha_pago)
        VALUES (v_emp, v_ev, v_usr, round(v_monto * 0.30, 2), 'transferencia', 'seña', 'aprobado',
                v_fecha - 30);
        -- Algunos pagan el resto (i par), otros solo una cuota parcial (i múltiplo de 3),
        -- el resto queda con saldo pendiente.
        IF i % 2 = 0 THEN
          INSERT INTO pagos (id_empresa, id_evento, id_usuario, monto, metodo_pago, concepto, estado, fecha_pago)
          VALUES (v_emp, v_ev, v_usr, v_monto - round(v_monto * 0.30, 2), 'efectivo', 'saldo', 'aprobado',
                  v_fecha - 2);
        ELSIF i % 3 = 0 THEN
          INSERT INTO pagos (id_empresa, id_evento, id_usuario, monto, metodo_pago, concepto, estado, fecha_pago)
          VALUES (v_emp, v_ev, v_usr, round(v_monto * 0.25, 2), 'tarjeta', 'cuota', 'aprobado',
                  v_fecha - 10);
        END IF;
        -- Un pago pendiente de aprobación que NO debe contar como cobrado
        IF i % 5 = 0 THEN
          INSERT INTO pagos (id_empresa, id_evento, id_usuario, monto, metodo_pago, concepto, estado, fecha_pago)
          VALUES (v_emp, v_ev, v_usr, round(v_monto * 0.10, 2), 'transferencia', 'cuota', 'pendiente',
                  v_fecha - 5);
        END IF;
      ELSIF v_estado = 'cancelado' AND i % 2 = 0 THEN
        -- Cancelado que dejó la seña cobrada
        INSERT INTO pagos (id_empresa, id_evento, id_usuario, monto, metodo_pago, concepto, estado, fecha_pago)
        VALUES (v_emp, v_ev, v_usr, round(v_monto * 0.20, 2), 'transferencia', 'seña', 'aprobado',
                v_fecha - 40);
      END IF;

      -- Invitados: 3 a 5 por evento, con una parte confirmada
      FOR r IN 1 .. 3 + (i % 3) LOOP
        INSERT INTO invitados (id_empresa, id_evento, nombre, apellido, telefono, confirmado)
        VALUES (v_emp, v_ev, 'Invitado' || r, 'Demo', NULL, (r + i) % 2 = 0);
      END LOOP;
    END LOOP;
  END LOOP;
END $$;

COMMIT;

-- Control rápido: eventos y facturación por empresa tras la carga.
SELECT em.nombre,
       COUNT(ev.id_evento)                                    AS eventos,
       COUNT(*) FILTER (WHERE ev.estado = 'reservado')       AS reservados,
       SUM(ev.monto_total) FILTER (WHERE ev.estado = 'reservado') AS monto_reservado
  FROM empresas em
  LEFT JOIN eventos ev ON ev.id_empresa = em.id_empresa
 GROUP BY em.nombre
 ORDER BY em.nombre;

-- ---------------------------------------------------------------------
-- LIMPIEZA (opcional): borra SOLO las empresas demo y sus datos. Hay que
-- borrar los eventos antes que los usuarios (pagos y eventos referencian
-- usuarios sin ON DELETE CASCADE). Descomentar para usar.
-- ---------------------------------------------------------------------
-- BEGIN;
-- DELETE FROM eventos
--  WHERE id_empresa IN (SELECT id_empresa FROM empresas WHERE cuit LIKE '30-5550%');
-- DELETE FROM empresas WHERE cuit LIKE '30-5550%';
-- COMMIT;
