#!/usr/bin/env python3
"""
get_llm_score_qa.py

S3-only filing-level LLM scoring for EDGAR extract_df_chunk_XXXXX.rds files.

What it does
------------
1. Lists or reads chunk files from one S3 prefix.
2. Converts long-format Item 1 / Item 7 rows to one row per filing.
3. Sends relevant filing snippets to a Llama endpoint.
4. Writes one score CSV and one summary JSON per chunk.

Because the file chunks live in a S3 buckets, the only input location you need is:

    s3://BUCKET/PREFIX/extract_df_chunk_00001.rds

Use --s3-bucket BUCKET and --s3-prefix PREFIX. Or paste a full S3 URI
into --s3-prefix, for example:
  --s3-prefix s3://jupyter.notebook.uktrade.io/path/to/chunks
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
import re
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

import pandas as pd


# ---------------------------------------------------------------------------
# Configuration and text patterns
# ---------------------------------------------------------------------------
# Make output produced tracable, if i.e., the prompt or script logic
# changes, bump these values so later CSVs show exactly which version produced
# them.
SCRIPT_VERSION = "2026-04-18"
PROMPT_VERSION = "llama_ai_adoption_v3_filing_time"

DEFAULT_ENDPOINT = "jupyterhub-llama-3-3b-instruct-endpoint"
DEFAULT_S3_BUCKET = "jupyter.notebook.uktrade.io"

# Only files with this exact chunk naming pattern are treated as input chunks.
CHUNK_RE = re.compile(r"^extract_df_chunk_(\d{5})\.rds$")

# AI_KEYWORDS is used for two things:
# 1. deciding which sentences are relevant enough to send to the LLM
# 2. optionally assigning zero to no-keyword filings in prefilter modes
#
# Bare lowercase "ml" is intentionally not matched, because it often means
# milliliters. Uppercase "ML" still matches.
AI_KEYWORDS = re.compile(
    r"(?i:"
    r"\bartificial intelligence\b|"
    r"\bmachine learning\b|"
    r"\bdeep learning\b|"
    r"\bneural networks?\b|"
    r"\bpredictive models?\b|"
    r"\balgorithmic\b|"
    r"\bautomated decisions?\b|"
    r"\bautomated underwriting\b|"
    r"\brecommendation engines?\b|"
    r"\brecommendation systems?\b|"
    r"\bdecision engines?\b|"
    r"\bpersonalization engines?\b|"
    r"\bcomputer vision\b|"
    r"\bnatural language processing\b|"
    r"\bnatural language generation\b|"
    r"\bgenerative ai\b|"
    r"\bgenai\b|"
    r"\blarge language models?\b|"
    r"\bllms?\b|"
    r"\bnlp\b|"
    r"\brobotic process automation\b|"
    r"\bautonomous systems?\b|"
    r"\bfraud detection models?\b|"
    r"\boptimization engines?\b"
    r")|"
    r"\bAI\b|"
    r"\bA\.I\.\b|"
    r"\bML\b|"
    r"\bRPA\b"
)

# These cues help rank candidate snippets. They do not create the final score;
# they only help decide which parts of a long filing the LLM should see first.
OPERATIONAL_CUES = re.compile(
    r"(?i)\b("
    r"use|uses|used|using|deploy|deploys|deployed|deployment|implemented|implements|"
    r"integrated|integrates|embedded|operates|operational|automate|automates|automated|"
    r"recommend|recommends|detect|detects|forecast|forecasts|predict|predicts|"
    r"underwrite|underwrites|optimize|optimizes|personalize|personalizes"
    r")\b"
)

# Low-value cues are common in risk factors and future-looking language. They
# are down-ranked during snippet selection so boilerplate does not crowd out
# operational evidence.
LOW_VALUE_CUES = re.compile(
    r"(?i)\b("
    r"risk|risks|could|may|might|intend|intends|plan|plans|future|potential|"
    r"regulation|regulatory|competition|competitors|cybersecurity|pilot|pilots|"
    r"proof of concept|experiment|experiments|research"
    r")\b"
)

SENTENCE_SPLIT_RE = re.compile(r"(?<=[\.\!\?\;])\s+|\n+")
WHITESPACE_RE = re.compile(r"\s+")


# ---------------------------------------------------------------------------
# Small data containers and utility helpers
# ---------------------------------------------------------------------------
@dataclass
class ChunkRef:
    """Minimal reference to one chunk found under the S3 prefix."""

    name: str
    key: str


def utc_now() -> str:
    """Return a compact UTC timestamp used as the run id."""

    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def sha256_text(text: str) -> str:
    """Hash text so outputs can be audited without storing full snippets."""

    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def stable_unit_interval(value: str) -> float:
    """Map a string to a stable 0-to-1 value for reproducible audit sampling."""

    digest = hashlib.sha256(value.encode("utf-8")).hexdigest()
    return int(digest[:16], 16) / float(16 ** 16)


def normalize_whitespace(text: Any) -> str:
    """Convert missing values to empty strings and collapse noisy whitespace."""

    if text is None or (isinstance(text, float) and pd.isna(text)):
        return ""
    text = str(text).replace("\x00", " ")
    text = WHITESPACE_RE.sub(" ", text)
    return text.strip()


def count_ai_keywords(text: str) -> int:
    """Count AI keyword hits using the shared keyword pattern."""

    return len(list(AI_KEYWORDS.finditer(text))) if text else 0


def preferred_output_columns(save_raw_json: bool) -> List[str]:
    """Define the CSV column order so every output chunk has the same shape."""

    cols = [
        "run_id",
        "script_version",
        "prompt_version",
        "source_label",
        "chunk_id",
        "accession_number",
        "cik",
        "year",
        "form_type",
        "has_item1",
        "has_item7",
        "item1_chars",
        "item7_chars",
        "combined_chars",
        "keyword_hits",
        "prefilter_mode",
        "prefilter_decision",
        "prefilter_audit_sample",
        "snippet_chars",
        "llm_called",
        "endpoint_attempts",
        "ai_adoption_score",
        "explanation",
        "score_status",
        "endpoint",
        "job_id",
        "snippet_sha256",
        "raw_json_sha256",
    ]
    if save_raw_json:
        cols.append("raw_json")
    return cols


# ---------------------------------------------------------------------------
# Prompt construction and model-output parsing
# ---------------------------------------------------------------------------
def build_ai_prompt(text: str) -> str:
  
    """
    Build the instruction sent to the model.

    The prompt is deliberately long because it defines the scoring concept,
    what should not count, and the required JSON output format.
    """
    
    return (
        "You are an academic research assistant measuring firm-level artificial intelligence adoption from SEC Form 10-K disclosures.\n\n"
        "TASK\n"
        "Read the filing text and estimate the firm's level of AI adoption as described in this filing, at the time covered by the filing text.\n"
        "After reading the filing text, return exactly two fields in valid JSON: score and explanation.\n\n"
        "CONCEPT TO MEASURE\n"
        "AI adoption means the extent to which AI, machine learning, algorithmic systems, or automated decision systems are already implemented and embedded in the firm's core business activities.\n"
        "This includes adoption in products, services, operations, production, logistics, underwriting, forecasting, recommendations, fraud detection, pricing, internal decision systems, or other strategically relevant processes.\n\n"
        "IMPORTANT: FOCUS ONLY ON FIRM-SPECIFIC, OPERATIONAL USE DURING THE FILING PERIOD\n"
        "Score only based on evidence that the firm itself is using AI in a meaningful way in the business described by the filing.\n\n"
        "DO NOT SCORE HIGHLY FOR THE FOLLOWING ALONE\n"
        "- mere mention of AI, machine learning, or automation\n"
        "- generic discussion of industry trends\n"
        "- speculative future plans or intentions\n"
        "- research, experiments, pilots, or proofs of concept with no evidence of deployment\n"
        "- boilerplate innovation language\n"
        "- risk factors mentioning AI competition, regulation, or cybersecurity\n"
        "- references to third-party technology unless the text shows the firm has operationally integrated it\n\n"
        "WHAT SHOULD INCREASE THE SCORE\n"
        "- clear evidence that AI is already deployed in products, services, or internal operations\n"
        "- AI tied to revenue generation, product delivery, cost reduction, efficiency, or decision-making\n"
        "- distinct evidence of deployment across meaningful business functions\n"
        "- AI embedded in core business segments rather than peripheral activities\n"
        "- AI described as strategically important to how the firm operates or competes\n\n"
        "SCORING GUIDANCE\n"
        "0.00 = no explicit evidence of AI adoption in the filing text\n"
        "0.01 to 0.10 = very weak evidence; vague references, early exploration, or non-operational discussion\n"
        "0.11 to 0.30 = limited adoption; some specific use cases but narrow, tentative, or not central\n"
        "0.31 to 0.50 = moderate adoption; clear operational use in some relevant business areas\n"
        "0.51 to 0.70 = substantial adoption; AI is integrated into multiple important functions or products\n"
        "0.71 to 0.90 = extensive adoption; AI is deeply embedded in operations and materially relevant to the business\n"
        "0.91 to 1.00 = AI is fundamental to the firm's core business model and competitive functioning\n\n"
        "DECISION RULES\n"
        "- Use the full 0.00 to 1.00 range.\n"
        "- Avoid coarse rounding such as only 0.2, 0.5, or 0.8.\n"
        "- Base the score only on the text provided.\n"
        "- Do not infer adoption from the industry the firm operates in.\n"
        "- Do not reward aspiration more than implementation.\n\n"
        "TEXT TO EVALUATE:\n"
        "<filing_text>\n"
        f"{text}\n"
        "</filing_text>\n\n"
        "Now produce the score for the filing text above.\n"
        "Return ONLY one valid JSON object and no other text.\n"
        "The JSON object must have this shape:\n"
        "{\"score\": NUMBER_BETWEEN_0_AND_1, \"explanation\": \"ONE_SHORT_PARAGRAPH\"}\n"
        "Do not copy the template. Replace NUMBER_BETWEEN_0_AND_1 with a numeric score between 0.00 and 1.00.\n"
        "Do not return markdown, bullets, headings, or any text before or after the JSON."
        )
      

def extract_text_from_response(resp: Any) -> str:
    """
    Pull generated text from common endpoint response shapes.

    Different hosted LLM endpoints return different object structures. This
    recursive helper keeps the rest of the code independent of those details.
    """

    if resp is None:
        return ""
    if isinstance(resp, str):
        return resp
    if isinstance(resp, list):
        for item in resp:
            txt = extract_text_from_response(item)
            if txt:
                return txt
        return json.dumps(resp, ensure_ascii=False)
    if isinstance(resp, dict):
        for key in ["generated_text", "text", "output", "response", "completion", "content"]:
            if key in resp and resp[key] is not None:
                txt = extract_text_from_response(resp[key])
                if txt:
                    return txt
        for key in ["choices", "message", "outputs"]:
            if key in resp:
                txt = extract_text_from_response(resp[key])
                if txt:
                    return txt
        return json.dumps(resp, ensure_ascii=False)
    return str(resp)


def extract_balanced_json_objects(text: str) -> List[str]:
    """
    Extract all balanced JSON-looking objects from a text response.

    The code tracks quotes and escape characters so braces inside strings do
    not break the extraction.
    """

    objects: List[str] = []
    if not text:
        return objects

    start = 0
    while start < len(text):
        if text[start] != "{":
            start += 1
            continue

        depth = 0
        in_string = False
        escape = False
        found_end = None

        for i in range(start, len(text)):
            ch = text[i]
            if in_string:
                if escape:
                    escape = False
                elif ch == "\\":
                    escape = True
                elif ch == '"':
                    in_string = False
                continue

            if ch == '"':
                in_string = True
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    found_end = i
                    break

        if found_end is None:
            start += 1
        else:
            objects.append(text[start:found_end + 1])
            start = found_end + 1

    return objects


def parse_score_object(obj: Any) -> Tuple[Any, str, str]:
    """Validate one parsed JSON object and return score, explanation, status."""

    if not isinstance(obj, dict):
        return pd.NA, "Parsed JSON was not an object.", "json_not_object"

    try:
        score = float(obj.get("score"))
    except Exception:
        return pd.NA, "Score field was not numeric.", "non_numeric_score"

    if not (0.0 <= score <= 1.0):
        return pd.NA, "Score was outside [0,1].", "score_out_of_bounds"

    explanation = obj.get("explanation", "")
    if not isinstance(explanation, str):
        explanation = "" if explanation is None else str(explanation)
    explanation = " ".join(explanation.split()).strip() or "No explanation returned."

    return score, explanation, "ok"


def parse_model_output(text: str) -> Tuple[Any, str, str, str]:
    """
    Convert raw model text into a score record.

    Try JSON objects from last to first. Some endpoints echo the prompt, and the
    prompt contains an example JSON object, so using the first object is unsafe.
    """
    if not text:
        return pd.NA, "No model output returned.", "missing_output", ""

    candidates = extract_balanced_json_objects(text)
    if not candidates:
        return pd.NA, "Model output did not contain valid JSON.", "no_json_found", ""

    last_candidate = candidates[-1]
    for jtxt in reversed(candidates):
        try:
            obj = json.loads(jtxt)
        except Exception:
            continue
        score, explanation, status = parse_score_object(obj)
        if status == "ok":
            return score, explanation, "ok", jtxt

    return pd.NA, "Model output did not contain usable score JSON.", "no_valid_score_json", last_candidate


# ---------------------------------------------------------------------------
# Snippet extraction
# ---------------------------------------------------------------------------
def split_into_sentences(text: str) -> List[str]:
    """Split a filing section into rough sentences for snippet selection."""

    text = normalize_whitespace(text)
    if not text:
        return []
    return [p.strip() for p in SENTENCE_SPLIT_RE.split(text) if p and p.strip()] or [text]


def extract_relevant_snippets(full_text: str, max_chars: int, sentence_window: int) -> str:
    """
    Pull the most relevant filing text to fit into the prompt.

    Full 10-K sections can be too long for the endpoint. This keeps sentences
    around AI keyword hits, ranks operational-looking windows above boilerplate,
    and then returns the selected text in original filing order.
    """
    full_text = normalize_whitespace(full_text)
    if not full_text:
        return ""

    sentences = split_into_sentences(full_text)
    hit_idx = [i for i, s in enumerate(sentences) if AI_KEYWORDS.search(s)]
    if not hit_idx:
        return full_text[:max_chars]

    windows = []
    for idx in hit_idx:
        # Build a small context window around each keyword-hit sentence.
        lo = max(0, idx - sentence_window)
        hi = min(len(sentences), idx + sentence_window + 1)
        indices = list(range(lo, hi))

        # Rank windows so deployed/operational language is more likely to be
        # included than generic risk or future-looking language.
        window_text = " ".join(sentences[i] for i in indices)
        score = 0
        if OPERATIONAL_CUES.search(window_text):
            score += 4
        if OPERATIONAL_CUES.search(sentences[idx]):
            score += 2
        if LOW_VALUE_CUES.search(sentences[idx]):
            score -= 2
        if LOW_VALUE_CUES.search(window_text):
            score -= 1
        windows.append((score, idx, indices))

    windows.sort(key=lambda x: (-x[0], x[1]))

    # Select the best-ranked windows without repeating sentences.
    selected = set()
    approx_chars = 0
    for _, _, indices in windows:
        new_indices = [i for i in indices if i not in selected]
        if not new_indices:
            continue
        new_chars = sum(len(sentences[i]) for i in new_indices) + 2 * len(new_indices)
        if approx_chars and approx_chars + new_chars > max_chars:
            continue
        selected.update(new_indices)
        approx_chars += new_chars
        if approx_chars >= max_chars:
            break

    # Emit the chosen sentences in document order so the LLM sees coherent text.
    chunks = []
    used = 0
    last_i = None
    for i in sorted(selected):
        prefix = " " if chunks and last_i is not None and i == last_i + 1 else "\n\n"
        candidate = (prefix + sentences[i]) if chunks else sentences[i]
        if used + len(candidate) > max_chars:
            remaining = max_chars - used
            if remaining > 150:
                chunks.append(candidate[:remaining].rstrip())
            break
        chunks.append(candidate)
        used += len(candidate)
        last_i = i

    return "".join(chunks).strip() or full_text[:max_chars]


# ---------------------------------------------------------------------------
# S3 input and chunk selection
# ---------------------------------------------------------------------------
def parse_s3_location(bucket: str, prefix: Optional[str], prefix_env: Optional[str]) -> Tuple[str, str]:
    """
    Normalize S3 location arguments.

    Users can pass bucket/prefix separately or paste a full s3://bucket/prefix
    URI into --s3-prefix. This returns the final bucket and prefix either way.
    """

    if not prefix and prefix_env:
        prefix = os.getenv(prefix_env, "")
    if not prefix:
        raise ValueError("Provide --s3-prefix, for example: --s3-prefix path/to/chunks")

    prefix = prefix.strip()
    if prefix.startswith("s3://"):
        without_scheme = prefix[len("s3://"):]
        parts = without_scheme.split("/", 1)
        if len(parts) == 1:
            raise ValueError("Full S3 URI must include a prefix after the bucket name.")
        bucket = parts[0]
        prefix = parts[1]

    return bucket.strip(), prefix.strip().strip("/")


def get_s3_client() -> Any:
    """Create a boto3 S3 client, with a clear install error if boto3 is missing."""

    try:
        import boto3
    except ImportError as exc:
        raise RuntimeError("boto3 is not installed. Run: pip install boto3") from exc
    return boto3.client("s3")


def list_chunks_s3(bucket: str, prefix: str) -> Dict[str, ChunkRef]:
    """Find all valid extract_df_chunk_XXXXX.rds files under one S3 prefix."""

    s3 = get_s3_client()
    paginator = s3.get_paginator("list_objects_v2")

    refs: Dict[str, ChunkRef] = {}
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix.rstrip("/") + "/"):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            name = key.rsplit("/", 1)[-1]
            if CHUNK_RE.match(name):
                refs[name] = ChunkRef(name=name, key=key)

    return dict(sorted(refs.items()))


def read_rds_s3(bucket: str, key: str) -> pd.DataFrame:
    """
    Download one RDS chunk from S3 to a temporary file and read it as a DataFrame.

    pyreadr expects a file path, so the temporary local file is only an
    implementation detail and is deleted automatically.
    """

    try:
        import pyreadr
    except ImportError as exc:
        raise RuntimeError("pyreadr is not installed. Run: pip install pyreadr") from exc

    s3 = get_s3_client()
    with tempfile.NamedTemporaryFile(suffix=".rds", delete=True) as tmp:
        s3.download_file(bucket, key, tmp.name)
        result = pyreadr.read_r(tmp.name)

    if not result:
        raise ValueError(f"No readable objects found in s3://{bucket}/{key}")

    df = next(iter(result.values()))
    if not isinstance(df, pd.DataFrame):
        raise TypeError(f"First object in s3://{bucket}/{key} is not a data frame.")

    return df


def chunk_name_from_id(chunk_id: int) -> str:
    """Convert chunk id 1 to extract_df_chunk_00001.rds."""

    if chunk_id < 1:
        raise ValueError("Chunk ids must be positive integers.")
    return f"extract_df_chunk_{chunk_id:05d}.rds"


def select_chunks(
    available: Dict[str, ChunkRef],
    chunk_names: Optional[Sequence[str]],
    chunk_ids: Optional[Sequence[int]],
    chunk_range: Optional[Sequence[int]],
    all_chunks: bool,
    max_chunks: Optional[int],
) -> List[ChunkRef]:
    """
    Resolve the user's chunk selection into concrete S3 objects.

    The command line allows several selection styles: exact names, numeric ids,
    numeric ranges, or all chunks under the prefix.
    """

    names: List[str] = []

    if chunk_names:
        names = [Path(name).name for name in chunk_names]
        bad = [name for name in names if not CHUNK_RE.match(name)]
        if bad:
            raise ValueError(f"Invalid chunk filename(s): {bad}")
    elif chunk_ids:
        names = [chunk_name_from_id(int(chunk_id)) for chunk_id in chunk_ids]
    elif chunk_range:
        start, end = int(chunk_range[0]), int(chunk_range[1])
        if end < start:
            raise ValueError("--chunk-range requires START <= END")
        names = [chunk_name_from_id(chunk_id) for chunk_id in range(start, end + 1)]
    elif all_chunks:
        selected = list(available.values())
        return selected[:max_chunks] if max_chunks else selected
    else:
        raise ValueError("No chunks selected. Use --chunk-ids, --chunk-range, --chunk-names, or --all-chunks.")

    selected = []
    for name in names:
        if name not in available:
            raise FileNotFoundError(f"Chunk not found under the S3 prefix: {name}")
        selected.append(available[name])

    deduped = []
    seen = set()
    for ref in selected:
        if ref.key not in seen:
            deduped.append(ref)
            seen.add(ref.key)

    return deduped[:max_chunks] if max_chunks else deduped


# ---------------------------------------------------------------------------
# Data reshaping
# ---------------------------------------------------------------------------
def long_to_wide(df: pd.DataFrame, include_amended: bool) -> pd.DataFrame:
    """
    Convert long-format filing section rows to one row per filing.

    Input has one row per filing section. Output has one row per accession
    number with Item 1 and Item 7 text side by side.
    """

    required = {"item", "year", "accession_number", "cik", "form_type", "text"}
    missing = required - set(df.columns)
    if missing:
        raise ValueError(f"Missing required columns: {sorted(missing)}")

    # Normalize key fields before filtering and grouping.
    work = df.copy()
    work["item"] = work["item"].astype(str).str.strip().str.lower()
    work["form_type"] = work["form_type"].astype(str).str.upper().str.strip()
    work["accession_number"] = work["accession_number"].astype(str).str.strip()
    work["cik"] = work["cik"].astype(str).str.strip()
    work["text"] = work["text"].apply(normalize_whitespace)

    # Keep only annual 10-K filings and the two sections used for scoring.
    keep_forms = {"10-K", "10-K/A"} if include_amended else {"10-K"}
    work = work[work["form_type"].isin(keep_forms)]
    work = work[work["item"].isin(["item1", "item7"])]

    base_cols = [
        "accession_number",
        "cik",
        "year",
        "form_type",
        "item1_text",
        "item7_text",
        "has_item1",
        "has_item7",
        "item1_chars",
        "item7_chars",
        "combined_text",
        "combined_chars",
    ]
    if work.empty:
        return pd.DataFrame(columns=base_cols)

    # If a filing-section appears multiple times, collapse duplicate text before
    # pivoting to wide format.
    collapsed = (
        work.groupby(["accession_number", "cik", "year", "form_type", "item"], as_index=False)
        .agg(text=("text", lambda x: " ".join([t for t in pd.unique(x) if t])))
    )

    # Pivot item1 and item7 into separate columns.
    wide = collapsed.pivot_table(
        index=["accession_number", "cik", "year", "form_type"],
        columns="item",
        values="text",
        aggfunc="first",
        fill_value="",
    ).reset_index()
    wide.columns.name = None

    for col in ["item1", "item7"]:
        if col not in wide.columns:
            wide[col] = ""

    wide = wide.rename(columns={"item1": "item1_text", "item7": "item7_text"})
    wide["year"] = pd.to_numeric(wide["year"], errors="coerce").astype("Int64")
    wide["has_item1"] = wide["item1_text"].astype(str).str.len().gt(0)
    wide["has_item7"] = wide["item7_text"].astype(str).str.len().gt(0)
    wide["item1_chars"] = wide["item1_text"].astype(str).str.len()
    wide["item7_chars"] = wide["item7_text"].astype(str).str.len()
    # Add labels so the model can tell which text came from which section.
    wide["combined_text"] = (
        "ITEM 1 BUSINESS:\n"
        + wide["item1_text"].fillna("").astype(str)
        + "\n\nITEM 7 MD&A:\n"
        + wide["item7_text"].fillna("").astype(str)
    )
    wide["combined_chars"] = wide["combined_text"].astype(str).str.len()

    return wide[base_cols].sort_values(["accession_number"]).reset_index(drop=True)


# ---------------------------------------------------------------------------
# Endpoint scoring
# ---------------------------------------------------------------------------
def get_dwutils_sm() -> Any:
    """Load the dwutils SageMaker helper used to query the Llama endpoint."""

    try:
        from dwutils import sm
    except ImportError as exc:
        raise RuntimeError(
            "dwutils is not installed. Install it with:\n"
            "  pip install dwutils\n"
            "  pip install 'dwutils[ml]'"
        ) from exc
    return sm


def query_endpoint_with_retries(
    *,
    sm: Any,
    prompt: str,
    endpoint: str,
    parameters: Dict[str, Any],
    job_id: str,
    retries: int,
    retry_sleep: float,
) -> Tuple[Any, int]:
    """
    Query the model endpoint with simple exponential backoff.

    Returns both the response and the number of attempts so failures/retries are
    visible in the output CSV.
    """

    last_exc: Optional[Exception] = None
    for attempt in range(retries + 1):
        try:
            resp = sm.query_endpoint(
                prompt=prompt,
                endpoint=endpoint,
                parameters=parameters,
                job_id=job_id,
            )
            return resp, attempt + 1
        except Exception as exc:
            last_exc = exc
            if attempt >= retries:
                break
            sleep_for = retry_sleep * (2 ** attempt)
            logging.warning(
                "Endpoint call failed for %s attempt %d/%d; retrying in %.1fs: %s",
                job_id,
                attempt + 1,
                retries + 1,
                sleep_for,
                str(exc)[:300],
            )
            time.sleep(sleep_for)

    raise RuntimeError(str(last_exc) if last_exc else "Endpoint call failed.")


def score_filing(
    row: pd.Series,
    *,
    sm: Any,
    endpoint: str,
    max_prompt_chars: int,
    sentence_window: int,
    temperature: float,
    max_new_tokens: int,
    prefilter_mode: str,
    prefilter_audit_sample: bool,
    save_raw_json: bool,
    file_id: str,
    row_number: int,
    run_id: str,
    source_label: str,
    retries: int,
    retry_sleep: float,
) -> Dict[str, Any]:
    """
    Score one filing and return the exact output row written to CSV.

    This function handles all row-level decisions: empty text, prefilter zero,
    snippet extraction, endpoint call, model-output parsing, and QA metadata.
    """

    cik = str(row.get("cik", "")).strip()
    accession_number = str(row.get("accession_number", "")).strip()
    form_type = str(row.get("form_type", "")).strip()
    year = row.get("year", pd.NA)
    year = int(year) if pd.notna(year) else pd.NA

    full_text = normalize_whitespace(row.get("combined_text", ""))
    keyword_hits = count_ai_keywords(full_text)

    prompt_text = ""
    raw_json = ""
    job_id = ""
    score = pd.NA
    explanation = ""
    score_status = ""
    llm_called = False
    endpoint_attempts = 0
    prefilter_decision = "not_applicable"

    # Decision path 1: no text, so the filing cannot contain AI evidence.
    if not full_text:
        score = 0.0
        explanation = "No text was available after combining Item 1 and Item 7."
        score_status = "empty_text_zero"
        prefilter_decision = "empty_text"

    # Decision path 2: hard prefilter zero for no-keyword filings.
    elif keyword_hits == 0 and prefilter_mode in {"hard_zero", "audit"} and not prefilter_audit_sample:
        score = 0.0
        explanation = "No AI-related keywords were detected by the prefilter, so the filing was assigned zero without an LLM call."
        score_status = "prefilter_zero_no_keyword"
        prefilter_decision = f"{prefilter_mode}_zero_no_keyword"

    # Decision path 3: call the LLM, then parse and validate its JSON response.
    else:
        if keyword_hits == 0 and prefilter_audit_sample:
            prefilter_decision = "audit_call_no_keyword"
        elif keyword_hits == 0:
            prefilter_decision = "llm_call_no_keyword_prefilter_off"
        else:
            prefilter_decision = "keyword_hit_llm_call"

        prompt_text = extract_relevant_snippets(full_text, max_prompt_chars, sentence_window)
        if not prompt_text:
            score = pd.NA
            explanation = "Snippet extraction returned empty text."
            score_status = "snippet_extraction_failed"
        else:
            llm_called = True
            job_id = f"{run_id}_{file_id}_{row_number:06d}"
            prompt = build_ai_prompt(prompt_text)
            try:
                resp, endpoint_attempts = query_endpoint_with_retries(
                    sm=sm,
                    prompt=prompt,
                    endpoint=endpoint,
                    parameters={
                        "temperature": temperature,
                        "max_new_tokens": max_new_tokens,
                        "return_full_text": False,
                    },
                    job_id=job_id,
                    retries=retries,
                    retry_sleep=retry_sleep,
                )
                out_text = extract_text_from_response(resp)
                score, explanation, score_status, raw_json = parse_model_output(out_text)
                if prefilter_audit_sample and score_status == "ok":
                    score_status = "prefilter_audit_ok"
            except Exception as exc:
                score = pd.NA
                explanation = f"Endpoint error: {str(exc)[:500]}"
                score_status = "endpoint_error"

    # The output row includes the score plus enough QA columns to explain how
    # the score was produced.
    record = {
        "run_id": run_id,
        "script_version": SCRIPT_VERSION,
        "prompt_version": PROMPT_VERSION,
        "source_label": source_label,
        "chunk_id": file_id,
        "accession_number": accession_number,
        "cik": cik,
        "year": year,
        "form_type": form_type,
        "has_item1": bool(row.get("has_item1", False)),
        "has_item7": bool(row.get("has_item7", False)),
        "item1_chars": int(row.get("item1_chars", 0) or 0),
        "item7_chars": int(row.get("item7_chars", 0) or 0),
        "combined_chars": int(row.get("combined_chars", 0) or 0),
        "keyword_hits": keyword_hits,
        "prefilter_mode": prefilter_mode,
        "prefilter_decision": prefilter_decision,
        "prefilter_audit_sample": bool(prefilter_audit_sample),
        "snippet_chars": len(prompt_text),
        "llm_called": llm_called,
        "endpoint_attempts": int(endpoint_attempts),
        "ai_adoption_score": score,
        "explanation": explanation,
        "score_status": score_status,
        "endpoint": endpoint,
        "job_id": job_id,
        "snippet_sha256": sha256_text(prompt_text) if prompt_text else "",
        "raw_json_sha256": sha256_text(raw_json) if raw_json else "",
    }
    if save_raw_json:
        record["raw_json"] = raw_json
    return record


# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
def write_json(path: str, payload: Dict[str, Any]) -> None:
    """Write a JSON file with stable formatting."""

    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, ensure_ascii=False, default=str)


def order_columns(df: pd.DataFrame, save_raw_json: bool) -> pd.DataFrame:
    """Put important QA columns first and keep any extra columns at the end."""

    preferred = preferred_output_columns(save_raw_json)
    if df.empty:
        return pd.DataFrame(columns=preferred)
    existing = [c for c in preferred if c in df.columns]
    other = [c for c in df.columns if c not in existing]
    return df[existing + other]


def write_checkpoint(path: str, rows: List[Dict[str, Any]], save_raw_json: bool) -> None:
    """Write partial progress so a long chunk does not lose all completed rows."""

    order_columns(pd.DataFrame(rows), save_raw_json).to_csv(path, index=False)


def output_dir_for_run(args: argparse.Namespace, run_id: str) -> str:
    """Choose either a run-specific output folder or the flat output folder."""

    return args.out_dir if args.flat_output else os.path.join(args.out_dir, run_id)


# ---------------------------------------------------------------------------
# Chunk processing
# ---------------------------------------------------------------------------
def process_chunk(
    ref: ChunkRef,
    *,
    args: argparse.Namespace,
    run_id: str,
    sm: Any,
    bucket: str,
) -> Dict[str, Any]:
    """
    Process one S3 chunk from download through final CSV and summary JSON.

    The return value becomes one row in the run manifest.
    """

    file_id = Path(ref.name).stem
    run_out_dir = output_dir_for_run(args, run_id)
    os.makedirs(run_out_dir, exist_ok=True)

    out_csv = os.path.join(run_out_dir, f"{file_id}_llama_scores.csv")
    out_json = os.path.join(run_out_dir, f"{file_id}_summary.json")
    partial_csv = os.path.join(run_out_dir, f"{file_id}_llama_scores.partial.csv")
    source_label = f"s3://{bucket}/{ref.key}"

    # Skip only when both final files already exist.
    if args.skip_existing and os.path.exists(out_csv) and os.path.exists(out_json):
        logging.info("Skipping existing output for %s", ref.name)
        return {
            "chunk_name": ref.name,
            "source_label": source_label,
            "status": "skipped_existing",
            "output_csv": out_csv,
            "output_summary": out_json,
            "n_filings": pd.NA,
            "n_ok": pd.NA,
        }

    logging.info("Reading %s", source_label)
    # Read and reshape the source data before row-level scoring.
    df = read_rds_s3(bucket, ref.key)
    wide = long_to_wide(df, include_amended=args.include_amended)

    if args.max_filings_per_chunk > 0:
        wide = wide.head(args.max_filings_per_chunk).copy()

    rows: List[Dict[str, Any]] = []
    audit_calls = 0

    for i, row in wide.iterrows():
        # In audit mode, send only a stable sample of no-keyword filings to the
        # LLM. This estimates false-zero risk without scoring every no-keyword
        # filing.
        accession_number = str(row.get("accession_number", "")).strip()
        full_text = normalize_whitespace(row.get("combined_text", ""))
        keyword_hits = count_ai_keywords(full_text)

        audit_sample = False
        if args.prefilter_mode == "audit" and keyword_hits == 0:
            sampled = stable_unit_interval(f"{args.audit_seed}|{accession_number}") < args.prefilter_audit_rate
            under_limit = args.prefilter_audit_limit <= 0 or audit_calls < args.prefilter_audit_limit
            audit_sample = sampled and under_limit
            if audit_sample:
                audit_calls += 1

        rec = score_filing(
            row,
            sm=sm,
            endpoint=args.endpoint,
            max_prompt_chars=args.max_prompt_chars,
            sentence_window=args.sentence_window,
            temperature=args.temperature,
            max_new_tokens=args.max_new_tokens,
            prefilter_mode=args.prefilter_mode,
            prefilter_audit_sample=audit_sample,
            save_raw_json=args.save_raw_json,
            file_id=file_id,
            row_number=i + 1,
            run_id=run_id,
            source_label=source_label,
            retries=args.retries,
            retry_sleep=args.retry_sleep,
        )
        rows.append(rec)

        if len(rows) % 50 == 0:
            logging.info("Scored %s: %d/%d filings", ref.name, len(rows), len(wide))

        if args.checkpoint_every > 0 and len(rows) % args.checkpoint_every == 0:
            write_checkpoint(partial_csv, rows, args.save_raw_json)
            logging.info("Wrote checkpoint: %s (%d rows)", partial_csv, len(rows))

    # Write the final per-filing CSV for this chunk.
    out_df = order_columns(pd.DataFrame(rows), args.save_raw_json)
    out_df.to_csv(out_csv, index=False)

    if os.path.exists(partial_csv):
        os.remove(partial_csv)

    # The summary JSON gives a fast chunk-level QA view without opening the CSV.
    score_series = pd.to_numeric(out_df["ai_adoption_score"], errors="coerce") if not out_df.empty else pd.Series(dtype=float)
    summary = {
        "run_id": run_id,
        "chunk_name": ref.name,
        "source_label": source_label,
        "script_version": SCRIPT_VERSION,
        "prompt_version": PROMPT_VERSION,
        "endpoint": args.endpoint,
        "prefilter_mode": args.prefilter_mode,
        "prefilter_audit_rate": args.prefilter_audit_rate,
        "prefilter_audit_limit": args.prefilter_audit_limit,
        "n_filings": int(len(out_df)),
        "n_unique_cik": int(out_df["cik"].nunique()) if not out_df.empty else 0,
        "n_llm_called": int(out_df["llm_called"].sum()) if not out_df.empty else 0,
        "n_ok": int((out_df["score_status"] == "ok").sum()) if not out_df.empty else 0,
        "n_prefilter_audit_ok": int((out_df["score_status"] == "prefilter_audit_ok").sum()) if not out_df.empty else 0,
        "n_prefilter_zero": int((out_df["score_status"] == "prefilter_zero_no_keyword").sum()) if not out_df.empty else 0,
        "n_missing_item1": int((~out_df["has_item1"]).sum()) if not out_df.empty else 0,
        "n_missing_item7": int((~out_df["has_item7"]).sum()) if not out_df.empty else 0,
        "status_counts": out_df["score_status"].value_counts(dropna=False).to_dict() if not out_df.empty else {},
        "score_min": None if score_series.dropna().empty else float(score_series.min()),
        "score_mean": None if score_series.dropna().empty else float(score_series.mean()),
        "score_max": None if score_series.dropna().empty else float(score_series.max()),
        "output_csv": out_csv,
    }
    write_json(out_json, summary)

    logging.info("Wrote %s (%d rows)", out_csv, len(out_df))
    return {
        "chunk_name": ref.name,
        "source_label": source_label,
        "status": "ok",
        "output_csv": out_csv,
        "output_summary": out_json,
        "n_filings": int(len(out_df)),
        "n_ok": int((out_df["score_status"] == "ok").sum()) if not out_df.empty else 0,
        "n_prefilter_audit_ok": int((out_df["score_status"] == "prefilter_audit_ok").sum()) if not out_df.empty else 0,
    }


# ---------------------------------------------------------------------------
# Command-line interface and orchestration
# ---------------------------------------------------------------------------
def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    """
    Define command-line options and validate simple numeric constraints.

    Keeping validation here means later functions can assume arguments are in a
    reasonable range.
    """

    ap = argparse.ArgumentParser(
        description="Score selected S3 extract_df_chunk_XXXXX.rds files with a Llama endpoint."
    )

    ap.add_argument("--s3-bucket", default=DEFAULT_S3_BUCKET, help="S3 bucket containing the chunk prefix.")
    ap.add_argument(
        "--s3-prefix",
        default=None,
        help="S3 prefix containing chunk files. Can also be a full s3://bucket/prefix URI.",
    )
    ap.add_argument("--s3-prefix-env", default=None, help="Environment variable holding the S3 prefix.")

    sel = ap.add_mutually_exclusive_group(required=False)
    sel.add_argument("--chunk-names", nargs="+", help="Chunk basenames, e.g. extract_df_chunk_00001.rds")
    sel.add_argument("--chunk-ids", nargs="+", type=int, help="Chunk ids, e.g. 1 2 18 37")
    sel.add_argument("--chunk-range", nargs=2, type=int, metavar=("START", "END"), help="Inclusive chunk id range.")
    sel.add_argument("--all-chunks", action="store_true", help="Process every chunk under the S3 prefix. Use with care.")

    ap.add_argument("--list-only", action="store_true", help="List available chunks under the S3 prefix and exit.")
    ap.add_argument("--max-chunks", type=int, default=0, help="Cap number of selected chunks after resolution.")
    ap.add_argument("--max-filings-per-chunk", type=int, default=0, help="For QA/testing, only score first N filings per chunk.")
    ap.add_argument("--include-amended", action="store_true", help="Include 10-K/A rows. Default keeps only 10-K.")
    ap.add_argument(
        "--prefilter-mode",
        choices=["off", "hard_zero", "audit"],
        default="off",
        help="off calls the LLM on all non-empty filings; hard_zero skips no-keyword filings; audit samples no-keyword filings.",
    )
    ap.add_argument("--prefilter-audit-rate", type=float, default=0.02)
    ap.add_argument("--prefilter-audit-limit", type=int, default=0, help="Per-chunk audit call cap; 0 means no cap.")
    ap.add_argument("--audit-seed", default="ai-adoption-prefilter-audit-v1")
    ap.add_argument("--save-raw-json", action="store_true", help="Store raw model JSON in output CSV.")
    ap.add_argument("--skip-existing", action="store_true", help="Skip chunks whose final CSV and summary JSON already exist.")
    ap.add_argument("--flat-output", action="store_true", help="Write directly to --out-dir instead of --out-dir/RUN_ID.")
    ap.add_argument("--out-dir", default=os.path.join(os.getcwd(), "output", "llama_scores"))
    ap.add_argument("--endpoint", default=DEFAULT_ENDPOINT)
    ap.add_argument("--max-prompt-chars", type=int, default=12000)
    ap.add_argument("--sentence-window", type=int, default=1)
    ap.add_argument("--temperature", type=float, default=0.0)
    ap.add_argument("--max-new-tokens", type=int, default=300)
    ap.add_argument("--retries", type=int, default=2, help="Endpoint retries after the initial attempt.")
    ap.add_argument("--retry-sleep", type=float, default=5.0, help="Initial retry sleep in seconds; doubles each retry.")
    ap.add_argument("--checkpoint-every", type=int, default=25, help="Write a partial CSV every N scored filings; 0 disables.")
    ap.add_argument("--log-level", default="INFO", choices=["DEBUG", "INFO", "WARNING", "ERROR"])

    args = ap.parse_args(argv)

    if args.max_chunks < 0:
        ap.error("--max-chunks must be >= 0")
    if args.max_filings_per_chunk < 0:
        ap.error("--max-filings-per-chunk must be >= 0")
    if args.max_prompt_chars <= 0:
        ap.error("--max-prompt-chars must be > 0")
    if args.sentence_window < 0:
        ap.error("--sentence-window must be >= 0")
    if not (0.0 <= args.temperature <= 2.0):
        ap.error("--temperature must be between 0 and 2")
    if args.retries < 0:
        ap.error("--retries must be >= 0")
    if args.retry_sleep < 0:
        ap.error("--retry-sleep must be >= 0")
    if args.checkpoint_every < 0:
        ap.error("--checkpoint-every must be >= 0")
    if not (0.0 <= args.prefilter_audit_rate <= 1.0):
        ap.error("--prefilter-audit-rate must be between 0 and 1")
    if args.prefilter_audit_limit < 0:
        ap.error("--prefilter-audit-limit must be >= 0")

    return args


def main(argv: Optional[Sequence[str]] = None) -> int:
    """Run the full workflow: parse args, list/select chunks, process each one."""

    args = parse_args(argv)
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s | %(levelname)s | %(message)s",
    )

    # Resolve and list the S3 prefix before doing any endpoint work.
    bucket, prefix = parse_s3_location(args.s3_bucket, args.s3_prefix, args.s3_prefix_env)
    logging.info("Using S3 prefix: s3://%s/%s", bucket, prefix)

    available = list_chunks_s3(bucket, prefix)
    if args.list_only:
        if not available:
            print(f"No chunk files found under s3://{bucket}/{prefix}")
            return 0
        for name in available:
            print(name)
        return 0

    max_chunks = args.max_chunks if args.max_chunks > 0 else None
    selected = select_chunks(
        available=available,
        chunk_names=args.chunk_names,
        chunk_ids=args.chunk_ids,
        chunk_range=args.chunk_range,
        all_chunks=args.all_chunks,
        max_chunks=max_chunks,
    )

    if not selected:
        logging.warning("No chunks selected after filtering.")
        return 0

    # One run_id ties together every chunk output and the manifest.
    run_id = utc_now()
    run_out_dir = output_dir_for_run(args, run_id)
    os.makedirs(run_out_dir, exist_ok=True)

    sm = get_dwutils_sm()

    manifest_rows = []
    for ref in selected:
        # Keep going if one chunk fails; the manifest records the failure.
        try:
            row = process_chunk(ref, args=args, run_id=run_id, sm=sm, bucket=bucket)
        except Exception as exc:
            logging.exception("Failed processing %s", ref.name)
            row = {
                "chunk_name": ref.name,
                "source_label": f"s3://{bucket}/{ref.key}",
                "status": "failed",
                "output_csv": "",
                "output_summary": "",
                "n_filings": pd.NA,
                "n_ok": pd.NA,
                "error": str(exc)[:1000],
            }
        manifest_rows.append(row)

    manifest = pd.DataFrame(manifest_rows)
    manifest_path = os.path.join(run_out_dir, f"run_manifest_{run_id}.csv")
    manifest.to_csv(manifest_path, index=False)
    logging.info("Wrote run manifest: %s", manifest_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
