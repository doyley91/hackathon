# SBB Hackathon Setup Guide

This guide provides step-by-step instructions for setting up the SBB Hackathon project in Snowflake, which includes document processing, mobility data analysis, and Cortex AI capabilities.

## Prerequisites

- Access to a Snowflake account with ACCOUNTADMIN role
- Database `MY_DEMOS_DB` (will be created if needed)
- Snowflake CLI or SnowSQL installed (for file uploads)
- Access to Snowflake Cortex features

## Project Structure

```
hackathon/
├── hackathon_setup.sql          # Main setup script
├── data/
│   ├── ts-x-11.04.03-MZ-2021-T01.csv           # Mobility behavior data
│   └── ts-x-11.04.03-MZ-2021-T01-APPENDIX.xlsx # Metadata for semantic view
└── documents/
    ├── Ergebnisbericht_Bahn_KUZU_2023_Kanton_Solothurn.pdf
    └── Mobilfunknetztest+DACH+connect+2026-01+fin+gesamt.pdf
```

---

## Setup Instructions

### Step 1: Create Database, Schema, and Stage Objects

Run the first part of the `hackathon_setup.sql` script to create the foundational objects:

```sql
USE ROLE ACCOUNTADMIN;

-- Create database and schema if they don't exist
CREATE DATABASE IF NOT EXISTS MY_DEMOS_DB;
CREATE SCHEMA IF NOT EXISTS MY_DEMOS_DB.SBB_HACKATHON;

USE DATABASE MY_DEMOS_DB;
USE SCHEMA SBB_HACKATHON;

-- Create stage for PDF documents
CREATE STAGE IF NOT EXISTS MY_DEMOS_DB.SBB_HACKATHON.DOCUMENTS
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');
```

**Verify**: Run `SHOW STAGES IN SCHEMA MY_DEMOS_DB.SBB_HACKATHON;` to confirm the DOCUMENTS stage was created.

---

### Step 2: Create and Populate UMFRAGE_WERBEKAMPAGNE Table

Continue with the setup script to create the survey table and insert dummy data:

```sql
-- This creates the table structure
CREATE OR REPLACE TABLE MY_DEMOS_DB.SBB_HACKATHON.UMFRAGE_WERBEKAMPAGNE (
    umfrage_id INTEGER AUTOINCREMENT PRIMARY KEY,
    befragter_id INTEGER,
    werbekampagne_name VARCHAR(200),
    ist_verstaendlich BOOLEAN,
    verstaendlichkeits_bewertung INTEGER,
    kommentar VARCHAR(500),
    umfrage_datum TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    alter_gruppe VARCHAR(50),
    geschlecht VARCHAR(20)
);

-- Execute the INSERT statement from hackathon_setup.sql (lines 24-87)
-- This generates 200 random survey responses for 8 different campaigns
```

**Verify**: Run `SELECT COUNT(*) FROM MY_DEMOS_DB.SBB_HACKATHON.UMFRAGE_WERBEKAMPAGNE;` to confirm 200 rows were inserted.

---

### Step 3: Upload PDF Documents to Stage

**Manual Step**: Upload the PDF files from the `documents/` folder to the DOCUMENTS stage.

#### Option A: Using Snowsight (Web UI)
1. Navigate to **Data** > **Databases** > **MY_DEMOS_DB** > **SBB_HACKATHON** > **Stages**
2. Click on the **DOCUMENTS** stage
3. Click **+ Files** button
4. Upload both PDF files:
   - `Ergebnisbericht_Bahn_KUZU_2023_Kanton_Solothurn.pdf`
   - `Mobilfunknetztest+DACH+connect+2026-01+fin+gesamt.pdf`

#### Option B: Using SnowSQL
```bash
export SNOWSQL_PRIVATE_KEY_PASSPHRASE="[your passphrase from ~/.snowsql/config]"
snowsql -d MY_DEMOS_DB -s SBB_HACKATHON

-- In SnowSQL:
PUT file://./documents/*.pdf @MY_DEMOS_DB.SBB_HACKATHON.DOCUMENTS AUTO_COMPRESS=FALSE;
```

**Verify**: Run `LIST @MY_DEMOS_DB.SBB_HACKATHON.DOCUMENTS;` to see both PDF files.

---

### Step 4: Create MOBILITAETSVERHALTEN Table from CSV

**Manual Step**: Create the table by importing the CSV file.

#### Using Snowsight (Web UI)
1. Navigate to **Data** > **Databases** > **MY_DEMOS_DB** > **SBB_HACKATHON**
2. Click **+ Create** > **Table** > **From File**
3. Select the file: `data/ts-x-11.04.03-MZ-2021-T01.csv`
4. Name the table: `MOBILITAETSVERHALTEN`
5. Review the auto-detected schema and adjust if needed
6. Click **Create Table**

