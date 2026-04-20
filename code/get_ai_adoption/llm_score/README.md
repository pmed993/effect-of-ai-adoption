```markdown
# get_ai_adoption

Filing-level AI adoption scoring for SEC 10-K filings.

This project scores EDGAR filing chunks using a Llama endpoint. It reads `.rds` files from S3, reshapes Item 1 and Item 7 text into one row per filing, extracts relevant AI-related snippets, sends those snippets to an LLM, and writes filing-level AI adoption scores.

The main scoring script is:

```bash
llm_score/get_llama_score.py
```

## What The Process Does

For each selected chunk file:

1. Reads `extract_df_chunk_XXXXX.rds` from S3.
2. Keeps 10-K filings and Item 1 / Item 7 sections.
3. Converts the data to one row per filing.
4. Detects AI-related keyword mentions.
5. Optionally skips no-keyword filings with a hard-zero prefilter.
6. Sends relevant filing snippets to the Llama endpoint.
7. Parses the model response into:
   - `ai_adoption_score`
   - `explanation`
   - `score_status`
8. Writes a per-chunk CSV, summary JSON, and run manifest.

## Input Data

Input files are stored in S3.

Expected file pattern:

```text
extract_df_chunk_00001.rds
extract_df_chunk_00002.rds
extract_df_chunk_00003.rds
```

Current S3 bucket:

```text
jupyter.notebook.uktrade.io
```

Current prefix is stored in the environment variable:

```text
S3_PREFIX_TEAM_EFFECT_OF_AI
```

The prefix should point to the folder containing the chunk files, for example:

```text
teams/_team_effect_of_ai
```

Each `.rds` file must contain a data frame with these columns:

```text
item
year
accession_number
cik
form_type
text
```

The script expects:

```text
form_type = 10-K
item = item1 or item7
```

## Outputs

Outputs are written locally under:

```text
<out-dir>/<RUN_ID>/
```

For each chunk, the script writes:

```text
extract_df_chunk_00001_llama_scores.csv
extract_df_chunk_00001_summary.json
run_manifest_<RUN_ID>.csv
```

Important CSV columns:

```text
accession_number
cik
year
form_type
has_item1
has_item7
combined_chars
keyword_hits
prefilter_mode
prefilter_decision
snippet_chars
llm_called
endpoint_attempts
ai_adoption_score
explanation
score_status
job_id
snippet_sha256
raw_json_sha256
```

Important `score_status` values:

```text
ok
prefilter_zero_no_keyword
prefilter_audit_ok
empty_text_zero
endpoint_error
no_json_found
no_valid_score_json
snippet_extraction_failed
```

## Setup

From the project folder:

```bash
cd ~/get_ai_adoption/llm_score
```

Install requirements if needed:

```bash
pip install -r requirements.txt
```

At minimum, the process needs:

```text
pandas
pyreadr
boto3
dwutils
dwutils[ml]
```

Check that the S3 prefix variable is available:

```bash
echo "$S3_PREFIX_TEAM_EFFECT_OF_AI"
```

Expected output should be something like:

```text
teams/_team_effect_of_ai
```

## SageMaker Output Folder Check

The `dwutils` endpoint helper may wait for outputs under:

```text
/home/dw-user-efs/sagemaker/outputs
```

In this environment, outputs may actually appear under:

```text
/home/dw-user/sagemaker/outputs
```

Before running LLM tests, check:

```bash
ls -ld /home/dw-user-efs/sagemaker/outputs
ls -ld /home/dw-user/sagemaker/outputs
```

If `/home/dw-user-efs/sagemaker/outputs` does not exist but `/home/dw-user/sagemaker/outputs` does, create a symlink:

```bash
ln -s /home/dw-user/sagemaker/outputs /home/dw-user-efs/sagemaker/outputs
```

Then confirm:

```bash
ls -lt /home/dw-user-efs/sagemaker/outputs | head
```

## Basic Commands

List available chunks:

```bash
python3 get_llama_score.py \
  --s3-bucket jupyter.notebook.uktrade.io \
  --s3-prefix-env S3_PREFIX_TEAM_EFFECT_OF_AI \
  --list-only
