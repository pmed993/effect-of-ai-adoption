# S3 Filing-Level AI Adoption Scoring

This folder contains a simplified S3-only scoring script:

```bash
/Users/piomedolla/Documents/Codex/2026-04-17-check-and-qa-this-process-usr/get_llm_score_qa.py
```

The script reads EDGAR chunk files from S3, optionally filters filings to a research lookup of `cik`/`year` pairs, scores each remaining filing for AI adoption using the Llama endpoint, and writes CSV/JSON outputs locally.

There is no local chunk input mode in this version.

## Input Location

Your files should look like this in S3:

```text
s3://jupyter.notebook.uktrade.io/some/path/to/chunks/extract_df_chunk_00001.rds
s3://jupyter.notebook.uktrade.io/some/path/to/chunks/extract_df_chunk_00002.rds
s3://jupyter.notebook.uktrade.io/some/path/to/chunks/extract_df_chunk_00003.rds
```

In that example:

```text
bucket = jupyter.notebook.uktrade.io
prefix = some/path/to/chunks
```

Do not include the filename in the prefix.

You can provide the bucket and prefix separately:

```bash
--s3-bucket jupyter.notebook.uktrade.io \
--s3-prefix some/path/to/chunks
```

Or you can paste the full S3 prefix:

```bash
--s3-prefix s3://jupyter.notebook.uktrade.io/some/path/to/chunks
```

## Required Input Columns

Each `.rds` chunk must contain a data frame with:

```text
item
year
accession_number
cik
form_type
text
```

The script keeps:

```text
form_type = 10-K
item = item1 or item7
```

Add `--include-amended` if you also want `10-K/A`.

## Research Lookup Filter

Use the lookup filter when the research sample is smaller than the full EDGAR chunk universe.

The lookup file should contain at least:

```text
cik
year
```

In the current project, the lookup is:

```text
../lookup/cik_year.csv
```

When `--lookup-csv` is provided, the script filters each chunk after reshaping to filing level and before making any LLM calls. Only rows whose `cik` and `year` appear in the lookup are scored.

This is the recommended workflow if the lookup has already applied the research sample restrictions, for example:

```text
exclude SIC between 4900 and 4999
keep SIC below 6000
```

The script does not apply the SIC rule directly unless SIC is present in the input data. It assumes `../lookup/cik_year.csv` already represents the final research sample.

Check the lookup:

```bash
python3 - <<'PY'
import pandas as pd

lookup = pd.read_csv("../lookup/cik_year.csv")

print("Rows:", len(lookup))
print("Columns:", list(lookup.columns))
print("Unique CIKs:", lookup["cik"].nunique())
print("Year range:", lookup["year"].min(), lookup["year"].max())
print("Duplicate cik/year rows:", lookup.duplicated(["cik", "year"]).sum())
print(lookup.head(10).to_string(index=False))
PY
```

Good signs:

- columns include `cik` and `year`
- duplicate `cik`/`year` rows are zero or understood
- the year range matches the research period

Estimate how many filings in one chunk match the lookup before calling the LLM:

```bash
python3 - <<'PY'
import importlib.util
import sys

SCRIPT = "get_llama_score.py"
BUCKET = "jupyter.notebook.uktrade.io"
PREFIX_ENV = "S3_PREFIX_TEAM_EFFECT_OF_AI"
LOOKUP = "../lookup/cik_year.csv"

spec = importlib.util.spec_from_file_location("scoreqa", SCRIPT)
mod = importlib.util.module_from_spec(spec)
sys.modules["scoreqa"] = mod
spec.loader.exec_module(mod)

bucket, prefix = mod.parse_s3_location(BUCKET, None, PREFIX_ENV)
chunks = mod.list_chunks_s3(bucket, prefix)

ref = chunks["extract_df_chunk_00001.rds"]
df = mod.read_rds_s3(bucket, ref.key)
wide = mod.long_to_wide(df, include_amended=False)
lookup = mod.load_cik_year_lookup(LOOKUP)
filtered = mod.filter_wide_to_lookup(wide, lookup)

print("Chunk:", ref.name)
print("Rows before lookup:", len(wide))
print("Rows after lookup:", len(filtered))

if len(filtered):
    filtered["keyword_hits"] = filtered["combined_text"].apply(mod.count_ai_keywords)
    print("Keyword-hit rows after lookup:", int((filtered["keyword_hits"] > 0).sum()))
    print("No-keyword rows after lookup:", int((filtered["keyword_hits"] == 0).sum()))
    print(filtered[["accession_number", "cik", "year", "keyword_hits", "combined_chars"]].head(20).to_string(index=False))
PY
```

This test is fast because it does not call SageMaker.

## Dependencies

Install these if they are missing:

```bash
pip install pandas pyreadr boto3 dwutils 'dwutils[ml]'
```

You also need S3 credentials available in the environment where you run the script.

## Step 1: Find Your S3 Prefix

If you do not know the prefix, search the bucket:

```bash
aws s3 ls s3://jupyter.notebook.uktrade.io --recursive | rg 'extract_df_chunk_[0-9]{5}\.rds$'
```

If that prints:

```text
2026-04-18 10:00:00  123456  users/piomedolla/edgar/chunks/extract_df_chunk_00001.rds
```

then your prefix is:

```text
users/piomedolla/edgar/chunks
```

## Step 2: List Chunks

Use `--list-only` before scoring:

```bash
python3 /Users/piomedolla/Documents/Codex/2026-04-17-check-and-qa-this-process-usr/get_llm_score_qa.py \
  --s3-bucket jupyter.notebook.uktrade.io \
  --s3-prefix users/piomedolla/edgar/chunks \
  --list-only
```

Or with a full S3 prefix:

