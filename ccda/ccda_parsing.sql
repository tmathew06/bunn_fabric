-- =============================================================================
-- CCDA Variant Parsing - Databricks SQL
-- Translates PySpark notebook (cells 1–8) to a single executable SQL script.
-- Requires: Databricks Runtime 14+ (variant type + variant_explode support)
--
-- Parameters (set via :param syntax in Databricks SQL editor or job params):
--   :Catalog_Name    e.g. 'racd_dev'
--   :Schema_Name     e.g. 'shared'
--   :File_Name       e.g. 'EPIC%.xml'
--   :Entity_Name     e.g. 'Patient'
--   :Component_Name  e.g. 'Results'
--   :Source_Name     e.g. 'CCDA'
--   :Source_Type     e.g. 'File'
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 1: Metadata / Mapping lookups  (Cells 1–4)
-- ─────────────────────────────────────────────────────────────────────────────

WITH

-- Active mapping rows for this file + entity  (cell 2: df_elements)
mapping AS (
    SELECT *
    FROM dev_teams.racd.source_mappings_ccda_1
    WHERE Source_Entity_Name = :File_Name
      AND Target_Entity_Name = :Entity_Name
      AND Active_Indicator   = 'Y'
),

-- All section rows for this file regardless of entity  (cell 2: df_elements_all)
all_section_meta AS (
    SELECT *
    FROM dev_teams.racd.source_mappings_ccda_1
    WHERE Source_Entity_Name = :File_Name
      AND Element_Type       = 'Section'
),

-- Struct-type sections in active mapping  (cell 3: dict_section_reg)
struct_sections AS (
    SELECT Section_Name, Section_Path
    FROM mapping
    WHERE Element_Type  = 'Section'
      AND Section_Type  = 'Struct'
),

-- Array-type sections in active mapping  (cell 3: dict_section_arr)
array_sections AS (
    SELECT Section_Name, Section_Path
    FROM mapping
    WHERE Element_Type  = 'Section'
      AND Section_Type  = 'Array'
),

-- Column definitions  (cell 4: Columns list)
column_defs AS (
    SELECT
        Section_Name  AS Section,
        Column_Name,
        Column_Path
    FROM mapping
    WHERE Element_Type = 'Column'
),

-- Section hierarchy metadata used in the dynamic loop  (cell 7: dicts)
section_meta AS (
    SELECT
        m.Section_Name,
        m.Section_Path,
        m.Section_Type,
        m.Section_Level,
        m.Parent_Section_Name,
        m.Section_keys,
        -- Convenience flags
        (m.Section_Type = 'Array')  AS is_array,
        (m.Section_Type = 'Struct') AS is_struct
    FROM dev_teams.racd.source_mappings_ccda_1 m
    WHERE m.Source_Entity_Name = :File_Name
      AND m.Element_Type       = 'Section'
),

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 2: Raw source data + Document_ID filter  (Cell 5)
-- ─────────────────────────────────────────────────────────────────────────────

raw_source AS (
    SELECT
        r.MEDICAL_RECORD_FILENAME,
        r.CCDA_RAW,
        -- Inline Document_ID extraction; path comes from mapping
        variant_get(
            r.CCDA_RAW,
            (SELECT Column_Path
             FROM dev_teams.racd.source_mappings_ccda_1
             WHERE Source_Entity_Name = :File_Name
               AND Section_Name       = 'Document'
               AND Column_Name        = 'Document_ID'
             LIMIT 1),
            'string'
        ) AS Document_ID
    FROM IDENTIFIER(:Catalog_Name || '.' || :Schema_Name || '.brnz_ccda_raw_variant') r
    WHERE r.MEDICAL_RECORD_FILENAME LIKE '%' || :File_Name || '%'
),

-- Apply Document_ID filter (matching cell 5 hard-filter; remove/parameterise as needed)
filtered_source AS (
    SELECT *
    FROM raw_source
    -- WHERE Document_ID = '3b7d532f-a064-41b3-8de7-2337bf865f93'  -- optional dev filter
),

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 3: Components extraction & explode  (Cell 6)
-- "Components" is always the top-level array container.
-- Path is resolved from all_section_meta at runtime.
-- ─────────────────────────────────────────────────────────────────────────────

