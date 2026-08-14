# LLM Extraction Scoring Methodology

This folder contains the simplified LLM extraction pipeline for scoring firm AI
adoption from SEC 10-K text. The design is meant for empirical work where the
goal is a reproducible filing-level score, not a long-form model explanation.

## Research Target

The output is a disclosure-based 1-3 score of the firm's AI implementation
maturity in the filing evidence. The decision rules use implementation stage
and organizational scope or core integration. The model returns only the
derived score, so the downstream data contract is unchanged.

Rubric:

- `1`: no disclosed current AI implementation
- `2`: emerging or bounded AI implementation
- `3`: established and integrated AI implementation

Interpretation:

- `1` includes no disclosed firm implementation, industry or third-party
  context, risk discussion, plans, preliminary exploration, and general
  capacity building without a specific active application.
- `2` requires a concrete specific development, test, or pilot, or bounded
  current production use that does not satisfy score 3.
- `3` requires explicit current production or operational use **and** evidence
  of meaningful organizational scale or integration into a core activity.
  Strategy language and expected benefits alone are insufficient.

The logical derivation is:

```text
score 1: no concrete active firm implementation
score 2: concrete implementation AND (specific pilot OR bounded production use)
score 3: current production use AND (meaningful scale OR core integration)
```

A narrow use can therefore receive score 3 when it is demonstrably core. AI
may be developed internally or obtained externally, but it counts only with
evidence of active implementation or use, including in products or services
currently provided by the firm. Ambiguous evidence receives the lower score.

This is a measure of disclosed AI adoption, not a direct measure of true AI
deployment, AI capability, AI spending, or productivity.

## Frozen Research Profile

The pipeline is now frozen as:

```text
research_profile = llm_extraction_ai_1to3_v6
script_version   = 2026-08-14-llm_extraction_v15
prompt_version   = llm_extraction_claude_v6
```

Recommended default settings:

```text
model_label       = claude
model_id          = eu.anthropic.claude-sonnet-4-6
temperature       = 0.0
max_prompt_chars  = 10000
sentence_window   = 1
max_new_tokens    = 128
prefilter_mode    = hard_zero
max_analysis_year = 2025
```

Run this stage inside Data Workspace. If the environment does not already have
the dependencies, install them from this folder before scoring:

```bash
python3 -m pip install -r requirements.txt
```

These settings are written into the row-level CSV output and the chunk summary
JSON so runs can be reproduced later.

The v6 prompt uses a concise decision tree based only on implementation stage
and scope or core integration. Earlier score files remain valid as historical
outputs but must not be mixed with v6 files. The extracted EDGAR RDS chunks can
be reused; run v6 scoring into a new output directory.

## Why This Design

The workflow is intentionally narrow and conservative in structure:

1. one filing-level score per 10-K
2. one shared keyword dictionary
3. one concise ordinal decision framework
4. deterministic parsing and retry logic
5. stable prefilter and snippet extraction

This is closer to a text-classification pipeline than a free-form reasoning
prompt.

## Input Data

The scripts expect EDGAR chunk files such as:

```text
extract_df_chunk_00001.rds
extract_df_chunk_00002.rds
```

Each chunk should contain at least:

```text
item
year
accession_number
cik
form_type
text
```

The current EDGAR extractor writes multiple `keyword_window` rows per filing
from the whole 10-K or 10-K/A primary document. The loader preserves every
window in source order, joins them into one filing-level input, and includes
both forms. A filing with no extracted hit is represented by an empty-text
sentinel, allowing the scorer to retain it as a score-1 observation without an
LLM request instead of dropping it from the sample.

The study period ends in filing year 2025. `--max-analysis-year 2025` is the
default and removes later filings before prompt construction, including 2026
rows retained in older extraction chunks.

## Prefilter Design

`AI_KEYWORDS` is the single published source of truth for AI terminology. Each
entry carries its category, routing weight, ranking weight, case policy, and an
optional ambiguity check. Routing and ranking therefore use the same auditable
dictionary without treating every term as equally precise.

Explicit terms such as `artificial intelligence`, `machine learning`, and
`large language model` receive high routing and ranking weights. Ambiguous terms
such as `transformer`, `Claude`, and `Gemini` must pass local context checks and
receive lower ranking priority. Bare `learning model` has a non-routing weight;
it can appear only as context around a separately validated AI anchor.

