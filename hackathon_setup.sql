--CREATE DATABASE IF NOT EXISTS MY_DEMOS_DB;
--CREATE SCHEMA IF NOT EXISTS MY_DEMOS_DB.SBB_HACKATHON;

USE ROLE ACCOUNTADMIN;
USE DATABASE MY_DEMOS_DB;
USE SCHEMA SBB_HACKATHON;

-- Create stage for PDF documents
CREATE STAGE IF NOT EXISTS MY_DEMOS_DB.SBB_HACKATHON.DOCUMENTS
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

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

INSERT INTO MY_DEMOS_DB.SBB_HACKATHON.UMFRAGE_WERBEKAMPAGNE 
    (befragter_id, werbekampagne_name, ist_verstaendlich, verstaendlichkeits_bewertung, kommentar, umfrage_datum, alter_gruppe, geschlecht)
SELECT 
    seq4() + 1000 AS befragter_id,
    kampagnen.kampagne AS werbekampagne_name,
    CASE WHEN UNIFORM(1, 10, RANDOM()) > 3 THEN TRUE ELSE FALSE END AS ist_verstaendlich,
    UNIFORM(1, 5, RANDOM()) AS verstaendlichkeits_bewertung,
    kommentare.kommentar,
    DATEADD(HOUR, UNIFORM(1, 720, RANDOM()), '2025-09-01 00:00:00'::TIMESTAMP_NTZ) AS umfrage_datum,
    altersgruppen.altersgruppe AS alter_gruppe,
    geschlechter.geschlecht
FROM 
    TABLE(GENERATOR(ROWCOUNT => 200)),
    (SELECT * FROM (VALUES 
        ('Frühlingsaktion 2025'),
        ('Sommerspezial'),
        ('Wintersale'),
        ('Black Friday Aktion'),
        ('Neujahrsangebot'),
        ('Cyber Monday Deal'),
        ('Valentinstag Special'),
        ('Osteraktion')
    ) AS t(kampagne)) AS kampagnen,
    (SELECT * FROM (VALUES 
        ('Sehr klare Botschaft, gut verständlich'),
        ('Gute Kampagne, macht Sinn'),
        ('Zu kompliziert formuliert'),
        ('Ausgezeichnet! Sofort verstanden'),
        ('Verständlich und ansprechend'),
        ('Botschaft nicht klar erkennbar'),
        ('Perfekt formuliert'),
        ('Okay, könnte klarer sein'),
        ('Überhaupt nicht verständlich'),
        ('Sehr deutlich und attraktiv'),
        ('Gut gemacht'),
        ('Klar und präzise'),
        ('Zu viele Informationen auf einmal'),
        ('Geht so, nicht optimal'),
        ('Hervorragend verständlich'),
        ('Schwer zu verstehen'),
        ('Ansprechend gestaltet'),
        ('Zu abstrakt'),
        ('Genau richtig'),
        ('Verwirrend')
    ) AS t(kommentar)) AS kommentare,
    (SELECT * FROM (VALUES 
        ('18-24'),
        ('25-34'),
        ('35-44'),
        ('45-54'),
        ('55-64'),
        ('65+')
    ) AS t(altersgruppe)) AS altersgruppen,
    (SELECT * FROM (VALUES 
        ('männlich'),
        ('weiblich'),
        ('divers')
    ) AS t(geschlecht)) AS geschlechter
WHERE 
    ABS(MOD(seq4(), 8)) = ABS(MOD(HASH(kampagnen.kampagne), 8))
    AND ABS(MOD(seq4(), 20)) = ABS(MOD(HASH(kommentare.kommentar), 20))
    AND ABS(MOD(seq4(), 6)) = ABS(MOD(HASH(altersgruppen.altersgruppe), 6))
    AND ABS(MOD(seq4(), 3)) = ABS(MOD(HASH(geschlechter.geschlecht), 3))
LIMIT 200;