```

Run one filing with a small prompt:

```bash
python3 get_llama_score.py \
  --s3-bucket jupyter.notebook.uktrade.io \
  --s3-prefix-env S3_PREFIX_TEAM_EFFECT_OF_AI \
  --chunk-ids 1 \
  --max-filings-per-chunk 1 \
  --prefilter-mode off \
  --max-prompt-chars 1500 \
  --max-new-tokens 80 \
  --retries 0 \
  --out-dir output/test_small_prompt \
  --log-level INFO
```

Run 25 filings with hard-zero prefilter:

```bash
python3 get_llama_score.py \
  --s3-bucket jupyter.notebook.uktrade.io \
  --s3-prefix-env S3_PREFIX_TEAM_EFFECT_OF_AI \
  --chunk-ids 1 \
  --max-filings-per-chunk 25 \
  --prefilter-mode hard_zero \
  --max-prompt-chars 1500 \
  --max-new-tokens 80 \
  --retries 0 \
  --out-dir output/test_25_hard_zero \
  --log-level INFO
```

## Prefilter Modes

### `off`

Calls the LLM for every non-empty filing.

Use for small QA tests only.

```bash
--prefilter-mode off
```

Given current endpoint speed, this is not recommended for full chunks.

### `hard_zero`

Assigns `0.0` to filings with no AI keyword hits and skips the LLM.

```bash
--prefilter-mode hard_zero
```

This is the likely production mode, because the endpoint is slow.

### `audit`

Assigns zero to most no-keyword filings but sends a sample of no-keyword filings to the LLM.

Use this to test whether the hard-zero prefilter creates false zeroes.

```bash
--prefilter-mode audit \
--prefilter-audit-rate 0.10 \
--prefilter-audit-limit 25
```

## QA Test Plan

### Test 1: Syntax Check

```bash
python3 -m py_compile get_llama_score.py
```

Pass condition:

```text
No output and no error.
```

### Test 2: Dependency Check

```bash
python3 - <<'PY'
import pandas
import pyreadr
import boto3
from dwutils import sm

print("pandas ok")
print("pyreadr ok")
print("boto3 ok")
print("dwutils.sm ok")
PY
```

Pass condition:

```text
All imports print ok.
```

### Test 3: S3 Chunk Listing

```bash
python3 get_llama_score.py \
  --s3-bucket jupyter.notebook.uktrade.io \
  --s3-prefix-env S3_PREFIX_TEAM_EFFECT_OF_AI \
  --list-only
```

Pass condition:

```text
The command lists files like extract_df_chunk_00001.rds.
```

### Test 4: Read And Reshape One Chunk

Run this from `llm_score/`:

```bash
python3 - <<'PY'
import importlib.util
import sys

SCRIPT = "get_llama_score.py"
BUCKET = "jupyter.notebook.uktrade.io"
PREFIX_ENV = "S3_PREFIX_TEAM_EFFECT_OF_AI"

spec = importlib.util.spec_from_file_location("scoreqa", SCRIPT)
mod = importlib.util.module_from_spec(spec)
sys.modules["scoreqa"] = mod
spec.loader.exec_module(mod)

bucket, prefix = mod.parse_s3_location(BUCKET, None, PREFIX_ENV)
chunks = mod.list_chunks_s3(bucket, prefix)

first_name = sorted(chunks)[0]
ref = chunks[first_name]

print("Testing chunk:", first_name)
print("S3 path:", f"s3://{bucket}/{ref.key}")

df = mod.read_rds_s3(bucket, ref.key)

print("\nRaw rows:", len(df))
print("Columns:", list(df.columns))