components_raw AS (
    SELECT
        fs.MEDICAL_RECORD_FILENAME,
        fs.Document_ID,
        variant_get(
            fs.CCDA_RAW,
            (SELECT Section_Path FROM all_section_meta WHERE Section_Name = 'Components' LIMIT 1),
            'variant'
        ) AS Components
    FROM filtered_source fs
),

-- Explode the top-level Components array
components_exploded AS (
    SELECT
        cr.MEDICAL_RECORD_FILENAME,
        cr.Document_ID,
        ce.pos,
        ce.value
    FROM components_raw cr,
    LATERAL variant_explode(cr.Components) ce
),

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 4: Target component slice  (Cell 7, level-0 block)
-- Filter exploded components down to the requested :Component_Name section.
-- ─────────────────────────────────────────────────────────────────────────────

target_component AS (
    SELECT
        ce.MEDICAL_RECORD_FILENAME,
        ce.Document_ID,
        variant_get(
            ce.value,
            (SELECT Section_Path
             FROM section_meta
             WHERE Section_Name = :Component_Name
             LIMIT 1),
            'variant'
        ) AS component_variant
    FROM components_exploded ce
    WHERE variant_get(
            ce.value,
            (SELECT Section_Path
             FROM section_meta
             WHERE Section_Name = :Component_Name
             LIMIT 1),
            'string'
          ) IS NOT NULL
),

-- Explode the target component (level-0 array)
target_component_exploded AS (
    SELECT
        tc.MEDICAL_RECORD_FILENAME,
        tc.Document_ID,
        tce.pos,
        tce.value
    FROM target_component tc,
    LATERAL variant_explode(tc.component_variant) tce
    WHERE tce.value IS NOT NULL
),

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 5: Child section extraction  (Cell 7, level > 0 blocks)
--
-- The PySpark loop handles arbitrary nesting dynamically.  In SQL we materialise
-- each level explicitly.  The pattern below covers the four parent/child type
-- combinations (Array→Struct, Array→Array, Struct→Struct, Struct→Array).
--
-- Extend this block for additional Section_Level values as your mapping grows.
-- Each level block follows the same template; only the parent CTE changes.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── Level 1 sections (parent = target component, itself an Array) ─────────────

-- Level-1 Struct children  (Parent=Array, Child=Struct)
level1_struct AS (
    SELECT
        tce.MEDICAL_RECORD_FILENAME,
        tce.Document_ID,
        sm.Section_Name,
        variant_get(tce.value, sm.Section_Path, 'variant') AS section_data
    FROM target_component_exploded tce
    CROSS JOIN section_meta sm
    WHERE sm.Section_Level = 1
      AND sm.is_struct      = TRUE
      AND sm.Parent_Section_Name = :Component_Name
      AND variant_get(tce.value, sm.Section_Path, 'variant') IS NOT NULL
),

-- Level-1 Array children  (Parent=Array, Child=Array)
level1_array_raw AS (
    SELECT
        tce.MEDICAL_RECORD_FILENAME,
        tce.Document_ID,
        sm.Section_Name,
        sm.Section_keys,
        variant_get(tce.value, sm.Section_Path, 'variant') AS section_data
    FROM target_component_exploded tce
    CROSS JOIN section_meta sm
    WHERE sm.Section_Level = 1
      AND sm.is_array       = TRUE
      AND sm.Parent_Section_Name = :Component_Name
),

level1_array AS (
    SELECT
        lar.MEDICAL_RECORD_FILENAME,
        lar.Document_ID,
        lar.Section_Name,
        lae.pos,
        lae.value
    FROM level1_array_raw lar,
    LATERAL variant_explode(lar.section_data) lae
    WHERE lae.value IS NOT NULL
),

