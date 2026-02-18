# CCDA Bronze-to-Silver Pipeline

## Overview

This directory contains the metadata-driven pipeline for processing clinical JSON documents
from the bronze layer into structured silver layer delta tables. The pipeline reads JSON blobs
stored as VARIANT columns in the bronze delta table, identifies the document type using
configuration metadata, dynamically extracts fields based on mapping rules, and loads the
results into silver layer target tables.

The pipeline is designed for extensibility. While the current implementation supports CCDA
(Consolidated Clinical Document Architecture) documents, the metadata-driven architecture
allows new document formats to be added by inserting configuration rows -- no code changes
required for additional CCDA sections or fields.

## Architecture

### Processing Flow

1. **Read Bronze**: Query the bronze delta table for rows where `insert_timestamp` exceeds
   the last processed watermark.
2. **Identify Document Type**: Check each JSON blob against the `clinical_document_type`
   configuration table to determine its format (CCDA, etc.).
3. **Load Mappings**: Retrieve field-level extraction rules from `clinical_field_mapping`
   for the identified document type and target table.
4. **Extract Section Data**: For CCDA documents, explode the sections array, filter to
   the relevant section by LOINC code, normalize and explode entries, then extract fields
   using dynamic variant path expressions.
5. **Extract Root Data**: For fields sourced from the document root (e.g., patient ID),
   extract directly without section traversal.
6. **Write Silver**: Write the extracted and transformed data to the silver delta table.
7. **Update Watermark**: Record the max `insert_timestamp` processed to prevent reprocessing.

### Configuration Tables (utilities_lakehouse)

| Table                      | Purpose                                                        |
|----------------------------|----------------------------------------------------------------|
| `clinical_document_type`   | Registry of document formats with identification rules         |
| `clinical_field_mapping`   | Maps JSON paths to target table columns per document type      |
| `clinical_processing_log`  | Tracks processing runs and high watermarks                     |

### CCDA JSON Structure

CCDA (Consolidated Clinical Document Architecture) documents contain up to 24 clinical
sections under `component.structuredBody.component[]`. Each section is identified by a
LOINC code in `section.code._code`. Sections contain entries that hold the clinical data
in varying structures (observations, acts, encounters, organizers).

Key sections and their LOINC codes:

| LOINC Code | Section Name             | Entry Structure                          |
|------------|--------------------------|------------------------------------------|
| 30954-2    | Results                  | entry.organizer.component.observation    |
| 8716-3     | Vital Signs              | entry.organizer.component.observation    |
| 46240-8    | Encounters               | entry.encounter                          |
| 11450-4    | Problems                 | entry.act.entryRelationship.observation  |
| 48765-2    | Allergies                | entry.act.entryRelationship.observation  |
| 10160-0    | Medications              | entry.substanceAdministration            |
| 47519-4    | Procedures               | entry.procedure                          |
| 11369-6    | Immunizations            | entry.substanceAdministration            |
| 29762-2    | Social History           | entry.observation                        |

### Path Notation

The `clinical_field_mapping` table stores JSON paths in **dot notation** (e.g.,
`organizer.component.observation.code._code`). The processing notebook converts these
to **variant colon notation** at runtime (e.g., `organizer:component:observation:code:_code`)
for use with Databricks/Fabric `selectExpr()` statements.

This design keeps the mapping table human-readable while generating the correct syntax
for VARIANT column access.

## Notebooks

| Notebook                       | Purpose                                                        |
|--------------------------------|----------------------------------------------------------------|
| `ccda_config_tables.ipynb`     | Creates configuration tables and seeds CCDA mapping data       |
| `ccda_silver_tables.ipynb`     | Creates silver layer target tables (OBSERVATION, ENCOUNTER)    |
| `ccda_bronze_to_silver.ipynb`  | Main processing notebook: extraction, transformation, loading  |

### Execution Order

1. Run `ccda_config_tables.ipynb` first to create and seed the metadata tables.
2. Run `ccda_silver_tables.ipynb` to create the silver target tables.
3. Run `ccda_bronze_to_silver.ipynb` to process bronze data into silver.

## How to Add New Field Mappings

Insert a new row into `clinical_field_mapping` with:

- `document_type_code`: The document type (e.g., `'CCDA'`)
- `target_table`: The silver table to load into (e.g., `'OBSERVATION'`)
- `target_column`: The column name in the silver table
- `column_ordinal`: Display/processing order
- `source_json_path`: Dot-notation path to the value in the JSON
  - For **section entries**: path relative to the entry element
    (e.g., `organizer.component.observation.value._unit`)
  - For **root-level** fields: path from the document root
    (e.g., `recordTarget.patientRole.id._root`)
- `path_context`: `'section_entry'` or `'root'`
- `section_loinc_code`: The LOINC code of the CCDA section (required for `section_entry`;
  NULL for `root`)
- `target_data_type`: Target Spark SQL data type (`STRING`, `TIMESTAMP`, `DOUBLE`, etc.)
- `transformation_sql`: Optional SQL expression using `{value}` as the placeholder for the
  raw extracted value. Example:
  `CASE WHEN {value} IN ('H','L','HH','LL','A') THEN true ELSE false END`

## How to Add New Document Types

1. Insert a row into `clinical_document_type` with the identification logic
   (a JSON path and value that uniquely identifies the document format).
2. Add field mappings to `clinical_field_mapping` for the new document type.
3. If the new format requires different extraction logic (e.g., not section-based),
   add a new extraction function in `ccda_bronze_to_silver.ipynb` and wire it
   into the orchestration logic.

## Watermark Behavior

Each processing run records a **high watermark** -- the maximum `insert_timestamp` from
the bronze rows that were processed. Subsequent runs only process rows with an
`insert_timestamp` greater than this watermark. On the first run (no prior watermark),
all rows are processed.

The watermark is tracked per `document_type_code` + `target_table` combination in the
`clinical_processing_log` table. This means OBSERVATION and ENCOUNTER extractions are
independently watermarked, allowing them to be reprocessed or reset independently.

To reprocess all data for a specific target table, delete or update the corresponding
rows in `clinical_processing_log` to reset the watermark.

## Key Design Decisions

- **selectExpr with variant paths**: Extraction uses `selectExpr()` with variant `:` notation,
  which reads like SQL and is accessible to the team.
- **Metadata-driven**: All extraction rules live in config tables, not in code. Adding new
  fields or sections requires only INSERT statements.
- **Array normalization**: CCDA entries can be a single object or an array. The extraction
  handles both cases using `COALESCE(TRY_CAST(... AS ARRAY<VARIANT>), ARRAY(...))`.
- **Section-level granularity**: Each mapping row specifies which CCDA section to extract from,
  ensuring data comes from the correct clinical context.
- **Independent watermarks**: Each target table has its own watermark, allowing fine-grained
  control over reprocessing.
