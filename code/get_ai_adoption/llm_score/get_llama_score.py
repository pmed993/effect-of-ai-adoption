#!/usr/bin/env python3
"""
get_llm_score_qa.py

Filing-level LLM scoring for EDGAR extract_df_chunk_XXXXX.rds files.

QA-hardened version of get_llm_score.py.

Key changes versus the earlier script
-------------------------------------
- Parses the last usable JSON score object, not the first JSON object in output
- Uses filing-time prompt wording rather than ambiguous "current" wording
- Makes hard-zero keyword prefilter opt-in through --prefilter-mode hard_zero
- Adds a deterministic no-keyword audit mode for estimating prefilter false zeroes
- Removes case-insensitive bare "ml" matching; only uppercase ML matches
- Filters local chunk names with the same strict regex used for S3
- Writes outputs under a run_id subdirectory by default to avoid overwriting
- Checks both CSV and JSON summary for --skip-existing
- Adds endpoint retries and periodic partial checkpoints
- Emits stable empty CSV headers for empty chunks

Important
---------
This script produces one score per filing (accession_number) within each chunk.
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

SCRIPT_VERSION = "2026-04-17-qa1"
PROMPT_VERSION = "llama_ai_adoption_v3_filing_time"

DEFAULT_ENDPOINT = "jupyterhub-llama-3-3b-instruct-endpoint"
DEFAULT_S3_BUCKET = "jupyter.notebook.uktrade.io"

CHUNK_RE = re.compile(r"^extract_df_chunk_(\d{5})\.rds$")

# Case-insensitive phrases plus selected abbreviations. Bare "ML" is intentionally
# case-sensitive to avoid matching units such as "ml".
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

OPERATIONAL_CUES = re.compile(
    r"(?i)\b("
    r"use|uses|used|using|deploy|deploys|deployed|deployment|implemented|implements|"
    r"integrated|integrates|embedded|operates|operational|automate|automates|automated|"
    r"recommend|recommends|detect|detects|forecast|forecasts|predict|predicts|price|prices|"
    r"underwrite|underwrites|optimize|optimizes|personalize|personalizes|deliver|delivers"
    r")\b"
)

LOW_VALUE_CUES = re.compile(
    r"(?i)\b("
    r"risk|risks|could|may|might|intend|intends|plan|plans|future|potential|regulation|"
    r"regulatory|competition|competitors|cybersecurity|industry trend|trends|pilot|pilots|"
    r"proof of concept|experiment|experiments|research"
    r")\b"
)

SENTENCE_SPLIT_RE = re.compile(r"(?<=[\.\!\?\;])\s+|\n+")
WHITESPACE_RE = re.compile(r"\s+")


@dataclass
class ChunkRef:
    source_type: str  # "local" or "s3"
    name: str         # basename, e.g. extract_df_chunk_00001.rds
    location: str     # local path or s3 key


def preferred_output_columns(save_raw_json: bool) -> List[str]:
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


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def stable_unit_interval(value: str) -> float:
    digest = hashlib.sha256(value.encode("utf-8")).hexdigest()
    return int(digest[:16], 16) / float(16 ** 16)


def normalize_whitespace(text: Any) -> str:
    if text is None or (isinstance(text, float) and pd.isna(text)):
        return ""
    text = str(text).replace("\x00", " ")
    text = WHITESPACE_RE.sub(" ", text)
    return text.strip()


def build_ai_prompt(text: str) -> str:
    return (
        "You are an academic research assistant measuring firm-level artificial intelligence adoption from SEC Form 10-K disclosures.\n\n"
        "TASK\n"
        "Read the filing text and estimate the firm's level of AI adoption as described in this filing, at the time covered by the filing text.\n"
        "Return exactly two fields in valid JSON:\n"
        "1. score: a continuous number between 0.00 and 1.00\n"
        "2. explanation: one short paragraph explaining why that score was assigned\n\n"
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
        "IMPORTANT CALIBRATION RULE\n"
        "- repeated wording alone must not increase the score\n"
        "- only distinct operational evidence should raise the score\n"
        "- if evidence is weak or ambiguous, assign a conservative lower score\n\n"
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
        "OUTPUT FORMAT\n"
        "Return ONLY valid JSON in exactly this structure:\n"
        "{\"score\": 0.00, \"explanation\": \"...\"}\n\n"
        "RULES FOR OUTPUT\n"
        "- score must be a number between 0.00 and 1.00\n"
        "- explanation must be a single paragraph\n"
        "- do not return markdown\n"
        "- do not return any text before or after the JSON\n\n"
        "TEXT TO EVALUATE:\n"
        f"{text}"
    )


def extract_text_from_response(resp: Any) -> str:
    """
    Best-effort extraction from common endpoint response shapes.
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
        preferred_keys = [
            "generated_text",
            "text",
            "output",
            "response",
            "completion",
            "generated_output",
            "content",
        ]
        for key in preferred_keys:
            if key in resp and resp[key] is not None:
                txt = extract_text_from_response(resp[key])
                if txt:
                    return txt

        if "choices" in resp and isinstance(resp["choices"], list):
            for choice in resp["choices"]:
                txt = extract_text_from_response(choice)
                if txt:
                    return txt

        if "message" in resp:
            txt = extract_text_from_response(resp["message"])
            if txt:
                return txt

        if "outputs" in resp:
            txt = extract_text_from_response(resp["outputs"])
            if txt:
                return txt

        return json.dumps(resp, ensure_ascii=False)

    return str(resp)


