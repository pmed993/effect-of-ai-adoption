# AI Adoption Labeling Methodology And Model Card

This document records the methodology for the filing-level AI adoption process in `2. get_ai_adoption/llm_score`. It is intended for project review, QA, and reproducibility.

## Summary

The pipeline estimates firm-level AI adoption from SEC Form 10-K disclosures. It reads EDGAR extract chunks, converts Item 1 and Item 7 text into one row per filing, optionally filters to a research lookup of `cik` and `year`, extracts a short AI-relevant excerpt, and sends that excerpt to a Data Workspace SageMaker endpoint.

The pipeline now produces:

- `ai_adopted` as the main specification
- `ai_adoption_level` as the secondary intensity measure

The process is binary first and ordinal second:

- first decide whether the filing contains explicit evidence that the firm itself already uses AI
- only if the answer is yes, classify the intensity as `low`, `medium`, or `high`

This replaces the earlier continuous-score design. The change reflects both the literature and our QA evidence:

- LLMs tend to be more reliable on discrete annotation than on fine-grained continuous scoring
- earlier continuous-score runs showed clear bunching at a small number of repeated values

Current implementation:

```text
Main script: get_ai_score_bulk.py
Utilities: ai_adoption_utils.py
Merge script: merge_outputs.py
Script version: 2026-06-29-get_ai_score_bulk-v3
Prompt version: get_ai_adoption_binary_v4
Default endpoint: jupyterhub-llama-3-3b-instruct-endpoint
Invocation method: dwutils.sm.bulk_invoke_endpoint_async
```

## Intended Use

This process is intended to create a research measure of disclosed firm AI adoption from 10-K filings. The filing-level output can be merged into a firm-year panel for downstream analysis.

Interpretation:

- `ai_adopted = 1` means the filing text provides explicit evidence that the firm itself already uses AI in products, services, or internal operations during the filing period
- `ai_adopted = 0` means the filing text does not provide that evidence
- `ai_adoption_level` is only intended as a coarse secondary measure of disclosed intensity

This is a disclosure-based measure, not a direct operational audit.

## Not Intended For

The output should not be used as:

- investment advice
- a compliance judgement
- proof that a firm definitively does or does not use AI outside the filing
- a precise interval-scale measure of AI intensity
- a measure of AI capability, AI spending, AI productivity, or model quality

## Main Design Decision

The pipeline is designed around a primary binary outcome and a secondary ordinal outcome.

Primary outcome:

```text
ai_adopted ∈ {0, 1}
```

Secondary outcome:

```text
ai_adoption_level ∈ {none, low, medium, high}
ai_adoption_level_code ∈ {0, 1, 2, 3}
```

Mapping:

```text
0 = none
1 = low
2 = medium
3 = high
```

`ai_adoption_level` should be used for robustness checks, heterogeneity, or descriptive work. The main empirical specification should use `ai_adopted`.

## Why The Process Was Redesigned

The earlier process used a continuous `ai_adoption_score`. That design had two practical issues:

1. The literature generally supports LLMs more strongly for categorical text annotation than for fine-grained interval-style scoring.
2. Our earlier runs showed visible clustering on a small number of repeated positive values, which suggests the model was behaving more like an ordinal coder than a smooth continuous scorer.

The new design therefore:

- simplifies the main decision to a binary adoption label
- keeps a coarse intensity label for richer secondary analysis
- removes the false precision of decimals such as `0.63` versus `0.64`

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

The current workflow reads chunks from the Data Workspace S3 team area using `dwutils.s3.read`.

Typical team setting:

```text
--team effect_of_ai
```

If the chunk files are stored in a subfolder under the team folder, use `--chunk-prefix`.

## Filing Construction

The source data is long format, with separate rows for different filing items. The process converts this into one row per filing.

Rows are retained when:

```text
form_type = 10-K
item in {item1, item7}
```

Amended filings are excluded by default. They are included only if:

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

The model receives one combined excerpt per filing, not separate Item 1 and Item 7 labels.

The output also records:

```text
has_item1
has_item7
item1_chars
item7_chars
combined_chars
```

These fields support QA for missing sections and short filings.

## Research Lookup Filter

The research sample is provided through a lookup CSV containing at least:

```text
cik
year
```

The lookup is applied after converting chunks to filing level and before prefiltering or LLM calls. Only filing rows whose normalized `cik` and `year` appear in the lookup are labeled.

The output summary records:

```text
n_filings_before_lookup
n_filings_after_lookup
lookup_csv
```

## Text Selection For The LLM