-- PDF Document Processing Pipeline
-- This pipeline ingests PDFs from a stage, parses them, chunks the content, 
-- and stores the chunks with embeddings for RAG applications

-- Create table to store parsed and chunked documents
CREATE OR REPLACE TABLE MY_DEMOS_DB.SBB_HACKATHON.document_chunks (
    chunk_id INTEGER AUTOINCREMENT PRIMARY KEY,
    document_name VARCHAR(500),
    page_number INTEGER,
    chunk_index INTEGER,
    chunk_text VARCHAR(16777216),
    created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Parse PDFs and chunk the content
-- This query processes all PDFs in the stage:
-- 1. AI_PARSE_DOCUMENT extracts text from PDFs in LAYOUT mode
-- 2. Splits multi-page documents into individual pages
-- 3. SPLIT_TEXT_RECURSIVE_CHARACTER chunks each page into smaller pieces
-- Note: Cortex Search Service will generate embeddings automatically

CREATE OR REPLACE PROCEDURE MY_DEMOS_DB.SBB_HACKATHON.process_pdf_documents()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    -- Clear existing chunks
    TRUNCATE TABLE MY_DEMOS_DB.SBB_HACKATHON.document_chunks;
    
    -- Process PDFs: parse and chunk (no manual embeddings needed for Cortex Search)
    INSERT INTO MY_DEMOS_DB.SBB_HACKATHON.document_chunks (
        document_name,
        page_number,
        chunk_index,
        chunk_text
    )
    WITH parsed_docs AS (
        -- Parse all PDFs from stage
        SELECT 
            RELATIVE_PATH AS doc_name,
            SNOWFLAKE.CORTEX.AI_PARSE_DOCUMENT(
                TO_FILE('@MY_DEMOS_DB.SBB_HACKATHON.DOCUMENTS', RELATIVE_PATH),
                {'mode': 'LAYOUT', 'page_split': TRUE}
            ) AS parsed_content
        FROM DIRECTORY(@MY_DEMOS_DB.SBB_HACKATHON.DOCUMENTS)
        WHERE RELATIVE_PATH LIKE '%.pdf'
    ),
    exploded_pages AS (
        -- Flatten pages from parsed documents
        SELECT 
            doc_name,
            page.value:index::INTEGER AS page_num,
            page.value:content::STRING AS page_content
        FROM parsed_docs,
        LATERAL FLATTEN(input => parsed_content:pages) page
    ),
    chunked_content AS (
        -- Chunk each page into smaller pieces
        SELECT 
            doc_name,
            page_num,
            chunk.index AS chunk_idx,
            chunk.value::STRING AS chunk_txt
        FROM exploded_pages,
        LATERAL FLATTEN(
            input => SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(
                page_content,
                'markdown',
                1000,
                100
            )
        ) chunk
    )
    SELECT 
        doc_name,
        page_num,
        chunk_idx,
        chunk_txt
    FROM chunked_content
    WHERE LENGTH(chunk_txt) > 50;
    
    RETURN 'PDF processing complete. ' || (SELECT COUNT(*) FROM MY_DEMOS_DB.SBB_HACKATHON.document_chunks) || ' chunks created.';
END;
$$;

-- Execute the pipeline
-- Uncomment the line below to run the pipeline after uploading PDFs to the stage
--CALL MY_DEMOS_DB.SBB_HACKATHON.process_pdf_documents();
SELECT DISTINCT DOCUMENT_NAME FROM MY_DEMOS_DB.SBB_HACKATHON.DOCUMENT_CHUNKS;
SELECT * FROM MY_DEMOS_DB.SBB_HACKATHON.DOCUMENT_CHUNKS;

SELECT COUNT(TRAVEL_REASON) FROM MOBILITAETSVERHALTEN WHERE TRAVEL_REASON = 'WORK';

-- Create Cortex Search

-- Create Cortex Analyst, use appendix xlsl file for metadata
