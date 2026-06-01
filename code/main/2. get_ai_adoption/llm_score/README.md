# AI Adoption Scoring Methodology And Model Card

This document records the methodology decisions for the filing-level AI adoption scoring process in this repository. It is intended for project review, QA, and reproducibility.

## Summary

The process estimates firm-level AI adoption from SEC Form 10-K disclosures. It reads EDGAR extract chunks from the Data Workspace team S3 folder, converts Item 1 and Item 7 text into one row per filing, optionally filters to a research lookup of `cik` and `year`, and sends relevant filing snippets to a Data Workspace SageMaker Llama endpoint.

The output is one score per filing, identified by `accession_number`, with transparent QA fields showing whether the LLM was called, which prefilter decision was made, and whether the model output parsed successfully.

Current implementation:

```text
Main script: get_ai_score_bulk.py
Utilities: ai_adoption_utils.py
Script version: 2026-04-20-bulk-v1
Prompt version: get_ai_adoption_v5
Default endpoint: jupyterhub-llama-3-3b-instruct-endpoint
Invocation method: dwutils.sm.bulk_invoke_endpoint_async
```

## Intended Use

This process is intended to create a research measure of AI adoption from firm disclosures. The measure can be used for firm-year analysis after joining the filing-level output to the relevant research panel.

The score should be interpreted as evidence of AI adoption in the filing text, not as a direct operational audit of the firm. A low score means the relevant filing text provides little or no explicit evidence of operational AI adoption. It does not prove the firm uses no AI outside the disclosure.

## Not Intended For

The output should not be used as:

- investment advice
- a compliance judgement
- a definitive classification of whether a firm uses AI
- a substitute for manual validation where high-stakes decisions depend on individual firms
- a measure of AI capability, AI spending, AI productivity, or model quality

## Input Data

The process reads RDS chunk files named:

```text
extract_df_chunk_00001.rds
extract_df_chunk_00002.rds
...
```

Each chunk is expected to contain a data frame with these columns:

```text
item
year
accession_number
cik
form_type
text
```

The current workflow reads chunks from the Data Workspace S3 team area using `dwutils.s3.read`. The main command uses:

```text
--team effect_of_ai
```

If chunk files are stored in a subfolder under the team folder, `--chunk-prefix` can be used.

## Filing Construction

The source data is long format, with separate rows for different filing items. The process converts this into one row per filing.

Rows are retained when:

```text
form_type = 10-K
item in {item1, item7}
```

Amended filings are excluded by default. They are included only if the command uses:

```text
--include-amended
```

Rows are grouped by:

```text
accession_number
cik
year
form_type
item
```

Duplicate item text within a group is collapsed before reshaping. The process then pivots the filing into:

```text
item1_text
item7_text
combined_text
```

When both Item 1 and Item 7 are available, they are combined and scored once. The score is not an average of separate Item 1 and Item 7 scores. There is one LLM judgement per filing based on the combined text.

When only one item is available, the filing can still be scored, but the output records:

```text
has_item1
has_item7
item1_chars
item7_chars
combined_chars
```

These fields allow missing-section checks during QA.

## Research Lookup Filter

The research sample is provided through a lookup CSV containing at least:

```text
cik
year
```

Current expected lookup:

```text
../lookup/cik_year.csv
```

The lookup is applied after converting chunks to filing level and before prefiltering or LLM calls. Only filing rows whose normalized `cik` and `year` appear in the lookup are scored.

The current research restriction is assumed to have been applied upstream when creating the lookup. In particular, the script assumes the lookup already reflects the sample definition such as:

```text
exclude SIC between 4900 and 4999
keep SIC below 6000
```

The scoring script does not apply the SIC restriction directly unless SIC is added to the input and the code is changed to use it.

The output summary records:

```text
n_filings_before_lookup
n_filings_after_lookup
lookup_csv
```

These fields are part of the QA trail.

## Text Selection For The LLM

Full 10-K filings can be very long. The process does not send the whole filing to the model. Instead, it extracts a snippet from the combined Item 1 and Item 7 text.

