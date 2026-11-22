-- ============================================================================
-- CONSULTAS DE ORIGEN PARA LA CAPA GOLD  (silver -> gold)
-- Base: dw_hospital   |   Linked service: sql_dw_hospital
--
-- Cada consulta es un SELECT unico (sin GO, CTE ni ORDER BY) para pegarla como
-- "Query" en el source de un Mapping Data Flow, igual que la consulta de
-- ejemplo SELECT DISTINCT ... FROM silver.<tabla>.
--
-- ORDEN DE CARGA (las facts leen las dimensiones ya cargadas en gold):
--   1) dim_fecha  2) dim_paciente  3) dim_departamento
--   4) dim_diagnostico  5) dim_servicio_cargo
--   6) fact_admisiones  7) fact_facturacion
--
-- Las columnas de salida llevan el mismo nombre que las columnas de destino de
-- 3_gold.sql; las claves surrogate (IDENTITY) no se incluyen: las genera SQL.
--
-- Filas esperadas segun los datos actuales de silver:
--   dim_fecha 1270 | dim_paciente 1015 | dim_departamento 7
--   dim_diagnostico 51 | dim_servicio_cargo 28
--   fact_admisiones 1689 | fact_facturacion 1898
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. gold.dim_fecha  (dataset: gold_dim_fecha)
--    Fechas distintas usadas por las facts: ingreso, alta y pago.
--    dia_semana: 1 = Lunes ... 7 = Domingo (no depende de DATEFIRST;
--    el 1900-01-01 fue lunes).
-- ----------------------------------------------------------------------------
SELECT
    CAST(CONVERT(CHAR(8), f.fecha, 112) AS INT)                          AS fecha_key,
    f.fecha                                                              AS fecha_completa,
    CAST(YEAR(f.fecha) AS SMALLINT)                                      AS anio,
    CAST(DATEPART(QUARTER, f.fecha) AS TINYINT)                          AS trimestre,
    CONCAT('T', DATEPART(QUARTER, f.fecha))                              AS trimestre_nombre,
    CAST(MONTH(f.fecha) AS TINYINT)                                      AS mes,
    CHOOSE(MONTH(f.fecha), 'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
                           'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre') AS mes_nombre,
    CHOOSE(MONTH(f.fecha), 'Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun',
                           'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic') AS mes_corto,
    CAST(DATEPART(ISO_WEEK, f.fecha) AS TINYINT)                         AS semana_anio,
    CAST(DAY(f.fecha) AS TINYINT)                                        AS dia_mes,
    CAST(DATEDIFF(DAY, '19000101', f.fecha) % 7 + 1 AS TINYINT)          AS dia_semana,
    CHOOSE(DATEDIFF(DAY, '19000101', f.fecha) % 7 + 1,
           'Lunes', 'Martes', 'Miercoles', 'Jueves', 'Viernes', 'Sabado', 'Domingo') AS dia_nombre,
    CAST(CASE WHEN DATEDIFF(DAY, '19000101', f.fecha) % 7 + 1 IN (6, 7) THEN 1 ELSE 0 END AS BIT) AS es_fin_de_semana
FROM (
    SELECT a.admission_date AS fecha FROM silver.admissions a
    UNION
    SELECT a.discharge_date FROM silver.admissions a WHERE a.discharge_date IS NOT NULL
    UNION
    SELECT b.payment_date FROM silver.billing b WHERE b.payment_date IS NOT NULL
) f;


-- ----------------------------------------------------------------------------
-- 2. gold.dim_paciente  (dataset: gold_dim_paciente)
--    genero estandarizado a Masculino / Femenino / Otro.
--    rango_etario calculado a la fecha actual: 0-18, 19-35, 36-60, 60+.
--    Columnas NOT NULL en gold: proveedor_seguro nulo -> 'Desconocido'.
-- ----------------------------------------------------------------------------
SELECT
    p.patient_id                                    AS patient_id_bk,
    p.full_name                                     AS nombre_completo,
    CASE p.gender
        WHEN 'Male'   THEN 'Masculino'
        WHEN 'Female' THEN 'Femenino'
        ELSE 'Otro'
    END                                             AS genero,
    p.date_of_birth                                 AS fecha_nacimiento,
    CASE
        WHEN p.date_of_birth IS NULL THEN NULL
        WHEN x.edad <= 18 THEN '0-18'
        WHEN x.edad <= 35 THEN '19-35'
        WHEN x.edad <= 60 THEN '36-60'
        ELSE '60+'
    END                                             AS rango_etario,
    p.email                                         AS correo_electronico,
    p.address                                       AS direccion,
    COALESCE(p.insurance_provider, 'Desconocido')   AS proveedor_seguro
FROM silver.patients p
CROSS APPLY (
    SELECT DATEDIFF(YEAR, p.date_of_birth, GETDATE())
           - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, p.date_of_birth, GETDATE()), p.date_of_birth) > GETDATE()
                  THEN 1 ELSE 0 END AS edad
) x;


-- ----------------------------------------------------------------------------
-- 3. gold.dim_departamento  (dataset: gold_dim_departamento)
-- ----------------------------------------------------------------------------
SELECT DISTINCT
    a.department AS nombre_departamento
FROM silver.admissions a;