def extract_balanced_json_objects(text: str) -> List[str]:
    """
    Extract all balanced JSON-looking objects from a string using brace matching
    while respecting quoted strings and escapes.
    """
    objects: List[str] = []
    if not text:
        return objects

    n = len(text)
    start = 0
    while start < n:
        if text[start] != "{":
            start += 1
            continue

        depth = 0
        in_string = False
        escape = False
        found_end = None

        for i in range(start, n):
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
            continue

        objects.append(text[start:found_end + 1])
        start = found_end + 1

    return objects


def parse_score_object(obj: Any) -> Tuple[Any, str, str]:
    if not isinstance(obj, dict):
        return pd.NA, "Parsed JSON was not an object.", "json_not_object"

    score = obj.get("score", None)
    explanation = obj.get("explanation", "")

    try:
        score = float(score)
    except Exception:
        return pd.NA, "Score field was not numeric.", "non_numeric_score"

    if not (0.0 <= score <= 1.0):
        return pd.NA, "Score was outside [0,1].", "score_out_of_bounds"

    if not isinstance(explanation, str):
        explanation = str(explanation) if explanation is not None else ""

    explanation = " ".join(explanation.split()).strip()
    if not explanation:
        explanation = "No explanation returned."

    return score, explanation, "ok"


def parse_model_output(text: str) -> Tuple[Any, str, str, str]:
    """
    Returns:
        score (float or pd.NA)
        explanation (str)
        score_status (str)
        raw_json (str)

    The parser intentionally tries JSON objects from last to first. Some hosted
    endpoints echo the prompt, and the prompt contains an example JSON object.
    Reading the first object can therefore silently assign the example score.
    """
    if not text:
        return pd.NA, "No model output returned.", "missing_output", ""

    candidates = extract_balanced_json_objects(text)
    if not candidates:
        return pd.NA, "Model output did not contain valid JSON.", "no_json_found", ""

    parse_error_count = 0
    validation_statuses: List[str] = []
    last_candidate = candidates[-1]

    for jtxt in reversed(candidates):
        try:
            obj = json.loads(jtxt)
        except Exception:
            parse_error_count += 1
            continue

        score, explanation, status = parse_score_object(obj)
        if status == "ok":
            return score, explanation, "ok", jtxt
        validation_statuses.append(status)

    if validation_statuses:
        status = validation_statuses[-1]
        return pd.NA, f"No usable score JSON found. Last validation issue: {status}.", "no_valid_score_json", last_candidate

    if parse_error_count:
        return pd.NA, "Model JSON candidates could not be parsed.", "json_parse_error", last_candidate

    return pd.NA, "Model output did not contain usable score JSON.", "no_valid_score_json", last_candidate


