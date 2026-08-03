# LLM Extraction Scoring Methodology

This folder contains the simplified LLM extraction pipeline for scoring firm AI
adoption from SEC 10-K text. The design is meant for empirical work where the
goal is a reproducible filing-level score, not a long-form model explanation.

## Research Target

The output is a disclosure-based 1-3 score of the firm's level of current AI
adoption in the filing text.

Rubric:

- `1`: no current AI adoption
- `2`: limited or targeted AI adoption
- `3`: production-level or strategic AI adoption

Interpretation:

- `1` includes no AI mention, industry context only, competitor discussion,
  future plans, exploration, or risk language.
- `2` includes early implementation, limited use cases, or clear AI use in
  some products or operations, without evidence that AI is central to strategy
  or financial performance.
- `3` includes production-level deployment, strategic importance, or explicit
  links to cost savings, revenue, performance, or broad operational use.

This is a measure of disclosed AI adoption, not a direct measure of true AI
deployment, AI capability, AI spending, or productivity.

## Frozen Research Profile

The pipeline is now frozen as:

```text
research_profile = llm_extraction_ai_1to3_v2
script_version   = 2026-08-01-llm_extraction_v5
prompt_version   = llm_extraction_claude_v2
```

Recommended default settings:

```text
model_label       = claude
model_id          = eu.anthropic.claude-haiku-4-5-20251001-v1:0
temperature       = 0.0
max_prompt_chars  = 1800
sentence_window   = 1
max_new_tokens    = 128
prefilter_mode    = hard_zero
```

These settings are written into the row-level CSV output and the chunk summary
JSON so runs can be reproduced later.

## Why This Design

The workflow is intentionally narrow and conservative in structure:

1. one filing-level score per 10-K
2. one shared keyword dictionary
3. one short ordinal rubric
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

The pipeline reshapes the long data into one filing-level row using:

- Item 1 (Business)
- Item 7 (MD&A)

By default it keeps only `10-K`. Use `--include-amended` to include `10-K/A`.

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

Recommended production mode:

```text
--prefilter-mode hard_zero
```

Recommended audit mode for validation:

```text
--prefilter-mode audit --prefilter-audit-rate 0.02
```

## Snippet Extraction

The model does not receive the full filing. The code:

1. preserves newlines, bullets, section headings, and list separators
2. creates bounded structural segments and protects against unusually long lists
3. finds validated dictionary matches with keyword-specific metadata
4. creates and scores individual anchor candidates
5. detects operational language only when it is close to an AI term
6. removes exact and near-duplicate disclosure
7. selects distinct anchors first using the available character budget
8. adds preceding and following context only with the remaining budget
9. returns the final excerpt in deterministic filing order

The selected anchors are independent of `sentence_window`: increasing the
window can add context, but it cannot remove an anchor. Context is truncated or
omitted before direct AI evidence is discarded.

For sampled no-keyword audits, the extractor ranks broader technology,
automation, analytics, algorithm, and intelligent-system proxy segments and
also samples the beginning, middle, and end of the filing. It no longer audits
only the first `max_prompt_chars` characters.

## Prompt Design

The prompt is intentionally short:

```text
You are an expert analyst.
Using the rubric below, assign one integer score from 1 to 3 for the firm's level of AI adoption.
Return only one character: 1, 2, or 3.
```

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
`max_prompt_chars` and `snippet_at_limit` so truncation can be audited directly.

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

If an accession boundary from an older extraction run placed Item 1 and Item 7
in adjacent chunks, the merger coalesces those complementary rows when their
scores agree. True overlaps and conflicting fragment scores still stop the
merge and are written to `filing_accession_duplicates.csv` for review.

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
  --lookup-csv ../lookup/cik_year.csv \
  --model-id eu.anthropic.claude-haiku-4-5-20251001-v1:0 \
  --prefilter-mode hard_zero \
  --max-prompt-chars 1800 \
  --sentence-window 1 \
  --out-dir output/final_llm_extraction
```

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

- `1` means no current AI adoption is disclosed
- `2` means limited or targeted AI adoption is disclosed
- `3` means production-level or strategic AI adoption is disclosed

This variable should be described in papers as a disclosure-based AI adoption
score built from 10-K Item 1 and Item 7 text using a frozen prompt and
deterministic post-processing rules.

## Limitations

- It measures disclosed adoption, not latent adoption.
- It depends on the research sample and EDGAR text extraction quality.
- Hard-zero prefiltering can still miss adopters if the explicit AI dictionary
  misses a term, so periodic audit-mode validation is still good practice.
- Small LLMs can still make classification errors, which is why the workflow
  keeps prompt structure minimal and output parsing strict.