#### Using SnowSQL
```bash
# First, create a temporary stage and upload the CSV
snowsql -d MY_DEMOS_DB -s SBB_HACKATHON

-- In SnowSQL:
CREATE OR REPLACE STAGE MY_DEMOS_DB.SBB_HACKATHON.TEMP_CSV_STAGE;
PUT file://./data/ts-x-11.04.03-MZ-2021-T01.csv @TEMP_CSV_STAGE;

-- Create table and load data (adjust column definitions based on CSV structure)
CREATE OR REPLACE TABLE MY_DEMOS_DB.SBB_HACKATHON.MOBILITAETSVERHALTEN (
    -- Define columns based on CSV structure
    -- Example structure (adjust as needed):
    TRAVEL_REASON VARCHAR,
    -- ... add other columns from the CSV
);

COPY INTO MY_DEMOS_DB.SBB_HACKATHON.MOBILITAETSVERHALTEN
FROM @TEMP_CSV_STAGE/ts-x-11.04.03-MZ-2021-T01.csv
FILE_FORMAT = (TYPE = CSV SKIP_HEADER = 1);
```

**Verify**: Run `SELECT COUNT(*) FROM MY_DEMOS_DB.SBB_HACKATHON.MOBILITAETSVERHALTEN;` to confirm data was loaded.

---

### Step 5: Parse PDF Documents and Create Text Chunks

The setup script includes a stored procedure to process PDFs, extract text, and create chunks for RAG applications.

```sql
-- First, create the document_chunks table and stored procedure (lines 96-175 in hackathon_setup.sql)
-- Then execute the procedure:

CALL MY_DEMOS_DB.SBB_HACKATHON.process_pdf_documents();
```

This procedure will:
1. Parse all PDFs from the DOCUMENTS stage using `SNOWFLAKE.CORTEX.AI_PARSE_DOCUMENT`
2. Split multi-page documents into individual pages
3. Chunk each page into smaller text pieces (~1000 characters with 100 character overlap)
4. Store chunks in the `document_chunks` table

**Verify**: 
```sql
-- Check number of chunks created
SELECT COUNT(*) FROM MY_DEMOS_DB.SBB_HACKATHON.DOCUMENT_CHUNKS;

-- View sample chunks
SELECT * FROM MY_DEMOS_DB.SBB_HACKATHON.DOCUMENT_CHUNKS LIMIT 10;

-- See distinct documents processed
SELECT DISTINCT DOCUMENT_NAME FROM MY_DEMOS_DB.SBB_HACKATHON.DOCUMENT_CHUNKS;
```

---

### Step 6: Create Cortex Search Service

**Manual Step**: Create a Cortex Search Service to enable semantic search over the document chunks.

#### Using Snowsight
1. Navigate to **AI & ML** > **Cortex Search**
2. Click **+ Search Service**
3. Configure the service:
   - **Name**: `DOCUMENT_SEARCH_SERVICE`
   - **Database**: `MY_DEMOS_DB`
   - **Schema**: `SBB_HACKATHON`
   - **Warehouse**: Select an appropriate warehouse
   - **Source Table**: `DOCUMENT_CHUNKS`
   - **Text Column**: `CHUNK_TEXT`
   - **Additional Metadata Columns**: `DOCUMENT_NAME`, `PAGE_NUMBER`, `CHUNK_INDEX`

#### Using SQL
```sql
CREATE OR REPLACE CORTEX SEARCH SERVICE MY_DEMOS_DB.SBB_HACKATHON.DOCUMENT_SEARCH_SERVICE
ON CHUNK_TEXT
ATTRIBUTES DOCUMENT_NAME, PAGE_NUMBER, CHUNK_INDEX
WAREHOUSE = [YOUR_WAREHOUSE_NAME]
TARGET_LAG = '1 hour'
AS (
    SELECT 
        CHUNK_TEXT,
        DOCUMENT_NAME,
        PAGE_NUMBER,
        CHUNK_INDEX
    FROM MY_DEMOS_DB.SBB_HACKATHON.DOCUMENT_CHUNKS
);
```

**Verify**: 
```sql
-- Check service status
SHOW CORTEX SEARCH SERVICES IN SCHEMA MY_DEMOS_DB.SBB_HACKATHON;

-- Test a search
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'MY_DEMOS_DB.SBB_HACKATHON.DOCUMENT_SEARCH_SERVICE',
    'Mobilität Solothurn'
);
```

---

### Step 7: Create Semantic View with Context

**Manual Step**: Create a semantic view for the MOBILITAETSVERHALTEN table using Cortex Analyst.

This step requires referencing the metadata in `ts-x-11.04.03-MZ-2021-T01-APPENDIX.xlsx` to add proper context and descriptions.

#### Using Snowsight
1. Navigate to **Data** > **Databases** > **MY_DEMOS_DB** > **SBB_HACKATHON**
2. Click **+ Create** > **View** > **Semantic View**
3. Select base table: `MOBILITAETSVERHALTEN`
4. Add semantic metadata:
   - Review `ts-x-11.04.03-MZ-2021-T01-APPENDIX.xlsx` for column descriptions
   - Add business-friendly names and descriptions for each column
   - Define relationships and metrics
   - Add synonyms and context to help Cortex Analyst understand queries