The snippet extraction logic:

1. Normalizes whitespace.
2. Splits the filing into sentence-like segments.
3. Finds sentences containing AI-related keywords.
4. Includes nearby context using `--sentence-window`.
5. Prioritizes windows with operational cues such as use, deployed, integrated, forecast, detect, recommend, optimize, or personalize.
6. Downweights windows that look like risk-only, speculative, regulatory, future-plan, pilot, or research-only discussion.
7. Returns selected sentences in filing order up to `--max-prompt-chars`.

Default QA setting:

```text
--max-prompt-chars 1500
```

If no AI keywords are found and the LLM is still called, the snippet falls back to the start of the combined filing text.

## Keyword Prefilter

The prefilter is used to reduce unnecessary LLM calls. It searches the combined filing text for AI-related terms, including phrases such as:

```text
artificial intelligence
machine learning
deep learning
neural network
predictive model
automated decision
recommendation engine
computer vision
natural language processing
generative AI
large language model
LLM
robotic process automation
autonomous systems
fraud detection model
optimization engine
```

Bare lowercase `ml` is intentionally not matched because it can mean milliliters. Uppercase `ML` is matched.

The process supports three prefilter modes.

`off`:

Calls the LLM for every non-empty filing.

`hard_zero`:

If no AI keyword is found, assigns:

```text
ai_adoption_score = 0.0
score_status = prefilter_zero_no_keyword
llm_called = False
```

This is the intended production-style mode after QA.

`audit`:

Mostly behaves like `hard_zero`, but sends a deterministic sample of no-keyword filings to the LLM. This estimates whether the keyword prefilter is incorrectly assigning zero to filings that the LLM would score above zero.

## LLM Prompt Design

The prompt asks the model to estimate the firm's level of AI adoption as described in the filing, at the time covered by the filing text.

The target concept is operational AI adoption:

```text
the extent to which AI, machine learning, algorithmic systems, or automated decision systems are already implemented and embedded in the firm's core business activities
```

The prompt instructs the model not to score highly for:

- mere mentions of AI or automation
- generic industry trends
- speculative future plans
- research, experiments, pilots, or proofs of concept with no evidence of deployment
- boilerplate innovation language
- risk-factor discussion about AI competition, regulation, or cybersecurity
- third-party technology references without evidence of operational integration

The prompt instructs the model to increase the score when the text gives evidence that AI is:

- deployed in products, services, or internal operations
- tied to revenue generation, product delivery, cost reduction, efficiency, or decision-making
- present across meaningful business functions
- embedded in core business segments
- strategically important to how the firm operates or competes

The final JSON instruction appears after the filing text. This is deliberate. Earlier versions placed an example JSON object before the filing text, which increased the risk that the endpoint echoed the template or returned the wrong JSON object.

## Score Scale

The model returns a continuous score from 0.00 to 1.00.

Scoring guidance:

```text
0.00 = no explicit evidence of AI adoption in the filing text
0.01 to 0.10 = very weak evidence; vague references, early exploration, or non-operational discussion
0.11 to 0.30 = limited adoption; some specific use cases but narrow, tentative, or not central
0.31 to 0.50 = moderate adoption; clear operational use in some relevant business areas
0.51 to 0.70 = substantial adoption; AI is integrated into multiple important functions or products
0.71 to 0.90 = extensive adoption; AI is deeply embedded in operations and materially relevant to the business
0.91 to 1.00 = AI is fundamental to the firm's core business model and competitive functioning
```

The prompt tells the model to use the full range, avoid coarse rounding, and assign 0.10 or below when there is no explicit evidence of firm-specific operational AI adoption.

## Model Invocation

The process uses Data Workspace bulk asynchronous SageMaker invocation:

```text
dwutils.sm.bulk_invoke_endpoint_async
```

This replaced the earlier one-call-at-a-time `sm.query_endpoint` approach because bulk invocation is faster and better aligned with the Data Workspace environment.

Each pending LLM call is represented by an item identifier and an invocation dictionary. The invocation dictionary includes:

```text
EndpointName
Input
ContentType
```

