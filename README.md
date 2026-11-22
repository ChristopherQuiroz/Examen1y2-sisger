# Hospital DW – Silver + Gold (Azure Data Factory + Terraform)

Repositorio nuevo basado en la lógica del proyecto antiguo (`tarea2-sisger`) y en la plantilla Terraform del hospital.
Cubre **bronze → silver** (dataflows y pipeline) y trae la implementación **gold** existente (datasets `gold_*` y `3_gold.sql`, sin modificar) más las consultas de origen para cargarla (`consultas/gold_consultas_origen.sql`).

## Estructura

```
dataflow/      df_silver_patients | admissions | diagnoses | billing
dataset/       dw_bronze_<tabla>, dw_silver_<tabla>_sql y gold_* (7 tablas gold)
consultas/     gold_consultas_origen.sql (7 SELECT silver → gold)
linkedService/ sql_dw_hospital  (Azure SQL dw_hospital, el del repo gold con su credencial)
pipeline/      pipeline_silver
factory/       definición de la factoría (renombrar con tu CI/teléfono)
terraform/     main.tf (infra) + sql/ (bronze, silver, gold y cargas)
```

## Despliegue

1. `terraform/main.tf`: completar credenciales del provider y reemplazar `<ci/telefono>` (servidor SQL y factoría). `terraform apply` crea la BD y carga bronze.
2. El linked service ya apunta al servidor y usuario del repo gold (credencial cifrada por ADF; si cambias de factoría, vuelve a ingresarla).
3. Conectar la factoría a este repo en ADF Studio (root folder `/`, branch `main`).
4. Ejecutar `pipeline_silver`.
5. Cargar gold con las consultas de `consultas/gold_consultas_origen.sql`, en el orden indicado en el archivo (dimensiones primero, facts después).

## Flujo del pipeline

`AuditarBronzeYLimpiarSilver` (cuenta bronze y vacía silver hijos→padres) → `SL_01_Patients` → `SL_02_Admissions` → `SL_03_Diagnoses` → `SL_04_Billing` → `ReconciliarSilver` (bronze vs silver vs descartadas).

El orden respeta las FK de `2_silver.sql`. Admissions, diagnoses y billing leen la tabla silver padre como segunda fuente y aplican `exists`, así los huérfanos se descartan en vez de romper el sink.

## Reglas de limpieza

| Tabla | Reglas |
|---|---|
| patients | `patient_id` a int; nombre sin `Â`/espacios raros; género → Male/Female; fecha de nacimiento desde 5 formatos (`MM-dd-yy` con año 00-26 → 20xx, resto 19xx; fuera de 1900–hoy → NULL); teléfono → `XXX-XXX-XXXX` (`unknown` → NULL); correo corregido (`,com`, ` at `, `gmial`) y validado; aseguradora canónica (Cigna, Aetna, BlueCross, Medicaid, Medicare, UnitedHealth, Self Pay) |
| admissions | ids a int; fechas desde 5 formatos; departamento canónico (7 valores); alta anterior al ingreso → alta NULL; descarta sin fecha de ingreso; `exists` contra `silver.patients` |
| diagnoses | solo el **primer** código ICD cuando vienen varios; mayúsculas, `-`→`.`, punto tras 3 caracteres (`E119`→`E11.9`); severidad Mild/Moderate/Severe/Critical (resto NULL); `exists` contra `silver.admissions` |
| billing | monto sin `$`/`USD`/comas, 2 decimales; descarta nulos y montos ≤ 0; `charge_type` nulo → `Unknown`; estado Paid/Pending/Unpaid/Overdue; `exists` contra `silver.admissions` |

Todos deduplican por la clave primaria (`aggregate ... first()`).

## Filas esperadas en silver

Calculadas con una réplica en Python de las mismas reglas (no ejecutando ADF):

| Tabla | Bronze | Silver | Descartadas |
|---|---|---|---|
| patients | 1015 | 1015 | 0 |
| admissions | 1800 | 1689 | 111 (42 sin fecha de ingreso, 69 sin paciente) |
| diagnoses | 2200 | 1991 | 209 (sin admisión válida) |
| billing | 2200 | 1898 | 302 (61 sin monto, 70 monto ≤ 0, 171 sin admisión) |

Si `ReconciliarSilver` muestra otros números, hay diferencia entre la réplica y ADF (ver pruebas pendientes en la respuesta).

## Decisiones que conviene revisar

- Montos negativos se descartan (podrían ser errores de signo → usar `abs`).
- Varios ICD por fila: se conserva solo el primero (la PK de `silver.diagnoses` es `diagnosis_id`).
- `severity`, `insurance_provider`, `phone`, `email`, `date_of_birth` quedan NULL cuando no se pueden inferir; gold deberá aplicar su propio valor por defecto (sus columnas son NOT NULL en `dim_paciente`/`dim_diagnostico`).