```bash
python3 /Users/piomedolla/Documents/Codex/2026-04-17-check-and-qa-this-process-usr/get_llm_score_qa.py \
  --s3-prefix s3://jupyter.notebook.uktrade.io/users/piomedolla/edgar/chunks \
  --list-only
```

## Step 3: Run A Small Smoke Test

This scores only the first 10 filings in chunk 1.

```bash
python3 /Users/piomedolla/Documents/Codex/2026-04-17-check-and-qa-this-process-usr/get_llm_score_qa.py \
  --s3-prefix s3://jupyter.notebook.uktrade.io/users/piomedolla/edgar/chunks \
  --chunk-ids 1 \
  --lookup-csv ../lookup/cik_year.csv \
  --max-filings-per-chunk 10 \
  --prefilter-mode off \
  --out-dir /Users/piomedolla/Documents/Codex/llama_scores_qa
```

`--prefilter-mode off` means every non-empty filing goes to the LLM. This is safest for testing.

## Step 4: Inspect The Output

By default the script writes to:

```text
<out-dir>/<RUN_ID>/
```

Inside that folder you will see:

```text
extract_df_chunk_00001_llama_scores.csv
extract_df_chunk_00001_summary.json
run_manifest_<RUN_ID>.csv
```

The summary JSON includes lookup counts when `--lookup-csv` is used:

```text
n_filings_before_lookup
n_filings_after_lookup
lookup_csv
```

These are important QA fields. For example, if a chunk has 1000 filing rows before the lookup and 12 after the lookup, only those 12 are considered for scoring.

Check these CSV columns first:

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

Healthy signs:

- most LLM-called rows have `score_status = ok`
- explanations are specific to the filing text
- `snippet_chars` is greater than zero when `llm_called = True`
- missing Item 1 and Item 7 rates look plausible
- low scores are not mostly parser or endpoint failures

Also check the summary JSON:

```bash
SUMMARY=$(find /path/to/output -name '*_summary.json' | sort | tail -1)
cat "$SUMMARY"
```

Good lookup signs:

- `n_filings_before_lookup` is plausible for the chunk
- `n_filings_after_lookup` is less than or equal to `n_filings_before_lookup`
- `n_filings_after_lookup` is greater than zero for chunks expected to contain research-sample firms

## Prefilter Modes

`off`

Calls the LLM on every non-empty filing. Use this for smoke tests and validation samples.

```bash
--prefilter-mode off
```

`audit`

Assigns zero to most no-keyword filings, but sends a deterministic sample of no-keyword filings to the LLM. Use this to test whether the keyword filter is creating false zeroes.

```bash
--prefilter-mode audit \
--prefilter-audit-rate 0.10 \
--prefilter-audit-limit 25
```

`hard_zero`

Assigns zero to every no-keyword filing and skips the LLM call. Use this only after the audit shows false zeroes are rare enough.

```bash
--prefilter-mode hard_zero
```

## Recommended QA Run

Run an audit sample:

```bash
python3 /Users/piomedolla/Documents/Codex/2026-04-17-check-and-qa-this-process-usr/get_llm_score_qa.py \
  --s3-prefix s3://jupyter.notebook.uktrade.io/users/piomedolla/edgar/chunks \
  --chunk-ids 1 \
  --lookup-csv ../lookup/cik_year.csv \
  --max-filings-per-chunk 200 \
  --prefilter-mode audit \
  --prefilter-audit-rate 0.10 \
  --prefilter-audit-limit 25 \
  --out-dir /Users/piomedolla/Documents/Codex/llama_scores_prefilter_audit
```

Then review rows where:

```text
score_status = prefilter_audit_ok
keyword_hits = 0
ai_adoption_score > 0
```

If many no-keyword audit rows get nonzero scores, keep using `--prefilter-mode off` or revise the keyword list before using `hard_zero`.

## Production-Style Test

After validation:

```bash
python3 /Users/piomedolla/Documents/Codex/2026-04-17-check-and-qa-this-process-usr/get_llm_score_qa.py \
  --s3-prefix s3://jupyter.notebook.uktrade.io/users/piomedolla/edgar/chunks \
  --chunk-range 1 5 \
  --lookup-csv ../lookup/cik_year.csv \
  --prefilter-mode hard_zero \
  --checkpoint-every 25 \
  --retries 2 \
  --out-dir /Users/piomedolla/Documents/Codex/llama_scores_production_test
```

Review the summaries and manifest before scaling up to more chunks.

## Useful Selection Options

Score specific chunk IDs:

```bash
--chunk-ids 1 2 18 37
```

Score a range:

```bash
--chunk-range 1 5
```

Score by exact filename:

```bash
--chunk-names extract_df_chunk_00001.rds extract_df_chunk_00002.rds
```

Score everything under the prefix:

```bash
--all-chunks
```

Use `--all-chunks` carefully.

## Common Problems

No chunks found:

- check that the prefix does not include the filename
- check that the chunk names match `extract_df_chunk_00001.rds`
- check S3 permissions

Access denied:

- check AWS credentials
- check that the environment can read the bucket and prefix

Many `endpoint_error` rows:

- check endpoint availability
- try a smaller test run
- keep `--retries 2`

Many `no_json_found` or `no_valid_score_json` rows:

- use `--save-raw-json` on a small run
- check whether the endpoint is returning prompt text or malformed output

Unexpectedly many missing Item 1 or Item 7 rows:

- check the original `item` labels in the RDS files
- this script expects `item1` and `item7`

No filings after lookup:

- check that `--lookup-csv ../lookup/cik_year.csv` points to the right file
- check that lookup `cik` and `year` values match the chunk contents
- try another chunk, because not every chunk must contain research-sample firms
- confirm the SIC filtering was applied when creating the lookup