Abbreviations are compiled independently. Standalone `AI`, `ML`, `NLP`, and
`LLM` use case-sensitive token boundaries, so dosage units such as `5 mL` do
not match `ML`. Known non-AI meanings such as `AI = American Indians`,
electrical transformers, remote learning models, and `Claude Bernard` are
excluded by deterministic disambiguation rules.

Recommended budget-constrained production mode:

```text
--prefilter-mode hard_zero
```

This repeats the deterministic keyword check before calling the LLM and keeps
the observed request count to approximately 10,281 after the year filter.
Empty no-hit sentinels still receive score 1 without an LLM request.

The higher-recall alternative is:

```text
--prefilter-mode off
```

`off` sends every non-empty filing-level extraction and produced 11,837 calls
in the current corpus, including 1,304 extracts rejected by the second keyword
pass.

Recommended audit mode for validation:

```text
--prefilter-mode audit --prefilter-audit-rate 0.02
```

## Filing Evidence Sent To The Model

The EDGAR stage has already reduced the full filing to merged keyword windows.
The default, `max_prompt_chars = 10000`, selects anchor-first
evidence within that limit. Direct keyword-hit text takes priority over
surrounding context.

With a positive character cap, the scorer:

1. normalizes whitespace while preserving newlines, bullets, headings, and lists
2. passes the complete filing-level extract through unchanged when it fits
3. only for extracts above the cap, creates bounded structural segments
4. finds validated dictionary matches with keyword-specific metadata
5. creates individual anchor candidates and removes near-duplicates
6. selects direct keyword evidence before surrounding context
7. adds context with the remaining budget and restores filing order

Selected anchors are independent of `sentence_window`: increasing the window
can add context, but it cannot remove an anchor. Context is truncated or
omitted before direct AI evidence is discarded.

In capped audit mode, a no-keyword extract that exceeds the cap ranks broader
technology, automation, analytics, algorithm, and intelligent-system proxy
segments and samples the beginning, middle, and end. Set `max_prompt_chars = 0`
to send the complete filing-level extraction instead.

## Prompt Design

The prompt is intentionally short:

```text
Classify the firm's disclosed AI adoption using the rules below.
Use only the extracted filing evidence; do not infer missing facts.
[frozen 1-3 rubric]
Choose the single best score.
Return only one character: 1, 2, or 3.
[extracted filing evidence]
```

`max_prompt_chars` limits only the extracted filing evidence, not the complete
request. The configured value `10000` produces a maximum 11,022-character
main prompt and an 11,106-character retry prompt. Set it to `0` to send every
extracted keyword window for the filing without a character cap. Complete
prompts are submitted to Bedrock without a second truncation step.

## Input Volume And Cost Benchmark

The previous local Sonnet run provides the relevant empirical benchmark. It
made 6,363 model calls with a 2,400-character evidence cap and only three
retries. Its maximum prompt-character envelope was 21.37 million characters.

After excluding 2026, the current corpus produces 10,281 calls under
`hard_zero`. A local preparation pass found that 745 calls (7.25%) exceed the
10,000-character evidence cap. Before anchor selection, applying the cap gives
a conservative upper estimate of 26.99 million evidence characters and 37.50
million total main-prompt characters before retries, retaining at most 77.9%
of all extracted evidence characters.

The 37.50-million-character upper estimate is 1.76 times the **maximum** prompt
envelope of the previous Sonnet run. It should therefore not be expected to
retain the previous sub-USD-5 cost. If that run was close to USD 5, a rough
proportional planning allowance is around USD 9 or more, subject to Data
Workspace pricing, tokenization, caching, and retry behavior. Because the
previous figure is an upper bound rather than its measured input volume, the
actual multiplier could be higher.

For a workload close to the previous sub-USD-5 envelope, explicitly use
`--max-prompt-chars 900`; its 19.76-million-character maximum is about 7.5%
below the previous envelope. The project default remains 10,000 as a compromise
between context retention and cost.

Prompt principles:

- decide only from filing text
- no chain-of-thought
- no JSON output
- no evidence-summary field
- one final score only
- if the text is weak or only speculative, stay at the lower score

## Parsing Rules

The parser accepts:

- an exact response of `1`, `2`, or `3`
- a JSON fallback containing a score field
- a single unambiguous score token in the response

If the model returns conflicting scores, the row is marked failed and retried
once with a stricter score-only prompt.

## Main Outputs

Per chunk:

```text
extract_df_chunk_XXXXX_claude_scores.csv
extract_df_chunk_XXXXX_claude_summary.json
extract_df_chunk_XXXXX_claude_snippet_audit.csv
```

The snippet-audit CSV contains one row for every filing in the chunk. Filings
submitted to the LLM have `llm_processed = True` and retain the exact
`snippet_text` sent to the model. Prefiltered filings remain visible with an
empty snippet and `snippet_text_length = 0`. The table also records
`max_prompt_chars` and `snippet_at_limit`. In unlimited mode,
`max_prompt_chars = 0` and `snippet_at_limit = False`.

Per run:

```text
run_manifest_<RUN_ID>.csv
```

Running `merge_outputs.py` over the chunk folder writes:

```text
llm_extraction_snippet_audit.csv
llm_extraction_filing_master.csv
llm_extraction_firm_year_panel.csv
```

Duplicate accessions stop the merge and are written to
`filing_accession_duplicates.csv` for review. The extractor keeps all windows
for one accession in the same input chunk, so duplicates indicate overlapping
score outputs rather than a valid filing split.

Important output fields:

```text
run_id
script_version
prompt_version
research_profile
llm_model
temperature
max_new_tokens
max_prompt_chars
sentence_window
prefilter_mode
keyword_hits
llm_called
parse_status
score_status
ai_score
ai_score_label
score_explanation
```

## Recommended Production Command

```bash
python3 get_ai_score_bulk.py \
  --team effect_of_ai \
  --chunk-prefix edgar_keyword_windows_full \
  --all-chunks \
  --lookup-csv ../lookup/cik_year.csv \
  --max-analysis-year 2025 \
  --model-id eu.anthropic.claude-sonnet-4-6 \
  --prefilter-mode hard_zero \
  --max-prompt-chars 10000 \
  --sentence-window 1 \
  --skip-existing \
  --out-dir output/final_llm_extraction
```

Use a new, clean `--chunk-prefix` containing only the RDS files from one EDGAR
run. The scorer deliberately requires `--all-chunks` or another explicit chunk
selection option; it will not guess which uploaded files should be processed.
`--skip-existing` skips a chunk only when its stored profile, model, prefilter,
prompt budget, source path, and other scoring settings match the current run.
Incompatible outputs stop that chunk instead of being silently reused.

The command exits nonzero when a chunk fails or any filing remains unscored.
Inspect the run manifest and repair or rerun incomplete chunks before merging.

`temperature` and `max_new_tokens` are fixed by the frozen research profile.
After scoring, aggregate the chunk outputs with:

```bash
python3 merge_outputs.py \
  --primary-dir output/final_llm_extraction/RUN_ID \
  --primary-label claude \
  --out-dir output/final_merged
```

## Interpretation For Empirical Use

The recommended main treatment is:

```text
ai_score ∈ {1, 2, 3}
```

Suggested interpretation:

- `1` means no current AI implementation is disclosed
- `2` means emerging or bounded AI implementation is disclosed
- `3` means established and integrated AI implementation is disclosed

For new extraction runs, this variable should be described in papers as a
disclosure-based AI adoption score built from AI-keyword sentence windows in
whole 10-K and 10-K/A primary documents using a frozen prompt and deterministic
post-processing rules.

## Limitations

- It measures disclosed adoption, not latent adoption.
- It depends on the research sample and EDGAR text extraction quality.
- The hard-zero prefilter excludes 1,304 non-empty extracts in the full corpus,
  and the 10,000-character evidence cap truncates up to 745 model-bound extracts
  in the current through-2025 corpus. Use `--prefilter-mode off
  --max-prompt-chars 0` only when maximum recall takes priority over cost.
- Small LLMs can still make classification errors, which is why the workflow
  keeps prompt structure minimal and output parsing strict.