-- ── Level 2 sections ──────────────────────────────────────────────────────────
-- Struct→Struct
level2_struct_from_struct AS (
    SELECT
        ls.MEDICAL_RECORD_FILENAME,
        ls.Document_ID,
        ls.Section_Name AS parent_section,
        sm.Section_Name,
        sm.Section_keys,
        variant_get(ls.section_data, sm.Section_Path, 'variant') AS section_data
    FROM level1_struct ls
    JOIN section_meta sm
      ON sm.Parent_Section_Name = ls.Section_Name
     AND sm.Section_Level       = 2
     AND sm.is_struct            = TRUE
    WHERE variant_get(ls.section_data, sm.Section_Path, 'variant') IS NOT NULL
),

-- Struct→Array
level2_array_from_struct_raw AS (
    SELECT
        ls.MEDICAL_RECORD_FILENAME,
        ls.Document_ID,
        ls.Section_Name          AS parent_section,
        sm.Section_Name,
        sm.Section_keys,
        -- parent key column carried forward for join cardinality
        variant_get(ls.section_data, sm.Section_Path, 'variant') AS section_data
    FROM level1_struct ls
    JOIN section_meta sm
      ON sm.Parent_Section_Name = ls.Section_Name
     AND sm.Section_Level       = 2
     AND sm.is_array             = TRUE
),

level2_array_from_struct AS (
    SELECT
        lar.MEDICAL_RECORD_FILENAME,
        lar.Document_ID,
        lar.Section_Name,
        lae.pos,
        lae.value
    FROM level2_array_from_struct_raw lar,
    LATERAL variant_explode(lar.section_data) lae
    WHERE lae.value IS NOT NULL
),

-- Array→Struct
level2_struct_from_array AS (
    SELECT
        la.MEDICAL_RECORD_FILENAME,
        la.Document_ID,
        la.Section_Name AS parent_section,
        sm.Section_Name,
        variant_get(la.value, sm.Section_Path, 'variant') AS section_data
    FROM level1_array la
    JOIN section_meta sm
      ON sm.Parent_Section_Name = la.Section_Name
     AND sm.Section_Level       = 2
     AND sm.is_struct            = TRUE
    WHERE variant_get(la.value, sm.Section_Path, 'variant') IS NOT NULL
),

-- Array→Array
level2_array_from_array_raw AS (
    SELECT
        la.MEDICAL_RECORD_FILENAME,
        la.Document_ID,
        la.Section_Name          AS parent_section,
        sm.Section_Name,
        variant_get(la.value, sm.Section_Path, 'variant') AS section_data
    FROM level1_array la
    JOIN section_meta sm
      ON sm.Parent_Section_Name = la.Section_Name
     AND sm.Section_Level       = 2
     AND sm.is_array             = TRUE
),

level2_array_from_array AS (
    SELECT
        lar.MEDICAL_RECORD_FILENAME,
        lar.Document_ID,
        lar.Section_Name,
        lae.pos,
        lae.value
    FROM level2_array_from_array_raw lar,
    LATERAL variant_explode(lar.section_data) lae
    WHERE lae.value IS NOT NULL
),

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 6: Column extraction — apply column_defs to each leaf section
-- Mirrors the cell 7 inner loop:
--   df_section_elements[i].withColumn(col_name, variant_get(section_col, path, 'string'))
--
-- One sub-CTE per leaf section; UNION ALL assembles final output.
-- Add/remove sub-CTEs to match your actual mapping.
-- ─────────────────────────────────────────────────────────────────────────────

--
-- Helper: pivot column_defs into a wide row per section using MAX(CASE …)
-- This approach avoids dynamic SQL while remaining set-based and efficient.
--

-- Leaf: level-1 Struct sections
parsed_level1_struct AS (
    SELECT
        ls.MEDICAL_RECORD_FILENAME,
        ls.Document_ID,
        ls.Section_Name,
        cd.Column_Name,
        variant_get(ls.section_data, cd.Column_Path, 'string') AS Column_Value
    FROM level1_struct ls
    JOIN column_defs cd
      ON cd.Section = ls.Section_Name
),