Full 10-K filings can be very long. The process does not send the whole filing to the model. Instead, it extracts a short excerpt from the combined Item 1 and Item 7 text.

The snippet extraction logic:

1. Normalizes whitespace.
2. Splits the filing into sentence-like segments.
3. Finds sentences containing explicit AI trigger terms or broader ranking-only AI-adjacent terms.
4. Adds nearby context using `--sentence-window`.
5. Prioritizes windows with explicit AI trigger terms.
6. Prioritizes windows with operational cues such as `use`, `deployed`, `integrated`, `detect`, `optimize`, or `personalize`.
7. Downweights windows that look like risk-only, speculative, regulatory, market-theme, future-plan, pilot, or research-only discussion.
8. Returns selected sentences in filing order up to `--max-prompt-chars`.

Default QA setting:

```text
--max-prompt-chars 1500
```

If no ranking keywords are found and the LLM is still called, the snippet falls back to the start of the combined filing text.

## Keyword Prefilter

The v3 prefilter reduces unnecessary LLM calls. It separates keywords into two groups.

Trigger terms:

```text
artificial intelligence
machine learning
deep learning
neural network
computer vision
natural language processing
generative AI
large language model
LLM
```

Ranking-only terms:

```text
big data
business intelligence
data science
predictive analytics
data mining
pattern recognition
anomaly detection
recommendation engine
expert systems
```

Trigger terms can justify an LLM call in `hard_zero` mode. Ranking-only terms improve snippet selection, but they do not by themselves count as a positive prefilter hit.

The process supports three prefilter modes.

`off`:

Calls the LLM for every non-empty filing.

`hard_zero`:

If no AI trigger keyword is found, assigns:

```text
ai_adopted = 0
ai_adoption_level = none
score_status = prefilter_zero_no_keyword
llm_called = False
```

`audit`:

Mostly behaves like `hard_zero`, but sends a deterministic sample of no-trigger-keyword filings to the LLM. This estimates whether the trigger dictionary is incorrectly labeling some filings as non-adopters.

## Prompt Design

The prompt is designed for small instruct models such as `llama-3-3b`. It follows a few practical rules drawn from the text-annotation literature and official prompt-engineering guidance:

- keep the task zero-shot and explicit
- put the main decision rule near the top
- separate the binary decision from the intensity classification
- use short, structured JSON output
- avoid long reasoning instructions and avoid chain-of-thought
- define what does not count as adoption

The prompt explicitly tells the model that the excerpt comes from:

```text
Item 1 (Business)
Item 7 (MD&A)
```

The core decision rule is:

```text
Set ai_adopted=1 if the excerpt says the firm already uses AI in its own products, services, or internal operations during the filing period.
Otherwise set ai_adopted=0.
```

The prompt tells the model not to count the following by themselves:

- selling into AI markets or supplying AI customers
- AI trends, opportunity, strategy, competition, regulation, or risk
- future plans, pilots, experiments, or research
- third-party AI without clear operational integration by the firm

Positive clues include statements that the firm uses AI or ML to:

- improve products
- personalize services
- support decisions
- automate tasks
- forecast outcomes
- detect fraud
- recommend content
- design products
- improve operations

The intensity decision is only made after the binary gate:

```text
If ai_adopted=0, ai_adoption_level must be "none".
If ai_adopted=1, ai_adoption_level must be "low", "medium", or "high".
```

Level meanings:

```text
low = one narrow or early deployed operational use case
medium = clear operational use in more than one area or in an important business function
high = AI is deeply embedded, used across multiple important functions, or core to the business
```

The prompt also asks for a short explanation in `1-2 sentences`, explicitly avoids step-by-step reasoning, and tells the model not to invent a direct negative statement unless the excerpt itself says the firm does not use AI.

## Model Invocation

The process uses Data Workspace bulk asynchronous SageMaker invocation:

```text
dwutils.sm.bulk_invoke_endpoint_async
```

Each pending LLM call is represented by:

- a linked object id
- an invocation dictionary with `EndpointName`, `Input`, and `ContentType`

The `Input` is a JSON string containing:

```text
inputs: prompt text
parameters:
  temperature
  max_new_tokens
  return_full_text
```

Current default generation setting:

```text
--max-new-tokens 120
```

This limits response length. Filing excerpt length is controlled separately by `--max-prompt-chars`.

## Model Output Schema

The model is instructed to return exactly one JSON object:

```json
{"ai_adopted": 1, "ai_adoption_level": "medium", "explanation": "The filing says the firm uses machine learning in underwriting and fraud detection, indicating deployed operational use in important functions."}
```

Required fields:

```text
ai_adopted
ai_adoption_level
explanation
```

