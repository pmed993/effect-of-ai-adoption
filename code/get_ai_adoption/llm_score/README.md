# Filing-Level AI Adoption Scoring

This process scores SEC Form 10-K filings for firm-level artificial intelligence adoption using an LLM endpoint. It reads `extract_df_chunk_XXXXX.rds` files, converts filing sections from long format to one row per filing, sends relevant filing snippets to the model, and writes chunk-level CSV outputs plus JSON summaries.

The main script is:

```bash
/Users/piomedolla/Documents/Codex/2026-04-17-check-and-qa-this-process-usr/get_llm_score_qa.py
```

## What The Script Produces

For each selected chunk, the script writes:

- one filing-level score CSV
- one chunk summary JSON
- one run manifest CSV

By default, outputs are written under:

```text
output/llama_scores/<RUN_ID>/
```

This run-specific output directory prevents accidental overwriting of earlier results.

Each scored row represents one filing, identified by `accession_number`.

## Input Requirements

Each `.rds` chunk must contain a data frame with these columns:

```text
item
year
accession_number
cik
form_type
text
```

The process keeps only:

```text
form_type = 10-K
item = item1 or item7
```

Use `--include-amended` if you also want to include `10-K/A` rows.

Chunk filenames must match this strict pattern:

```text
extract_df_chunk_00001.rds
extract_df_chunk_00002.rds
...
```

## Dependencies

The script expects:

```text
python 3
pandas
pyreadr
dwutils
dwutils[ml]
```

For S3 input, it also needs:

```text
boto3
```

Install missing packages as needed:

```bash
pip install pandas pyreadr boto3 dwutils 'dwutils[ml]'
```

## Basic Commands

List available local chunks:

```bash
python3 get_llm_score_qa.py \
  --chunk-dir /path/to/chunks \
  --list-only
```

Run a small smoke test:

```bash
python3 get_llm_score_qa.py \
  --chunk-dir /path/to/chunks \
  --chunk-ids 1 \
  --max-filings-per-chunk 10 \
  --prefilter-mode off \
  --out-dir /path/to/output/llama_scores_qa
```

Run a selected range:

```bash
python3 get_llm_score_qa.py \
  --chunk-dir /path/to/chunks \
  --chunk-range 1 5 \
  --prefilter-mode off \
  --out-dir /path/to/output/llama_scores_qa
```

Run from S3:

```bash
python3 get_llm_score_qa.py \
  --source s3 \
  --s3-bucket jupyter.notebook.uktrade.io \
  --s3-prefix path/to/chunks \
  --chunk-ids 1 \
  --prefilter-mode off \
  --out-dir /path/to/output/llama_scores_qa
```

## Prefilter Modes

The script has three prefilter modes.

`off`

Calls the LLM for every non-empty filing. This is the safest QA mode and the recommended starting point.

```bash
--prefilter-mode off
```

`audit`

Assigns hard zeroes to most no-keyword filings, but sends a deterministic sample of no-keyword filings to the LLM. Use this to estimate whether the keyword prefilter is creating false zeroes.

```bash
--prefilter-mode audit \
--prefilter-audit-rate 0.10 \
--prefilter-audit-limit 25
```

`hard_zero`

Assigns score `0.0` to filings with no AI-related keyword hits and skips the LLM call. Use this only after validating that the false-zero rate is acceptable.

```bash
--prefilter-mode hard_zero
```

## Recommended QA Workflow

1. List chunks.

```bash
python3 get_llm_score_qa.py \
  --chunk-dir /path/to/chunks \
  --list-only
```

2. Run a small smoke test with the prefilter off.

```bash
python3 get_llm_score_qa.py \
  --chunk-dir /path/to/chunks \
  --chunk-ids 1 \
  --max-filings-per-chunk 10 \
  --prefilter-mode off \
  --out-dir /path/to/output/smoke_test
```

3. Inspect the output CSV.

Check:

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

Expected signs of a healthy run:

- most LLM-called rows have `score_status = ok`
- explanations are specific to the filing text
- `snippet_chars` is greater than zero when `llm_called = True`
- missing Item 1 or Item 7 rates are plausible
- low scores are not mostly parser or endpoint failures

4. Run a prefilter audit.