print("\nForm types:")
print(df["form_type"].astype(str).str.upper().value_counts().head(10))

print("\nItems:")
print(df["item"].astype(str).str.lower().value_counts().head(20))

wide = mod.long_to_wide(df, include_amended=False)

print("\nWide filing rows:", len(wide))
print("Missing Item 1:", int((wide["has_item1"] == False).sum()))
print("Missing Item 7:", int((wide["has_item7"] == False).sum()))

print("\nCombined chars summary:")
print(wide["combined_chars"].describe())

print("\nFirst few filings:")
cols = ["accession_number", "cik", "year", "form_type", "has_item1", "has_item7", "combined_chars"]
print(wide[cols].head(10).to_string(index=False))
PY
```

Pass condition:

```text
Raw rows > 0
Columns include item, year, accession_number, cik, form_type, text
Form types include 10-K
Items include item1 and item7
Wide filing rows > 0
Combined text lengths are plausible
```

Observed successful example for chunk 1:

```text
Raw rows: 2000
item1: 1000
item7: 1000
Wide filing rows: 1000
Missing Item 1: 0
Missing Item 7: 2
```

### Test 5: One-Filing LLM Test

```bash
python3 get_llama_score.py \
  --s3-bucket jupyter.notebook.uktrade.io \
  --s3-prefix-env S3_PREFIX_TEAM_EFFECT_OF_AI \
  --chunk-ids 1 \
  --max-filings-per-chunk 1 \
  --prefilter-mode off \
  --max-prompt-chars 1500 \
  --max-new-tokens 80 \
  --retries 0 \
  --out-dir output/test_small_prompt \
  --log-level INFO
```

Inspect output:

```bash
CSV=$(find output/test_small_prompt -name '*_llama_scores.csv' | sort | tail -1)

python3 -c "import pandas as pd; df=pd.read_csv('$CSV'); print(df[['accession_number','keyword_hits','snippet_chars','llm_called','endpoint_attempts','ai_adoption_score','score_status','explanation']].to_string(index=False)); print(df['score_status'].value_counts(dropna=False))"
```

Pass condition:

```text
score_status = ok
ai_adoption_score is between 0 and 1
explanation is not blank
```

### Test 6: 25-Filing Hard-Zero Test

```bash
python3 get_llama_score.py \
  --s3-bucket jupyter.notebook.uktrade.io \
  --s3-prefix-env S3_PREFIX_TEAM_EFFECT_OF_AI \
  --chunk-ids 1 \
  --max-filings-per-chunk 25 \
  --prefilter-mode hard_zero \
  --max-prompt-chars 1500 \
  --max-new-tokens 80 \
  --retries 0 \
  --out-dir output/test_25_hard_zero \
  --log-level INFO
```

Inspect output:

```bash
CSV=$(find output/test_25_hard_zero -name '*_llama_scores.csv' | sort | tail -1)

python3 -c "import pandas as pd; df=pd.read_csv('$CSV'); print(df[['accession_number','keyword_hits','llm_called','ai_adoption_score','score_status','explanation']].to_string(index=False)); print('\nscore_status:'); print(df['score_status'].value_counts(dropna=False)); print('\nllm_called:'); print(df['llm_called'].value_counts(dropna=False)); print('\nkeyword_hits:'); print(df['keyword_hits'].describe())"
```

Pass condition:

```text
No-keyword filings have score_status = prefilter_zero_no_keyword
Keyword-hit filings have llm_called = True
Most LLM-called rows have score_status = ok
```

Observed test result:

```text
prefilter_zero_no_keyword: 16
ok: 7
no_json_found: 2
```

This means the process works, but the LLM parsing failure rate still needs review before full-scale running.

## Output QA Checklist

Before scaling up, inspect:

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
endpoint_attempts
```

Good signs:

```text
Most LLM-called rows have score_status = ok
No-keyword hard-zero rows are clearly marked
Scores are between 0 and 1
Explanations are filing-specific
snippet_chars > 0 when llm_called = True
Manifest status is ok for each processed chunk
```