Rules:

- `ai_adopted` must be `0` or `1`
- if `ai_adopted = 0`, `ai_adoption_level` must be `none`
- if `ai_adopted = 1`, `ai_adoption_level` must be `low`, `medium`, or `high`

## Model Output Parsing

The parser:

1. Extracts generated text from common endpoint response shapes.
2. Finds balanced JSON-looking objects while respecting quoted strings and escapes.
3. Tries JSON objects from last to first, because some endpoints may echo earlier prompt content.
4. Accepts the first object that satisfies the binary-plus-level schema.
5. Normalizes the explanation to a single paragraph.

If parsing fails on the first pass, the output keeps the row and records a failure status such as:

```text
missing_output
no_json_found
no_valid_score_json
non_binary_adoption
invalid_adoption_level
invalid_level_for_non_adopter
missing_level_for_adopter
```

Parser-like failures automatically receive a second LLM call using the same prompt and labeling rule as the first pass. Successful rescues are recorded as:

```text
ok_after_retry
prefilter_audit_ok_after_retry
```

## Output Files

For each chunk, the process writes:

```text
extract_df_chunk_XXXXX_llama_scores.csv
extract_df_chunk_XXXXX_summary.json
```

The filenames still use `_scores.csv` for backward compatibility, but the contents are now binary-first adoption labels rather than continuous scores.

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
ranking_keyword_hits
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
retry_job_id
raw_json_sha256
score_status
initial_score_status
retry_attempted
retry_score_status
```

The status column names keep the older `score` wording for compatibility, but they now refer to label parsing and endpoint status rather than a continuous score.

Main adoption outputs:

```text
ai_adopted
ai_adoption_level
ai_adoption_level_code
explanation
```

Optional debug output:

```text
raw_json
```

`raw_json` is included only when `--save-raw-json` is used.

## Merge Outputs

`merge_outputs.py` combines chunk outputs into:

- `ai_adoption_all_chunk_outputs.csv`
- `ai_adoption_filing_master.csv`
- `ai_adoption_firm_year_panel.csv`

The merge script now treats the main model outputs as:

```text
llama_ai_adopted
llama_ai_adoption_level
llama_ai_adoption_level_code
```

and similarly for Mistral when provided.

Duplicate-resolution rules such as `max_llama` now prefer:

1. adopted rows over non-adopted rows
2. stronger adoption levels over weaker adoption levels

The merge script also keeps backward compatibility with older continuous-score files and older legacy boolean fields when they are encountered.

## Recommended Production-Style Settings

Single chunk:

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

Small chunk range:

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

Merge chunk outputs:

```bash
python3 merge_outputs.py \
  --llama-dir output/test_bulk_chunks_1_3 \
  --out-dir output/final_merged \
  --lookup-csv ../lookup/cik_year.csv \
  --filing-duplicate-rule max_llama \
  --firm-year-rule max_llama
```

## QA Checks Before Scaling

For every QA run, inspect:

```text
score_status
llm_called
keyword_hits
ranking_keyword_hits
prefilter_decision
snippet_chars
ai_adopted
ai_adoption_level
explanation
has_item1
has_item7
```

Healthy output should show:

- `score_status = ok` for most or all LLM-called rows
- low parser-failure rates after the retry pass
- explanations that are specific to the filing text
- `llm_called = False` only where the prefilter decision explains the skip
- `snippet_chars > 0` for LLM-called rows
- plausible missing Item 1 and Item 7 counts
- a reasonable distribution across `ai_adopted` and `ai_adoption_level`

## Known Limitations

Disclosure bias:

The labels measure disclosed evidence, not actual adoption in all firm operations.

Keyword prefilter risk:

`hard_zero` can miss AI adoption if a filing describes AI-like systems without using any matched trigger term. Audit mode should be used to estimate this risk.

Snippet risk:

The LLM sees only selected snippets, not the full filing. Relevant evidence can still be missed.

Model variability:

LLM outputs can vary across runs, endpoint versions, and generation settings. `temperature = 0.0` reduces but does not eliminate variability.

Parsing risk:

The model may occasionally return malformed JSON. Parser failures are retained in the output through `score_status` rather than silently dropped.

Concept boundary:

Some filings remain genuinely ambiguous at the boundary between deployed use, strategic aspiration, and generic AI-market exposure.

Temporal interpretation:

The label is based on the filing period and text provided. It should not be interpreted as current real-time adoption unless the filing itself is current.

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

These fields allow reviewers to identify the code version, prompt version, endpoint, source chunk, and exact snippet hash used for each filing label.