-- Leaf: level-1 Array sections (value is the exploded row)
parsed_level1_array AS (
    SELECT
        la.MEDICAL_RECORD_FILENAME,
        la.Document_ID,
        la.Section_Name,
        cd.Column_Name,
        variant_get(la.value, cd.Column_Path, 'string') AS Column_Value
    FROM level1_array la
    JOIN column_defs cd
      ON cd.Section = la.Section_Name
),

-- Leaf: level-2 Struct from Struct
parsed_level2_struct_struct AS (
    SELECT
        ls.MEDICAL_RECORD_FILENAME,
        ls.Document_ID,
        ls.Section_Name,
        cd.Column_Name,
        variant_get(ls.section_data, cd.Column_Path, 'string') AS Column_Value
    FROM level2_struct_from_struct ls
    JOIN column_defs cd
      ON cd.Section = ls.Section_Name
),

-- Leaf: level-2 Array from Struct
parsed_level2_array_struct AS (
    SELECT
        la.MEDICAL_RECORD_FILENAME,
        la.Document_ID,
        la.Section_Name,
        cd.Column_Name,
        variant_get(la.value, cd.Column_Path, 'string') AS Column_Value
    FROM level2_array_from_struct la
    JOIN column_defs cd
      ON cd.Section = la.Section_Name
),

-- Leaf: level-2 Struct from Array
parsed_level2_struct_array AS (
    SELECT
        la.MEDICAL_RECORD_FILENAME,
        la.Document_ID,
        la.Section_Name,
        cd.Column_Name,
        variant_get(la.section_data, cd.Column_Path, 'string') AS Column_Value
    FROM level2_struct_from_array la
    JOIN column_defs cd
      ON cd.Section = la.Section_Name
),

-- Leaf: level-2 Array from Array
parsed_level2_array_array AS (
    SELECT
        la.MEDICAL_RECORD_FILENAME,
        la.Document_ID,
        la.Section_Name,
        cd.Column_Name,
        variant_get(la.value, cd.Column_Path, 'string') AS Column_Value
    FROM level2_array_from_array la
    JOIN column_defs cd
      ON cd.Section = la.Section_Name
),

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 7: Union all parsed leaf rows
-- ─────────────────────────────────────────────────────────────────────────────

all_parsed AS (
    SELECT * FROM parsed_level1_struct
    UNION ALL
    SELECT * FROM parsed_level1_array
    UNION ALL
    SELECT * FROM parsed_level2_struct_struct
    UNION ALL
    SELECT * FROM parsed_level2_array_struct
    UNION ALL
    SELECT * FROM parsed_level2_struct_array
    UNION ALL
    SELECT * FROM parsed_level2_array_array
)

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 8: Final output  (Cell 8)
-- Pivot long → wide so each Column_Name becomes a proper column.
-- The PIVOT list must match the Column_Names defined in your mapping table.
-- Replace the column list in the PIVOT clause with your actual column names.
--
-- To persist: wrap in  CREATE OR REPLACE TABLE dev_teams.racd.T_Parsed_<comp>_<entity> AS ...
-- ─────────────────────────────────────────────────────────────────────────────

SELECT *
FROM all_parsed
    PIVOT (
        MAX(Column_Value)
        FOR Column_Name IN (
            -- !! Replace / extend this list with your actual Column_Name values !!
            -- These must match Column_Name values in source_mappings_ccda_1
            'Document_ID',
            'Patient_First_Name',
            'Patient_Last_Name',
            'Patient_DOB',
            'Patient_Gender',
            'Result_Code',
            'Result_Value',
            'Result_Unit',
            'Result_Date',
            'Result_Status'
            -- ... add more as needed
        )
    )
ORDER BY MEDICAL_RECORD_FILENAME, Document_ID
;

-- =============================================================================
-- OPTIONAL: Persist to table (uncomment to replace cell 8 write operation)
-- =============================================================================
-- CREATE OR REPLACE TABLE dev_teams.racd.T_Parsed_Results_Patient AS
-- <paste full CTE query above here>
-- ;