Red flags:

```text
Many endpoint_error rows
Many no_json_found rows
Many no_valid_score_json rows
Blank or repeated explanations
Scores missing for many LLM-called rows
Unexpectedly high missing Item 1 or Item 7
Unexpectedly high number of LLM calls
```

## Performance Notes

The endpoint can be slow. In testing, one LLM call took about 9 minutes.

This means `--prefilter-mode off` is not suitable for full chunks.

Approximate runtime:

```text
10 LLM calls   = about 1.5 hours
100 LLM calls  = about 15 hours
1000 LLM calls = not practical
```

Therefore, before running all chunks:

1. Estimate how many filings have keyword hits.
2. Use `--prefilter-mode hard_zero` for production-style tests.
3. Use `--prefilter-mode audit` to test false-zero risk.
4. Do not run `--all-chunks` until output quality and runtime are acceptable.

## Estimate LLM Calls For One Chunk

This does not call the LLM:

```bash
python3 - <<'PY'
import importlib.util
import sys

SCRIPT = "get_llama_score.py"
BUCKET = "jupyter.notebook.uktrade.io"
PREFIX_ENV = "S3_PREFIX_TEAM_EFFECT_OF_AI"

spec = importlib.util.spec_from_file_location("scoreqa", SCRIPT)
mod = importlib.util.module_from_spec(spec)
sys.modules["scoreqa"] = mod
spec.loader.exec_module(mod)

bucket, prefix = mod.parse_s3_location(BUCKET, None, PREFIX_ENV)
chunks = mod.list_chunks_s3(bucket, prefix)

ref = chunks["extract_df_chunk_00001.rds"]
df = mod.read_rds_s3(bucket, ref.key)
wide = mod.long_to_wide(df, include_amended=False)

wide["keyword_hits"] = wide["combined_text"].apply(mod.count_ai_keywords)

print("filings:", len(wide))
print("keyword-hit filings:", int((wide["keyword_hits"] > 0).sum()))
print("no-keyword filings:", int((wide["keyword_hits"] == 0).sum()))
print("keyword-hit rate:", round((wide["keyword_hits"] > 0).mean(), 4))

print("\nkeyword_hits summary:")
print(wide["keyword_hits"].describe())

print("\ntop keyword-hit filings:")
cols = ["accession_number", "cik", "year", "form_type", "keyword_hits", "combined_chars"]
print(wide[cols].sort_values("keyword_hits", ascending=False).head(20).to_string(index=False))
PY
```

## Recommended Scale-Up Order

Use this order before running all chunks:

```text
1 filing, prefilter off
25 filings, hard_zero
50 filings, hard_zero
200 filings, hard_zero
200 filings, audit
1 full chunk, hard_zero
2-3 full chunks, hard_zero
all chunks only after QA approval
```

## Current Known Issues

The process is currently in QA.

Known issues to monitor:

```text
Some LLM outputs may fail with no_json_found.
The endpoint is slow.
The hard-zero prefilter should be audited before final use.
The SageMaker output folder path may need a symlink in this environment.
```

## Full Run Example

Only run after QA approval:

```bash
python3 get_llama_score.py \
  --s3-bucket jupyter.notebook.uktrade.io \
  --s3-prefix-env S3_PREFIX_TEAM_EFFECT_OF_AI \
  --all-chunks \
  --prefilter-mode hard_zero \
  --max-prompt-chars 1500 \
  --max-new-tokens 80 \
  --checkpoint-every 25 \
  --retries 0 \
  --out-dir output/full_run \
  --log-level INFO
```

## Project Status

This project is under active QA. The data reading, reshaping, S3 access, and hard-zero prefilter have passed initial tests. Further QA is needed on LLM response quality, JSON parse reliability, runtime, and prefilter false-zero risk before running the full production process.
```