#### Example Semantic Model YAML (adjust based on actual columns)
```yaml
name: MOBILITAETSVERHALTEN_SEMANTIC
description: "Mobility behavior data from transportation survey"
base_table:
  database: MY_DEMOS_DB
  schema: SBB_HACKATHON
  table: MOBILITAETSVERHALTEN
columns:
  - name: TRAVEL_REASON
    description: "Reason for travel (e.g., WORK, LEISURE, EDUCATION)"
    synonyms: ["purpose", "trip reason"]
  # Add more columns based on the appendix file
```

**Verify**: Test the semantic view with a natural language query using Cortex Analyst.

---

### Step 8: Create Cortex Agent

**Manual Step**: Create a Cortex Agent that combines the Cortex Search Service (for document RAG) and Cortex Analyst (for data analysis).

#### Using Snowsight
1. Navigate to **AI & ML** > **Cortex Agents**
2. Click **+ Agent**
3. Configure the agent:
   - **Name**: `SBB_HACKATHON_AGENT`
   - **Database**: `MY_DEMOS_DB`
   - **Schema**: `SBB_HACKATHON`
   - **Tools**:
     - Add **Cortex Search Service**: Select `DOCUMENT_SEARCH_SERVICE`
     - Add **Cortex Analyst**: Select the semantic view created in Step 7
   - **System Prompt**: Define how the agent should behave
     ```
     You are an assistant for SBB transportation analysis. You can:
     1. Search through transportation reports and studies
     2. Analyze mobility behavior data
     3. Answer questions about advertising campaigns
     
     Use the document search to find relevant information from reports.
     Use the analyst to query structured data about mobility patterns and surveys.
     ```

#### Using SQL (if supported)
```sql
CREATE OR REPLACE CORTEX AGENT MY_DEMOS_DB.SBB_HACKATHON.SBB_HACKATHON_AGENT
    WAREHOUSE = [YOUR_WAREHOUSE_NAME]
    SYSTEM_PROMPT = 'You are an assistant for SBB transportation analysis...'
    TOOLS = (
        SEARCH_SERVICE('MY_DEMOS_DB.SBB_HACKATHON.DOCUMENT_SEARCH_SERVICE'),
        ANALYST('MY_DEMOS_DB.SBB_HACKATHON.MOBILITAETSVERHALTEN_SEMANTIC')
    );
```

**Verify**: Test the agent with queries like:
- "What are the findings about transportation in Kanton Solothurn?"
- "How many people travel for work according to the mobility data?"
- "Summarize the mobile network test results"
- "What percentage of survey respondents found the Frühlingsaktion 2025 campaign understandable?"

---

## Testing the Complete Setup

Once all steps are complete, test the integration:

```sql
-- Test document chunks
SELECT COUNT(*) AS chunk_count FROM MY_DEMOS_DB.SBB_HACKATHON.DOCUMENT_CHUNKS;

-- Test mobility data
SELECT COUNT(*) FROM MY_DEMOS_DB.SBB_HACKATHON.MOBILITAETSVERHALTEN;

-- Test survey data
SELECT 
    werbekampagne_name,
    COUNT(*) AS responses,
    AVG(verstaendlichkeits_bewertung) AS avg_rating,
    SUM(CASE WHEN ist_verstaendlich THEN 1 ELSE 0 END) AS understood_count
FROM MY_DEMOS_DB.SBB_HACKATHON.UMFRAGE_WERBEKAMPAGNE
GROUP BY werbekampagne_name
ORDER BY avg_rating DESC;
```

---

## Troubleshooting

### Issue: PDFs not parsing
- Ensure PDFs are uploaded without compression: `AUTO_COMPRESS=FALSE`
- Verify stage path: `LIST @MY_DEMOS_DB.SBB_HACKATHON.DOCUMENTS;`

### Issue: Cortex Search Service not finding results
- Wait for initial indexing to complete (check TARGET_LAG)
- Verify chunks contain meaningful content (not just headers/footers)

### Issue: Cortex Analyst not understanding queries
- Review semantic model definitions
- Add more synonyms and context descriptions
- Check that column names match between base table and semantic view

### Issue: CSV import fails
- Check CSV encoding (should be UTF-8)
- Verify delimiter and quote characters
- Review column data types for compatibility

---

## Additional Resources

- [Snowflake Cortex Search Documentation](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-search)
- [Snowflake Cortex Analyst Documentation](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-analyst)
- [Document AI Functions](https://docs.snowflake.com/en/user-guide/snowflake-cortex/document-ai)

---

## Project Summary

This hackathon project demonstrates:
- **Document Processing**: PDF parsing and chunking for RAG applications
- **Data Analysis**: Mobility behavior analysis with semantic understanding
- **AI Integration**: Combining search and analytics in a unified agent
- **Survey Analysis**: Understanding advertising campaign effectiveness

The setup creates a comprehensive environment for exploring transportation data and documents using Snowflake's Cortex AI capabilities.