The `Input` is a JSON string containing:

```text
inputs: prompt text
parameters:
  temperature
  max_new_tokens
  return_full_text
```

Current QA-approved generation setting:

```text
--max-new-tokens 120
```

This controls the maximum length of the model response. It does not control the amount of filing text sent to the model. Filing text length is controlled by `--max-prompt-chars`.

The 100-row QA test showed that `--max-new-tokens 80` produced occasional `no_json_found` parser failures, while `--max-new-tokens 120` produced 16 successful parses out of 16 LLM-called rows.

## Model Output Parsing

The model is instructed to return exactly one JSON object:

```json
{"score": 0.64, "explanation": "One short paragraph."}
```

The parser:

1. Extracts generated text from common endpoint response shapes.
2. Finds balanced JSON-looking objects while respecting quoted strings and escapes.
3. Tries JSON objects from last to first, because some endpoints may echo earlier prompt content.
4. Accepts the first object that has a numeric `score` in `[0, 1]`.
5. Normalizes the explanation to a single paragraph.

If parsing fails, the output keeps the row but records a failure status such as:

```text
missing_output
no_json_found
no_valid_score_json
non_numeric_score
score_out_of_bounds
```

These rows should be reviewed during QA before production runs.

## Output Files

For each chunk, the process writes:

```text
extract_df_chunk_XXXXX_llama_scores.csv
extract_df_chunk_XXXXX_summary.json
```

For each run, it writes:

```text
run_manifest_<RUN_ID>.csv
```

By default, outputs are written to:

```text
<out-dir>/<RUN_ID>/
```

Use `--flat-output` only when a single output folder without run subfolders is desired.

## Key Output Columns

Core identifiers:

```text
run_id
script_version
prompt_version
source_label
chunk_id
accession_number
cik
year
form_type
```

Filing-text QA:

```text
has_item1
has_item7
item1_chars
item7_chars
combined_chars
keyword_hits
snippet_chars
snippet_sha256
```

Prefilter and LLM QA:

```text
prefilter_mode
prefilter_decision
prefilter_audit_sample
llm_called
endpoint
job_id
raw_json_sha256
score_status
```

Scoring output:

```text
ai_adoption_score
explanation
```

Optional debug output:

```text
raw_json
```

`raw_json` is included only when `--save-raw-json` is used. It stores parsed raw JSON, not necessarily the full unparsed model response.

## QA Decisions And Current Evidence

The current QA sequence used small runs before scaling:

1. List chunks.
2. Confirm RDS schema and long-to-wide reshaping.
3. Test 3 filings.
4. Test 10 filings.
5. Test 25 filings.
6. Test 100 filings.

Observed QA evidence from chunk 1:

```text
Raw filing rows after long-to-wide: 1000
Rows after lookup: 625
```

Bulk 25-row test:

```text
Rows scored: 25
LLM calls: 9
Hard-zero prefilter rows: 16
Successful LLM parses: 8
Parser failures: 1 with max_new_tokens = 80
```

Bulk 100-row test with `max_new_tokens = 120`:

```text
Rows scored: 100
LLM calls: 16
Hard-zero prefilter rows: 84
Successful LLM parses: 16
Parser failures: 0
Runtime: about 32 seconds
```

Based on this evidence, the recommended QA/default generation setting is:

```text
--max-new-tokens 120
```

Before all-chunk production, the next recommended gate is a full single-chunk run using the lookup filter and hard-zero prefilter.

## Recommended Production-Style Settings

For tested production-style runs:

```bash
python3 get_ai_score_bulk.py \
  --team effect_of_ai \
  --chunk-ids 1 \
  --lookup-csv ../lookup/cik_year.csv \
  --prefilter-mode hard_zero \
  --model-label llama \
  --max-prompt-chars 1500 \
  --max-new-tokens 120 \
  --max-concurrent-invocations 10 \
  --max-workers 5 \
  --out-dir output/test_bulk_chunk1_full \
  --log-level INFO
```

After reviewing the full single-chunk output, scale to a small chunk range:

```bash
python3 get_ai_score_bulk.py \
  --team effect_of_ai \
  --chunk-range 1 3 \
  --lookup-csv ../lookup/cik_year.csv \
  --prefilter-mode hard_zero \
  --model-label llama \
  --max-prompt-chars 1500 \
  --max-new-tokens 120 \
  --max-concurrent-invocations 10 \
  --max-workers 5 \
  --out-dir output/test_bulk_chunks_1_3 \
  --log-level INFO
```

Do not move to `--all-chunks` until the manifest, summaries, score distributions, and parser failure rates are reviewed.

## QA Checks Before Scaling

For every QA run, inspect:

```text
score_status
llm_called
keyword_hits
prefilter_decision
snippet_chars
ai_adoption_score
explanation
has_item1
has_item7
```

Healthy output should show:

- `score_status = ok` for most or all LLM-called rows
- no unexpected `endpoint_error` rows
- rare or zero parser failures
- explanations that are specific to the filing text
- `llm_called = False` only where the prefilter decision explains the skip
- `snippet_chars > 0` for LLM-called rows
- plausible missing Item 1 and Item 7 counts
- score distributions that do not collapse to a single repeated value

Real LLM failures can be inspected with:

```bash
CSV=$(find output/test_bulk_100 -name '*_llama_scores.csv' | sort | tail -1)

python3 -c "import pandas as pd; df=pd.read_csv('$CSV'); fail=df[(df['llm_called']==True) & (~df['score_status'].isin(['ok','prefilter_audit_ok']))]; print(fail[['accession_number','keyword_hits','score_status','explanation']].to_string(index=False) if len(fail) else 'None')"
```

## Known Limitations

Disclosure bias:

Firms differ in how much they disclose. The score measures disclosed evidence, not actual adoption in all firm operations.

Keyword prefilter risk:

`hard_zero` can miss AI adoption if a filing describes AI-like systems without using any matched keyword. Audit-mode testing should be used to estimate this risk.

Snippet risk:

The LLM sees only selected snippets, not the full filing. Relevant evidence can be missed if keyword matching or sentence splitting fails.

Model variability:

LLM outputs can vary across runs, endpoint versions, and generation settings. `temperature = 0.0` reduces but does not eliminate variability.

Parsing risk:

The model may occasionally return malformed JSON. Parser failures are retained in the output through `score_status` rather than silently dropped.

Concept boundary:

The prompt distinguishes operational adoption from aspiration, risk discussion, and industry trend language. Some filings may remain ambiguous.

Temporal interpretation:

The score is based on the filing period and text provided. It should not be interpreted as current AI adoption unless the filing itself is current.

## Reproducibility

Each output row includes:

```text
run_id
script_version
prompt_version
endpoint
source_label
chunk_id
snippet_sha256
raw_json_sha256
```

These fields allow reviewers to identify the code version, prompt version, endpoint, source chunk, and exact snippet hash used for each score.

The process does not currently save the full prompt or full filing text in the score CSV. This is a deliberate output-size and disclosure-risk choice. If deeper auditing is needed, a small QA run can be performed with additional debug output.

## Change Control

Changes that should trigger a new `PROMPT_VERSION`:

- scoring rubric changes
- concept definition changes
- changes to what counts as operational AI adoption
- output JSON format changes
- material changes to prompt ordering or instructions

Changes that should trigger a new `SCRIPT_VERSION`:

- changes to input filtering
- changes to Item 1 or Item 7 construction
- changes to snippet extraction
- changes to keyword prefiltering
- changes to parsing logic
- changes to output columns
- changes to bulk invocation behavior

## Open Review Questions

Before final production use, reviewers should confirm:

- whether the lookup CSV is the final research sample
- whether the SIC exclusion is correctly applied upstream
- whether `hard_zero` is acceptable after audit-mode testing
- whether `max_prompt_chars = 1500` captures enough context
- whether `max_new_tokens = 120` is stable across larger chunk runs
- whether parser failure rates remain low in full-chunk and multi-chunk tests
- whether raw model output should be saved for a QA sample
