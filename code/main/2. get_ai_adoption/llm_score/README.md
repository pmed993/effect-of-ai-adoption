# AI Adoption Labeling Methodology

This folder contains the finalized binary LLM pipeline for measuring disclosed
firm AI adoption from SEC 10-K text. The design is meant for empirical work in
economics and finance where the target is a reproducible text-based treatment
measure, not a free-form narrative summary.

## Research Target

The output is a disclosure-based measure of whether the filing indicates that
the firm itself uses or is implementing AI.

What counts:

- a concrete firm-specific AI application
- an AI-enabled feature in the firm's own product or service
- a concrete AI implementation, rollout, or integration in operations
- a specific internal function that uses AI

What does not count:

- generic AI discussion or market trends
- AI risk disclosure only
- exploration, evaluation, partnerships, or hiring without a concrete use
- customer use only
- AI demand, AI-capable hardware, chips, cloud, or enabling infrastructure
- product or platform names that mention AI but do not explain what the AI does
- vague analytics or automation language without explicit AI or ML use

This is a measure of disclosed AI adoption, not a direct measure of true AI
deployment, AI capability, AI spending, or productivity.

## Frozen Research Profile

The pipeline is now frozen as:

```text
research_profile = disclosed_ai_adoption_binary_v2
script_version   = 2026-07-10-ai_binary_research_v2
prompt_version   = ai_binary_adoption_research_v2
```

Recommended default settings:

```text
model_label       = llama
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

1. one filing-level binary decision per 10-K
2. minimal JSON output
3. positive evidence summary only
4. deterministic parsing and retry logic
5. stable prefilter and snippet extraction

This is closer to the text-classification literature than a looser prompt that
asks the model to reason at length or produce multiple labels at once.

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

The prefilter now has two distinct dictionaries:

1. `AI_TRIGGER_PATTERNS`
   These are explicit AI terms used for the hard-zero call decision.

2. `AI_RANKING_ONLY_PATTERNS`
   These are broader AI-adjacent terms used only for snippet ranking.

This distinction matters. For research use, a filing should not be forced into
the LLM queue just because it says `predictive analytics` or `big data`, but
those phrases can still help rank nearby sentences once an explicit AI mention
exists in the filing. The trigger list also avoids ambiguous standalone
abbreviations such as bare `ML`, which can appear in non-AI contexts like
measurement units or company initials.

Examples of explicit trigger terms:

```text
AI
NLP
artificial intelligence
machine learning
deep learning
generative AI
large language model
AI/ML
AI-powered
AI-enabled
```

Examples of ranking-only terms:

```text
predictive analytics
fraud detection
anomaly detection
business intelligence
data mining
pattern recognition
robotic process automation
```

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

The prompt asks only for a binary label plus positive evidence:

```json
{
  "ai_adoption": 0,
  "evidence_summary": ""
}
```

Prompt principles:

- decide only from filing text
- no chain-of-thought
- no zero-reason taxonomy
- positive cases require a short evidence summary
- zero cases return an empty evidence summary
- output exactly one JSON object
- if uncertain, choose 0

The model is not asked to produce `qualifying_evidence_found` or a reason code
for zero. Those are derived or left blank by the parser for compatibility.

## Parsing Rules

The parser accepts valid JSON objects and applies deterministic rules:

- `ai_adoption = 1` requires a non-empty `evidence_summary`
- positive rows are stored with `qualifying_evidence_found = true`
- zero rows are stored with `qualifying_evidence_found = false`
- `exclusion_reason_if_zero` is retained as a compatibility column but is blank
  in the finalized binary workflow

If the first response is malformed, the row gets one retry with a stricter
JSON-only prompt.

## Main Outputs

Per chunk:

```text
extract_df_chunk_XXXXX_llama_scores.csv
extract_df_chunk_XXXXX_llama_summary.json
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
ai_adoption
qualifying_evidence_found
evidence_summary
```

## Recommended Production Command

```bash
python3 get_ai_score_bulk.py \
  --team effect_of_ai \
  --lookup-csv ../lookup/cik_year.csv \
  --model-label llama \
  --prefilter-mode hard_zero \
  --max-prompt-chars 1800 \
  --sentence-window 1 \
  --max-new-tokens 128 \
  --temperature 0.0 \
  --out-dir output/final_llama_binary
```

## Interpretation For Empirical Use

The recommended main treatment is:

```text
ai_adoption ∈ {0, 1}
```

Suggested interpretation:

- `1` means the firm discloses a concrete AI use or implementation in the filing
- `0` means the filing does not disclose such evidence under this rule

This variable should be described in papers as a disclosure-based AI adoption
measure built from 10-K Item 1 and Item 7 text using a frozen prompt and
deterministic post-processing rules.

## Limitations

- It measures disclosed adoption, not latent adoption.
- It depends on the research sample and EDGAR text extraction quality.
- Hard-zero prefiltering can still miss adopters if the explicit AI dictionary
  misses a term, so periodic audit-mode validation is still good practice.
- Small LLMs can still make classification errors, which is why the workflow
  keeps prompt structure minimal and output parsing strict.
