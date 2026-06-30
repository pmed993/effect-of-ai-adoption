# AI Adoption Labeling Methodology And Model Card

This document records the methodology for the filing-level AI adoption process in `2. get_ai_adoption/llm_score`. It is intended for project review, QA, and reproducibility.

## Summary

The pipeline estimates firm-level AI adoption from SEC Form 10-K disclosures. It reads EDGAR extract chunks, converts Item 1 and Item 7 text into one row per filing, optionally filters to a research lookup of `cik` and `year`, extracts a short AI-relevant filing text section, and sends that filing text to a Data Workspace SageMaker endpoint.

The model now returns one ordinal adoption code, from which the pipeline derives:

- `ai_adopted` as the main specification
- `ai_adoption_level` as the secondary intensity measure
- `ai_adoption_level_code` as the stored ordinal code

This replaces the earlier continuous-score design. The change reflects both the literature and our QA evidence:

- LLMs tend to be more reliable on discrete annotation than on fine-grained continuous scoring
- earlier continuous-score runs showed clear bunching at a small number of repeated values

Current implementation:

```text
Main script: get_ai_score_bulk.py
Utilities: ai_adoption_utils.py
Merge script: merge_outputs.py
Script version: 2026-06-29-get_ai_score_bulk-v5
Prompt version: get_ai_adoption_binary_v10
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

The pipeline is designed around one ordinal model output and two derived analysis variables.

Model output:

```text
ai_level_code ∈ {0, 1, 2, 3}
```

Derived outcomes:

```text
ai_adopted ∈ {0, 1}
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

The pipeline derives:

- `ai_adopted = 0` when `ai_level_code = 0`
- `ai_adopted = 1` when `ai_level_code ∈ {1, 2, 3}`

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

The model receives one combined filing text section per filing, not separate Item 1 and Item 7 labels.

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

Full 10-K filings can be very long. The process does not send the whole filing to the model. Instead, it extracts a short filing text section from the combined Item 1 and Item 7 text.

The snippet extraction logic:

1. Normalizes whitespace.
2. Splits the filing into sentence-like segments.
3. Finds sentences containing broad AI dictionary terms.
4. Adds nearby context using `--sentence-window`.
5. Prioritizes windows with stronger AI language and operational cues.
6. Prioritizes windows with operational cues such as `use`, `deployed`, `integrated`, `detect`, `optimize`, or `personalize`.
7. Downweights windows that look like risk-only, speculative, regulatory, market-theme, future-plan, pilot, or research-only discussion.
8. Returns selected sentences in filing order up to `--max-prompt-chars`.

Default QA setting:

```text
--max-prompt-chars 1500
```

If no ranking keywords are found and the LLM is still called, the snippet falls back to the start of the combined filing text.

## Keyword Prefilter

The v4 prefilter uses a broader AI dictionary to reduce missed filings. The
code still keeps the terms in two readable lists, but the hard-zero call
decision now counts both groups together.

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

Both groups can now justify an LLM call in `hard_zero` mode. The broader list
raises recall by sending more AI-adjacent filings to the model.

The process supports three prefilter modes.

`off`:

Calls the LLM for every non-empty filing.

`hard_zero`:

If no AI dictionary keyword is found, assigns:

```text
ai_adopted = 0
ai_adoption_level = none
score_status = prefilter_zero_no_keyword
llm_called = False
```

`audit`:

Mostly behaves like `hard_zero`, but sends a deterministic sample of no-keyword
filings to the LLM. This estimates whether the broader dictionary is still
missing some adopters.

## Prompt Design

The prompt is designed for small instruct models such as `llama-3-3b`. It follows a few practical rules drawn from the text-annotation literature and official prompt-engineering guidance:

- keep the task zero-shot and explicit
- put the main decision rule near the top
- use one ordinal classification code and derive the binary adoption variable from it
- use short, structured JSON output
- avoid long reasoning instructions and avoid chain-of-thought
- define what does not count as adoption

The prompt explicitly tells the model that the filing text comes from:

```text
Item 1 (Business)
Item 7 (MD&A)
```

The core labeling rule is:

```text
Return one code:
0 = none
1 = low
2 = medium
3 = high
```

The prompt tells the model:

- count adoption when the filing text gives reasonably strong evidence that the firm itself already uses AI in its own products, services, or operations, even if no single sentence states this directly
- return `0` when the text gives only vague or ambiguous hints about the firm's own current AI use
- not infer adoption from industry context, firm name, product names, or vague tech language
- not count AI market exposure, customer use, general AI discussion, future plans, or pilots

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

Level meanings:

```text
none = no explicit evidence of AI adoption in the filing text
low = one narrow or early deployed operational use case
medium = clear operational use in more than one area or in an important business function
high = AI is fundamental to the firm's core business model and competitive functioning
```

The production scoring prompt asks only for the single field needed for labeling:

```text
ai_level_code
```

The pipeline derives `ai_adopted`, `ai_adoption_level`, and `ai_adoption_level_code` from that one ordinal code. This keeps the output small and reduces inconsistency risk for smaller models.

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
--max-new-tokens 60
```

This limits response length. Filing text length is controlled separately by `--max-prompt-chars`.

## Model Output Schema

The model is instructed to return exactly one JSON object:

```json
{"ai_level_code": 0_or_1_or_2_or_3}
```

Required fields:

```text
ai_level_code
```

Rules:

- `ai_level_code` must be `0`, `1`, `2`, or `3`
- `0 = none`
- `1 = low`
- `2 = medium`
- `3 = high`

## Model Output Parsing

The parser:

1. Extracts generated text from common endpoint response shapes.
2. Finds balanced JSON-looking objects while respecting quoted strings and escapes.
3. Tries JSON objects from last to first, because some endpoints may echo earlier prompt content.
4. Accepts the first object that satisfies the ordinal-code schema.
5. If no valid JSON is found, tries a fallback extractor that looks for one direct `ai_level_code` assignment in the raw text.

If parsing fails on the first pass, the output keeps the row and records a failure status such as:

```text
missing_output
no_json_found
no_valid_score_json
invalid_level_code
```

Parser-like failures automatically receive a second LLM call using the same labeling rule wrapped in a stricter JSON-only prompt. Successful rescues are recorded as:

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

`explanation` remains in the output schema for compatibility, but it is no longer required for a filing to be scored successfully.

Optional debug output:

```text
raw_model_output
raw_json
```

These fields are included only when `--save-raw-json` is used. `raw_model_output` stores the raw text returned by the model, which is useful for debugging parser failures.

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
  --max-new-tokens 60 \
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
  --max-new-tokens 60 \
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