def split_into_sentences(text: str) -> List[str]:
    text = normalize_whitespace(text)
    if not text:
        return []
    parts = [p.strip() for p in SENTENCE_SPLIT_RE.split(text) if p and p.strip()]
    if not parts:
        return [text]
    return parts


def make_window_indices(center: int, n_sentences: int, sentence_window: int) -> List[int]:
    lo = max(0, center - sentence_window)
    hi = min(n_sentences, center + sentence_window + 1)
    return list(range(lo, hi))


def score_window(sentences: List[str], indices: List[int], center: int) -> int:
    text = " ".join(sentences[i] for i in indices)
    center_text = sentences[center]
    score = 0

    if OPERATIONAL_CUES.search(text):
        score += 4
    if OPERATIONAL_CUES.search(center_text):
        score += 2
    if LOW_VALUE_CUES.search(center_text):
        score -= 2
    if LOW_VALUE_CUES.search(text):
        score -= 1

    # Prefer richer context over very short boilerplate fragments.
    if len(text) >= 200:
        score += 1
    return score


def extract_relevant_snippets(
    full_text: str,
    max_chars: int = 12000,
    sentence_window: int = 1,
    fallback_to_head: bool = True,
) -> str:
    """
    Sentence-aware excerpt extraction:
    - find sentences containing AI keywords
    - build +/- sentence_window windows
    - prioritize operational windows over low-value/risk-only windows
    - dedupe sentences while preserving final document order
    - stop at max_chars
    """
    full_text = normalize_whitespace(full_text)
    if not full_text:
        return ""

    sentences = split_into_sentences(full_text)
    if not sentences:
        return full_text[:max_chars]

    hit_idx = [i for i, s in enumerate(sentences) if AI_KEYWORDS.search(s)]
    if not hit_idx:
        return full_text[:max_chars] if fallback_to_head else ""

    windows = []
    for idx in hit_idx:
        indices = make_window_indices(idx, len(sentences), sentence_window)
        text = " ".join(sentences[i] for i in indices)
        windows.append(
            {
                "center": idx,
                "indices": indices,
                "text_len": len(text),
                "score": score_window(sentences, indices, idx),
            }
        )

    # Pick the most useful windows first so later operational evidence is not
    # crowded out by early repeated boilerplate. Then emit selected sentences in
    # original document order for readability.
    windows.sort(key=lambda w: (-int(w["score"]), int(w["center"])))

    selected_indices = set()
    used_estimate = 0
    for window in windows:
        new_indices = [i for i in window["indices"] if i not in selected_indices]
        if not new_indices:
            continue

        new_text = " ".join(sentences[i] for i in new_indices)
        if used_estimate >= max_chars:
            break
        if used_estimate + len(new_text) > max_chars and used_estimate > 0:
            continue

        for i in new_indices:
            selected_indices.add(i)
        used_estimate += len(new_text) + 2

    if not selected_indices:
        return full_text[:max_chars] if fallback_to_head else ""

    chunks = []
    used = 0
    last_j = None
    for j in sorted(selected_indices):
        sentence = sentences[j]
        prefix = " " if chunks and last_j is not None and j == last_j + 1 else "\n\n"
        candidate = (prefix + sentence) if chunks else sentence
        if used + len(candidate) > max_chars:
            remaining = max_chars - used
            if remaining > 150:
                chunks.append(candidate[:remaining].rstrip())
            break
        chunks.append(candidate)
        used += len(candidate)
        last_j = j

    out = "".join(chunks).strip()
    if out:
        return out

    return full_text[:max_chars] if fallback_to_head else ""


def read_rds_local(path: str) -> pd.DataFrame:
    try:
        import pyreadr
    except ImportError as exc:
        raise RuntimeError("pyreadr is not installed. Run: pip install pyreadr") from exc

    res = pyreadr.read_r(path)
    if len(res) == 0:
        raise ValueError(f"No readable objects found in RDS file: {path}")

    df = next(iter(res.values()))
    if not isinstance(df, pd.DataFrame):
        raise TypeError(f"First object in RDS file is not a data frame: {path}")

    return df