-- ----------------------------------------------------------------------------
-- 4. gold.dim_diagnostico  (dataset: gold_dim_diagnostico)
--    Grano: codigo ICD + severidad. La descripcion de silver es texto libre
--    distinto en cada fila, por lo que se usa el nombre estandar del codigo
--    ICD-10 y, si aparece un codigo nuevo, una descripcion de muestra (MIN).
--    Se agrega la fila 'N/A' para las admisiones sin diagnostico, porque
--    fact_admisiones.diagnostico_key es NOT NULL.
-- ----------------------------------------------------------------------------
SELECT
    d.icd_code                                          AS codigo_icd,
    COALESCE(
        CASE d.icd_code
            WHEN 'E11.9'    THEN 'Diabetes mellitus tipo 2 sin complicaciones'
            WHEN 'I10'      THEN 'Hipertension esencial'
            WHEN 'J45.909'  THEN 'Asma no especificada'
            WHEN 'K21.9'    THEN 'Enfermedad por reflujo gastroesofagico'
            WHEN 'M54.5'    THEN 'Dolor lumbar bajo'
            WHEN 'N39.0'    THEN 'Infeccion de vias urinarias'
            WHEN 'R51'      THEN 'Cefalea'
            WHEN 'F32.9'    THEN 'Trastorno depresivo mayor, episodio unico'
            WHEN 'C50.911'  THEN 'Neoplasia maligna de mama'
            WHEN 'S72.001A' THEN 'Fractura de cuello de femur, encuentro inicial'
        END,
        MIN(d.diagnosis_description))                   AS descripcion_patologia,
    COALESCE(d.severity, 'Desconocido')                 AS nivel_severidad
FROM silver.diagnoses d
GROUP BY d.icd_code, COALESCE(d.severity, 'Desconocido')
UNION ALL
SELECT 'N/A', 'Sin diagnostico registrado', 'Desconocido';


-- ----------------------------------------------------------------------------
-- 5. gold.dim_servicio_cargo  (dataset: gold_dim_servicio_cargo)
-- ----------------------------------------------------------------------------
SELECT DISTINCT
    b.charge_type    AS tipo_cargo,
    b.payment_status AS estado_pago
FROM silver.billing b;


-- ----------------------------------------------------------------------------
-- 6. gold.fact_admisiones  (dataset: gold_dim_admisiones -> gold.fact_admisiones)
--    Una fila por admision. El diagnostico es el principal (menor
--    diagnosis_id de la admision); sin diagnostico -> fila 'N/A'.
--    fecha_alta_key y dias_estancia quedan NULL si no hay alta.
-- ----------------------------------------------------------------------------
SELECT
    a.admission_id                                              AS admission_id_bk,
    p.paciente_key                                              AS paciente_key,
    dep.departamento_key                                        AS departamento_key,
    dg.diagnostico_key                                          AS diagnostico_key,
    CAST(CONVERT(CHAR(8), a.admission_date, 112) AS INT)        AS fecha_ingreso_key,
    CAST(CONVERT(CHAR(8), a.discharge_date, 112) AS INT)        AS fecha_alta_key,
    a.attending_doctor_id                                       AS medico_id,
    DATEDIFF(DAY, a.admission_date, a.discharge_date)           AS dias_estancia,
    1                                                           AS conteo_admisiones
FROM silver.admissions a
JOIN gold.dim_paciente p
    ON p.patient_id_bk = a.patient_id
JOIN gold.dim_departamento dep
    ON dep.nombre_departamento = a.department
LEFT JOIN (
    SELECT d.admission_id,
           d.icd_code,
           COALESCE(d.severity, 'Desconocido') AS severity,
           ROW_NUMBER() OVER (PARTITION BY d.admission_id ORDER BY d.diagnosis_id) AS rn
    FROM silver.diagnoses d
) dp
    ON dp.admission_id = a.admission_id AND dp.rn = 1
JOIN gold.dim_diagnostico dg
    ON dg.codigo_icd = COALESCE(dp.icd_code, 'N/A')
   AND dg.nivel_severidad = COALESCE(dp.severity, 'Desconocido');


-- ----------------------------------------------------------------------------
-- 7. gold.fact_facturacion  (dataset: gold_dim_facturacion -> gold.fact_facturacion)
--    Una fila por cargo. paciente y departamento vienen de la admision.
--    fecha_pago_key queda NULL si no hay fecha de pago.
-- ----------------------------------------------------------------------------
SELECT
    b.billing_id                                                AS billing_id_bk,
    b.admission_id                                              AS admission_id_bk,
    p.paciente_key                                              AS paciente_key,
    dep.departamento_key                                        AS departamento_key,
    sc.servicio_cargo_key                                       AS servicio_cargo_key,
    CAST(CONVERT(CHAR(8), b.payment_date, 112) AS INT)          AS fecha_pago_key,
    b.amount                                                    AS monto_facturado,
    1                                                           AS conteo_transacciones
FROM silver.billing b
JOIN silver.admissions a
    ON a.admission_id = b.admission_id
JOIN gold.dim_paciente p
    ON p.patient_id_bk = a.patient_id
JOIN gold.dim_departamento dep
    ON dep.nombre_departamento = a.department
JOIN gold.dim_servicio_cargo sc
    ON sc.tipo_cargo = b.charge_type
   AND sc.estado_pago = b.payment_status;
