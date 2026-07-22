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
research_profile = llm_extraction_ai_1to3_v1
script_version   = 2026-07-22-llm_extraction_v1
prompt_version   = llm_extraction_claude_v1
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

The pipeline now uses one shared published dictionary:

1. `AI_KEYWORD_PATTERNS`
   This single keyword list is used for both the hard-zero prefilter and
   snippet ranking.

This keeps the process simpler and easier to document. A filing is sent to the
LLM only if this shared dictionary appears in the filing text, and the same
dictionary is used to find candidate sentences for excerpt construction. The
list is based on explicit AI, ML, and model-method terminology such as
`artificial intelligence`, `machine learning`, `computer vision`,
`natural language processing`, `neural networks`, `transformer`,
`reinforcement learning`, `OpenCV`, `XGBoost`, and `Word2vec`.

The one place where the implementation is intentionally stricter than the raw
term list is standalone `ML`: the code still counts `ML`, but it guards
against obvious false positives such as `mg/ml` dosage units or company initials
written as `(ML)`.

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

1. normalizes whitespace
2. splits into sentence-like segments
3. finds AI-ranked sentences
4. adds nearby context with `sentence_window`
5. scores windows using operational and low-value cues
6. returns the best excerpt up to `max_prompt_chars`

This keeps the prompt short enough for smaller instruct models while preserving
the most relevant context.

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
```

Per run:

```text
run_manifest_<RUN_ID>.csv
```

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
ranking_keyword_hits
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
  --model-label claude \
  --model-id eu.anthropic.claude-haiku-4-5-20251001-v1:0 \
  --prefilter-mode hard_zero \
  --max-prompt-chars 1800 \
  --sentence-window 1 \
  --max-new-tokens 128 \
  --temperature 0.0 \
  --out-dir output/final_llm_extraction
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