def read_rds_s3(bucket: str, key: str) -> pd.DataFrame:
    try:
        import boto3
    except ImportError as exc:
        raise RuntimeError("boto3 is not installed. Run: pip install boto3") from exc

    s3 = boto3.client("s3")
    with tempfile.NamedTemporaryFile(suffix=".rds", delete=True) as tmp:
        s3.download_file(bucket, key, tmp.name)
        return read_rds_local(tmp.name)


def list_chunks_local(chunk_dir: str) -> Dict[str, ChunkRef]:
    path = Path(chunk_dir)
    if not path.exists():
        raise FileNotFoundError(f"Chunk directory does not exist: {chunk_dir}")

    refs: Dict[str, ChunkRef] = {}
    for p in sorted(path.glob("extract_df_chunk_*.rds")):
        if not CHUNK_RE.match(p.name):
            continue
        refs[p.name] = ChunkRef(source_type="local", name=p.name, location=str(p.resolve()))
    return refs


def resolve_s3_prefix(prefix: Optional[str], prefix_env: Optional[str]) -> str:
    if prefix:
        return prefix.strip().strip("/")
    if prefix_env:
        value = os.getenv(prefix_env, "").strip().strip("/")
        if not value:
            raise ValueError(f"Environment variable {prefix_env} is not set or is empty.")
        return value
    raise ValueError("For --source s3, provide either --s3-prefix or --s3-prefix-env.")


def list_chunks_s3(bucket: str, prefix: str) -> Dict[str, ChunkRef]:
    try:
        import boto3
    except ImportError as exc:
        raise RuntimeError("boto3 is not installed. Run: pip install boto3") from exc

    s3 = boto3.client("s3")
    paginator = s3.get_paginator("list_objects_v2")

    refs: Dict[str, ChunkRef] = {}
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix.rstrip("/") + "/"):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            name = key.rsplit("/", 1)[-1]
            if CHUNK_RE.match(name):
                refs[name] = ChunkRef(source_type="s3", name=name, location=key)
    return dict(sorted(refs.items()))


def chunk_name_from_id(chunk_id: int) -> str:
    if chunk_id < 1:
        raise ValueError("chunk ids must be positive integers.")
    return f"extract_df_chunk_{chunk_id:05d}.rds"


def select_chunks(
    available: Dict[str, ChunkRef],
    source: str,
    chunk_files: Optional[Sequence[str]],
    chunk_ids: Optional[Sequence[int]],
    chunk_range: Optional[Sequence[int]],
    all_chunks: bool,
    max_chunks: Optional[int],
) -> List[ChunkRef]:
    selected: List[ChunkRef] = []

    if chunk_files:
        for item in chunk_files:
            if source == "local" and Path(item).exists():
                p = Path(item).resolve()
                name = p.name
                if not CHUNK_RE.match(name):
                    raise ValueError(f"Not a valid chunk filename: {item}")
                selected.append(ChunkRef(source_type="local", name=name, location=str(p)))
            else:
                name = Path(item).name
                if name not in available:
                    raise FileNotFoundError(f"Chunk not found: {item}")
                selected.append(available[name])

    elif chunk_ids:
        for chunk_id in chunk_ids:
            name = chunk_name_from_id(int(chunk_id))
            if name not in available:
                raise FileNotFoundError(f"Chunk not found: {name}")
            selected.append(available[name])

    elif chunk_range:
        start, end = int(chunk_range[0]), int(chunk_range[1])
        if end < start:
            raise ValueError("--chunk-range requires START <= END")
        for chunk_id in range(start, end + 1):
            name = chunk_name_from_id(chunk_id)
            if name not in available:
                raise FileNotFoundError(f"Chunk not found: {name}")
            selected.append(available[name])

    elif all_chunks:
        selected = list(available.values())

    else:
        raise ValueError(
            "No chunks selected. Use one of --chunk-files, --chunk-ids, or --chunk-range. "
            "Use --all-chunks only if you explicitly want to process everything."
        )

    deduped = []
    seen = set()
    for ref in selected:
        key = (ref.source_type, ref.location)
        if key not in seen:
            deduped.append(ref)
            seen.add(key)

    if max_chunks is not None and max_chunks > 0:
        deduped = deduped[:max_chunks]

    return deduped