```bash
python3 get_llm_score_qa.py \
  --chunk-dir /path/to/chunks \
  --chunk-ids 1 \
  --max-filings-per-chunk 200 \
  --prefilter-mode audit \
  --prefilter-audit-rate 0.10 \
  --prefilter-audit-limit 25 \
  --out-dir /path/to/output/prefilter_audit
```

Review rows where:

```text
score_status = prefilter_audit_ok
keyword_hits = 0
ai_adoption_score > 0
```

If many no-keyword audit rows receive nonzero scores, do not use `hard_zero` yet.

5. Run a small production-style batch.

```bash
python3 get_llm_score_qa.py \
  --chunk-dir /path/to/chunks \
  --chunk-range 1 5 \
  --prefilter-mode hard_zero \
  --checkpoint-every 25 \
  --retries 2 \
  --out-dir /path/to/output/production_test
```

6. Scale up after reviewing summaries and manifest files.

## Key Output Columns

`ai_adoption_score`

Continuous score from `0.00` to `1.00`.

`explanation`

Short model explanation for the assigned score.

`score_status`

Status of the score generation. Important values include:

```text
ok
prefilter_audit_ok
prefilter_zero_no_keyword
empty_text_zero
endpoint_error
missing_output
no_json_found
json_parse_error
no_valid_score_json
snippet_extraction_failed
```

`llm_called`

Whether the LLM endpoint was called for the filing.

`keyword_hits`

Number of AI keyword matches in the combined Item 1 and Item 7 text.

`prefilter_mode`

The selected prefilter mode for the run.

`prefilter_decision`

The filing-level decision made by the prefilter logic.

`prefilter_audit_sample`

Whether the row was selected for no-keyword audit scoring.

`snippet_chars`

Number of characters sent to the prompt after snippet extraction.

`snippet_sha256`

Hash of the snippet sent to the LLM. This supports auditability without storing the snippet itself.

`raw_json_sha256`

Hash of the raw parsed JSON returned by the model.

`endpoint_attempts`

Number of endpoint attempts used for the filing.

## Summary JSON

Each chunk summary includes:

```text
n_filings
n_unique_cik
n_llm_called
n_ok
n_prefilter_audit_ok
n_prefilter_zero
n_missing_item1
n_missing_item7
status_counts
score_min
score_mean
score_max
```

Use `status_counts` as the first QA check after every run.

## Run Manifest

Each run writes a manifest:

```text
run_manifest_<RUN_ID>.csv
```

This records each selected chunk, whether it completed, output paths, row counts, and any chunk-level error.

## Checkpointing And Retries

The script writes partial checkpoint CSVs while a chunk is running:

```bash
--checkpoint-every 25
```

If the run completes successfully, the partial file is removed and replaced by the final CSV.

Endpoint calls retry by default:

```bash
--retries 2
--retry-sleep 5
```

The sleep time doubles after each failed attempt.

## Recommended Production Pattern

Start with:

```bash
--prefilter-mode off
```

for a small validation sample.

Then use:

```bash
--prefilter-mode audit
```

to estimate the false-zero risk from the keyword filter.

Only use:

```bash
--prefilter-mode hard_zero
```

once the no-keyword audit sample shows that false zeroes are rare enough for the research design.

## Notes On Interpretation

The model is instructed to score only operational, firm-specific AI adoption described in the filing text. It should not score highly for generic AI mentions, industry trends, future plans, experiments, risk factors, or third-party tools unless the filing shows operational integration by the firm.

The score is filing-time evidence, not present-day adoption. A 2018 filing should be interpreted as evidence about the firm as described in that 2018 filing, not as evidence about the firm today.

## Common Failure Modes

High `endpoint_error`

Check endpoint availability, credentials, retry settings, and batch size.

High `no_json_found` or `no_valid_score_json`

The model may not be following the JSON-only instruction. Consider lowering temperature, increasing `--max-new-tokens`, or checking raw endpoint responses with `--save-raw-json`.

Many `snippet_extraction_failed`

Check whether the input text is empty or malformed.

Unexpectedly high missing Item 1 or Item 7 rates

Check the original `item` labels. The script expects normalized values of `item1` and `item7`.

Many nonzero scores in no-keyword audit rows

The keyword prefilter is too narrow for the sample. Keep `--prefilter-mode off` or expand the keyword pattern before using `hard_zero`.