def long_to_wide(df: pd.DataFrame, include_amended: bool) -> pd.DataFrame:
    required = {"item", "year", "accession_number", "cik", "form_type", "text"}
    missing = required - set(df.columns)
    if missing:
        raise ValueError(f"Missing required columns: {sorted(missing)}")

    work = df.copy()

    work["item"] = work["item"].astype(str).str.strip().str.lower()
    work["form_type"] = work["form_type"].astype(str).str.upper().str.strip()
    work["accession_number"] = work["accession_number"].astype(str).str.strip()
    work["cik"] = work["cik"].astype(str).str.strip()
    work["text"] = work["text"].apply(normalize_whitespace)

    keep_forms = {"10-K", "10-K/A"} if include_amended else {"10-K"}
    work = work[work["form_type"].isin(keep_forms)]
    work = work[work["item"].isin(["item1", "item7"])]

    if work.empty:
        return pd.DataFrame(
            columns=[
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
        )

    collapsed = (
        work.groupby(["accession_number", "cik", "year", "form_type", "item"], as_index=False)
        .agg(text=("text", lambda x: " ".join([t for t in pd.unique(x) if t])))
    )

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
    wide["combined_text"] = (
        "ITEM 1 BUSINESS:\n"
        + wide["item1_text"].fillna("").astype(str)
        + "\n\nITEM 7 MD&A:\n"
        + wide["item7_text"].fillna("").astype(str)
    )
    wide["combined_chars"] = wide["combined_text"].astype(str).str.len()

    return wide.sort_values(["accession_number"]).reset_index(drop=True)


def get_dwutils_sm():
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
    attempts = 0
    last_exc: Optional[Exception] = None

    for attempt in range(retries + 1):
        attempts = attempt + 1
        try:
            resp = sm.query_endpoint(
                prompt=prompt,
                endpoint=endpoint,
                parameters=parameters,
                job_id=job_id,
            )
            return resp, attempts
        except Exception as exc:
            last_exc = exc
            if attempt >= retries:
                break
            sleep_for = retry_sleep * (2 ** attempt)
            logging.warning(
                "Endpoint call failed for job_id=%s attempt=%d/%d; retrying in %.1fs: %s",
                job_id,
                attempts,
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
    cik = str(row.get("cik", "")).strip()
    accession_number = str(row.get("accession_number", "")).strip()
    form_type = str(row.get("form_type", "")).strip()
    year = row.get("year", pd.NA)
    year = int(year) if pd.notna(year) else pd.NA

    full_text = normalize_whitespace(row.get("combined_text", ""))
    keyword_hits = len(list(AI_KEYWORDS.finditer(full_text))) if full_text else 0

    prompt_text = ""
    llm_called = False
    raw_json = ""
    job_id = ""
    score = pd.NA
    explanation = ""
    score_status = ""
    endpoint_attempts = 0
    prefilter_decision = "not_applicable"

    if not full_text:
        score = 0.0
        explanation = "No text was available after combining Item 1 and Item 7."
        score_status = "empty_text_zero"
        prefilter_decision = "empty_text"
    elif prefilter_mode == "hard_zero" and keyword_hits == 0 and not prefilter_audit_sample:
        score = 0.0
        explanation = "No AI-related keywords were detected by the conservative prefilter, so the filing was assigned a zero without an LLM call."
        score_status = "prefilter_zero_no_keyword"
        prefilter_decision = "hard_zero_no_keyword"
    else:
        if keyword_hits == 0:
            if prefilter_mode == "audit" and prefilter_audit_sample:
                prefilter_decision = "audit_call_no_keyword"
            elif prefilter_mode == "off":
                prefilter_decision = "llm_call_no_keyword_prefilter_off"
            else:
                prefilter_decision = "llm_call_no_keyword"
        else:
            prefilter_decision = "keyword_hit_llm_call"

        prompt_text = extract_relevant_snippets(
            full_text=full_text,
            max_chars=max_prompt_chars,
            sentence_window=sentence_window,
            fallback_to_head=True,
        )
        if not prompt_text:
            score = pd.NA
            explanation = "Snippet extraction returned empty text."
            score_status = "snippet_extraction_failed"
        else:
            llm_called = True
            prompt = build_ai_prompt(prompt_text)
            job_id = f"{run_id}_{file_id}_{row_number:06d}"

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

                if prefilter_mode == "audit" and keyword_hits == 0 and prefilter_audit_sample and score_status == "ok":
                    score_status = "prefilter_audit_ok"

            except Exception as exc:
                score = pd.NA
                explanation = f"Endpoint error: {str(exc)[:500]}"
                score_status = "endpoint_error"

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


def write_json(path: str, payload: Dict[str, Any]) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, ensure_ascii=False, default=str)


def order_columns(df: pd.DataFrame, save_raw_json: bool) -> pd.DataFrame:
    preferred_cols = preferred_output_columns(save_raw_json)
    if df.empty:
        return pd.DataFrame(columns=preferred_cols)

    existing_cols = [c for c in preferred_cols if c in df.columns]
    other_cols = [c for c in df.columns if c not in existing_cols]
    return df[existing_cols + other_cols]


def write_checkpoint(path: str, rows: List[Dict[str, Any]], save_raw_json: bool) -> None:
    out_df = order_columns(pd.DataFrame(rows), save_raw_json)
    out_df.to_csv(path, index=False)


def output_dir_for_run(args: argparse.Namespace, run_id: str) -> str:
    if args.flat_output:
        return args.out_dir
    return os.path.join(args.out_dir, run_id)


def process_chunk(ref: ChunkRef, args: argparse.Namespace, run_id: str, sm: Any) -> Dict[str, Any]:
    file_id = Path(ref.name).stem
    run_out_dir = output_dir_for_run(args, run_id)
    os.makedirs(run_out_dir, exist_ok=True)

    out_csv = os.path.join(run_out_dir, f"{file_id}_llama_scores.csv")
    out_json = os.path.join(run_out_dir, f"{file_id}_summary.json")
    partial_csv = os.path.join(run_out_dir, f"{file_id}_llama_scores.partial.csv")
    source_label = ref.location if ref.source_type == "local" else f"s3://{args.s3_bucket}/{ref.location}"

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
    if ref.source_type == "local":
        df = read_rds_local(ref.location)
    elif ref.source_type == "s3":
        df = read_rds_s3(args.s3_bucket, ref.location)
    else:
        raise ValueError(f"Unknown source_type: {ref.source_type}")

    wide = long_to_wide(df, include_amended=args.include_amended)

    if args.max_filings_per_chunk and args.max_filings_per_chunk > 0:
        wide = wide.head(args.max_filings_per_chunk).copy()

    rows: List[Dict[str, Any]] = []
    audit_calls = 0

    for i, row in wide.iterrows():
        accession_number = str(row.get("accession_number", "")).strip()
        audit_sample = False
        if args.prefilter_mode == "audit":
            full_text = normalize_whitespace(row.get("combined_text", ""))
            keyword_hits = len(list(AI_KEYWORDS.finditer(full_text))) if full_text else 0
            audit_rate_hit = stable_unit_interval(f"{args.audit_seed}|{accession_number}") < args.prefilter_audit_rate
            audit_limit_ok = args.prefilter_audit_limit <= 0 or audit_calls < args.prefilter_audit_limit
            audit_sample = keyword_hits == 0 and audit_rate_hit and audit_limit_ok
            if audit_sample:
                audit_calls += 1

        rec = score_filing(
            row=row,
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

        row_count = len(rows)
        if row_count % 50 == 0:
            logging.info("Scored %s: %d/%d filings", ref.name, row_count, len(wide))

        if args.checkpoint_every > 0 and row_count % args.checkpoint_every == 0:
            write_checkpoint(partial_csv, rows, args.save_raw_json)
            logging.info("Wrote checkpoint: %s (%d rows)", partial_csv, row_count)

    out_df = order_columns(pd.DataFrame(rows), args.save_raw_json)
    out_df.to_csv(out_csv, index=False)

    if os.path.exists(partial_csv):
        os.remove(partial_csv)

    status_counts = out_df["score_status"].value_counts(dropna=False).to_dict() if not out_df.empty else {}
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
        "status_counts": status_counts,
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


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        description="Score selected extract_df_chunk_XXXXX.rds files with a Llama endpoint and write one CSV per chunk."
    )

    ap.add_argument("--source", choices=["local", "s3"], default="local")
    ap.add_argument("--chunk-dir", default=".", help="Local directory containing extract_df_chunk_XXXXX.rds files.")
    ap.add_argument("--s3-bucket", default=DEFAULT_S3_BUCKET)
    ap.add_argument("--s3-prefix", default=None, help="S3 prefix containing chunk files.")
    ap.add_argument("--s3-prefix-env", default=None, help="Environment variable holding the S3 prefix.")

    sel = ap.add_mutually_exclusive_group(required=False)
    sel.add_argument("--chunk-files", nargs="+", help="Chunk basenames or local paths.")
    sel.add_argument("--chunk-ids", nargs="+", type=int, help="Chunk ids, e.g. 1 2 18 37")
    sel.add_argument("--chunk-range", nargs=2, type=int, metavar=("START", "END"), help="Inclusive chunk id range.")
    sel.add_argument("--all-chunks", action="store_true", help="Process every available chunk. Use with care.")

    ap.add_argument("--list-only", action="store_true", help="List available chunks and exit.")
    ap.add_argument("--max-chunks", type=int, default=0, help="Cap number of selected chunks after resolution.")
    ap.add_argument("--max-filings-per-chunk", type=int, default=0, help="For QA/testing, only score first N filings within each chunk.")
    ap.add_argument("--include-amended", action="store_true", help="Include 10-K/A rows. Default keeps only 10-K.")
    ap.add_argument(
        "--prefilter-mode",
        choices=["off", "hard_zero", "audit"],
        default="off",
        help=(
            "off calls the LLM on all non-empty filings; hard_zero assigns zero to no-keyword filings; "
            "audit hard-zeroes most no-keyword filings but sends a deterministic sample to the LLM."
        ),
    )
    ap.add_argument("--prefilter-audit-rate", type=float, default=0.02, help="Audit sample rate for no-keyword filings when --prefilter-mode audit.")
    ap.add_argument("--prefilter-audit-limit", type=int, default=0, help="Optional per-chunk cap on audit LLM calls; 0 means no cap.")
    ap.add_argument("--audit-seed", default="ai-adoption-prefilter-audit-v1", help="Stable seed for deterministic audit sampling.")
    ap.add_argument("--save-raw-json", action="store_true", help="Store raw model JSON in output CSV.")
    ap.add_argument("--skip-existing", action="store_true", default=False, help="Skip chunks whose output CSV and JSON summary already exist.")
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

    if args.max_chunks is not None and args.max_chunks < 0:
        ap.error("--max-chunks must be >= 0")
    if args.max_filings_per_chunk is not None and args.max_filings_per_chunk < 0:
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
    args = parse_args(argv)

    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s | %(levelname)s | %(message)s",
    )

    run_id = utc_now()
    max_chunks = args.max_chunks if args.max_chunks > 0 else None

    if args.source == "local":
        available = list_chunks_local(args.chunk_dir)
    else:
        prefix = resolve_s3_prefix(args.s3_prefix, args.s3_prefix_env)
        available = list_chunks_s3(args.s3_bucket, prefix)

    if args.list_only:
        if not available:
            print("No chunk files found.")
            return 0
        for name in available:
            print(name)
        return 0

    selected = select_chunks(
        available=available,
        source=args.source,
        chunk_files=args.chunk_files,
        chunk_ids=args.chunk_ids,
        chunk_range=args.chunk_range,
        all_chunks=args.all_chunks,
        max_chunks=max_chunks,
    )

    if not selected:
        logging.warning("No chunks selected after filtering.")
        return 0

    sm = get_dwutils_sm()

    run_out_dir = output_dir_for_run(args, run_id)
    os.makedirs(run_out_dir, exist_ok=True)

    manifest_rows = []
    for ref in selected:
        try:
            row = process_chunk(ref=ref, args=args, run_id=run_id, sm=sm)
        except Exception as exc:
            logging.exception("Failed processing %s", ref.name)
            row = {
                "chunk_name": ref.name,
                "source_label": ref.location if ref.source_type == "local" else f"s3://{args.s3_bucket}/{ref.location}",
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
