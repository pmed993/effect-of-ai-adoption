"""Utility functions for filing-level AI adoption labeling.

Helper functions for S3/Data Workspace access, RDS reading, lookup filtering,
prompt construction, snippet extraction, model-output parsing, and output formatting.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import tempfile
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Optional, Sequence

import pandas as pd


# ---------------------------------------------------------------------------
# Versions, defaults, and text-matching patterns
# ---------------------------------------------------------------------------
# These values are written into every output file so results can be traced back
# to the exact script and prompt version that produced them.
SCRIPT_VERSION = "2026-07-01-get_ai_score_bulk-v6"
PROMPT_VERSION = "ai_evidence_extraction_v1"
MODEL_NAME = "meta-llama/Llama-3.2-3B-Instruct"
TEMPERATURE = 0.0
DEFAULT_MAX_NEW_TOKENS = 220

DEFAULT_ENDPOINTS = {
    "llama": "jupyterhub-llama-3-3b-instruct-endpoint",
    "mistral": "jupyterhub-mistral-7b-instruct-endpoint"
}

DEFAULT_MODEL_NAMES = {
    "llama": MODEL_NAME,
    "mistral": "mistralai/Mistral-7B-Instruct-v0.3",
}

DEFAULT_ENDPOINT = DEFAULT_ENDPOINTS["llama"]

DEFAULT_BUCKET = "jupyter.notebook.uktrade.io"

# Chunk files must follow this exact naming pattern to be picked up.
CHUNK_RE = re.compile(r"^extract_df_chunk_(\d{5})\.rds$")

# Generic text cleanup and rough sentence splitting patterns.
WHITESPACE_RE = re.compile(r"\s+")
SENTENCE_SPLIT_RE = re.compile(r"(?<=[\.\!\?\;])\s+|\n+")

# The prefilter now uses a broader AI dictionary. We still keep explicit trigger
# terms and broader adjacent terms in separate lists for readability, but the
# call decision counts hits from both lists.
AI_TRIGGER_PATTERNS = [
    r"\bartificial intelligence\b",
    r"\bA\.I\.\b",
    r"\bAI/ML\b",
    r"\bmachine learning\b",
    r"\bdeep learning\b",
    r"\bneural networks?\b",
    r"\bartificial neural networks?\b",
    r"\bcomputer vision\b",
    r"\bnatural language processing\b",
    r"\bnatural language understanding\b",
    r"\bmachine translation\b",
    r"\bgenerative ai\b",
    r"\bgenai\b",
    r"\blarge language models?\b",
    r"\bllms?\b",
    r"\bchatbots?\b",
    r"\bsupport vector machines?\b",
    r"\bsupervised learning\b",
    r"\bunsupervised learning\b",
    r"\bclassification algorithms?\b",
    r"\bclustering algorithms?\b",
    r"\brecommender systems?\b",
    r"\binformation extraction\b",
    r"\bdimensionality reduction\b",
    r"\bkernel methods?\b",
    r"\bnamed entity recognition\b",
    r"\bentity recognition\b",
    r"\bintent classification\b",
    r"\breinforcement learning\b",
    r"\bfoundation models?\b",
    r"\btransformer models?\b",
    r"\bgenerative models?\b",
    r"\bconversational ai\b",
    r"\bvirtual assistants?\b",
    r"\bcopilots?\b",
    r"\bai assistants?\b",
    r"\bai agents?\b",
    r"\bagentic ai\b",
]

AI_RANKING_ONLY_PATTERNS = [
    r"\bbig data\b",
    r"\bbusiness intelligence\b",
    r"\bdata science\b",
    r"\bdata scientists?\b",
    r"\bimage recognition\b",
    r"\bobject recognition\b",
    r"\bspeech recognition\b",
    r"\bfacial recognition\b",
    r"\bdecision engines?\b",
    r"\bfraud detection\b",
    r"\bhandwriting recognition\b",
    r"\brobotic process automation\b",
    r"\bpredictive analytics?\b",
    r"\brecommendation engines?\b",
    r"\bexpert systems?\b",
    r"\bdata mining\b",
    r"\bpattern recognition\b",
    r"\banomaly detection\b",
    r"\blanguage models?\b",
    r"\balgorithmic decision-making\b",
    r"\bautomated decision-making\b",
]


def compile_keyword_patterns(patterns: Sequence[str]) -> re.Pattern[str]:
    """Compile a case-insensitive union of keyword patterns."""

    return re.compile(r"(?i:" + "|".join(patterns) + r")")


AI_TRIGGER_KEYWORDS = compile_keyword_patterns(AI_TRIGGER_PATTERNS + AI_RANKING_ONLY_PATTERNS)
AI_RANKING_ONLY_KEYWORDS = compile_keyword_patterns(AI_RANKING_ONLY_PATTERNS)
AI_RANKING_KEYWORDS = AI_TRIGGER_KEYWORDS

# These words help rank snippets. They do not determine the final label.
# They only make operational evidence more likely to be sent to the LLM.
OPERATIONAL_CUES = re.compile(
    r"(?i)\b("
    r"use|uses|used|using|deploy|deploys|deployed|deployment|implemented|implements|"
    r"integrated|integrates|embedded|operates|operational|automate|automates|automated|"
    r"recommend|recommends|detect|detects|forecast|forecasts|predict|predicts|"
    r"underwrite|underwrites|optimize|optimizes|personalize|personalizes"
    r")\b"
)

# These words are common in risk factors, future plans, or generic discussion.
# Snippets dominated by these cues are down-ranked during excerpt selection.
LOW_VALUE_CUES = re.compile(
    r"(?i)\b("
    r"risk|risks|could|may|might|intend|intends|plan|plans|future|potential|"
    r"regulation|regulatory|competition|competitors|cybersecurity|pilot|pilots|"
    r"proof of concept|experiment|experiments|research|trend|trends|market|markets|"
    r"opportunity|opportunities|demand|partner|partners|partnership|partnerships"
    r")\b"
)

AI_ADOPTION_LEVEL_CODES = {
    "none": 0,
    "low": 1,
    "medium": 2,
    "high": 3,
}

AI_LEVEL_CODE_LABELS = {code: label for label, code in AI_ADOPTION_LEVEL_CODES.items()}

BUSINESS_AREAS = {
    "product_service",
    "operations",
    "customer_service",
    "marketing_sales",
    "risk_fraud",
    "finance",
    "supply_chain",
    "r_and_d",
    "other",
}

BUSINESS_AREA_ALIASES = {
    "product": "product_service",
    "products": "product_service",
    "service": "product_service",
    "services": "product_service",
    "product/service": "product_service",
    "product_service": "product_service",
    "product services": "product_service",
    "customer service": "customer_service",
    "marketing": "marketing_sales",
    "sales": "marketing_sales",
    "marketing_sales": "marketing_sales",
    "risk": "risk_fraud",
    "fraud": "risk_fraud",
    "risk_fraud": "risk_fraud",
    "research": "r_and_d",
    "r&d": "r_and_d",
    "rd": "r_and_d",
}

EVIDENCE_STRENGTHS = {"weak", "moderate", "strong"}
EVIDENCE_STRENGTH_RANK = {"weak": 1, "moderate": 2, "strong": 3}

CENTRALITY_LEVELS = {"peripheral", "operational", "core"}
CENTRALITY_RANK = {"peripheral": 1, "operational": 2, "core": 3}

SOURCE_ITEMS = {"item_1", "item_7", "unknown"}
SOURCE_ITEM_ALIASES = {
    "1": "item_1",
    "item1": "item_1",
    "item_1": "item_1",
    "item 1": "item_1",
    "business": "item_1",
    "7": "item_7",
    "item7": "item_7",
    "item_7": "item_7",
    "item 7": "item_7",
    "md&a": "item_7",
    "mda": "item_7",
}

EXCLUSION_REASONS = {
    "future_only",
    "risk_only",
    "generic_market_discussion",
    "customer_only",
    "enabling_infrastructure",
    "vague",
    "not_ai",
    "other",
}

RETRYABLE_PARSE_STATUSES = {
    "missing_output",
    "no_json_found",
    "no_valid_score_json",
    "invalid_level_code",
    "conflicting_level_codes",
}

TEMPLATE_OUTPUT_CUES = re.compile(
    r"(?im)(^\s*def\s+|^\s*return\b|^\s*if\b|^\s*elif\b|^\s*else\s*:|^\s*###|^\s*##\s*step\b|^\s*solution\b)"
)


# ---------------------------------------------------------------------------
# Lightweight data structures
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class ChunkRef:
    """A chunk file available in the Data Workspace team S3 prefix."""

    name: str
    path: str


# ---------------------------------------------------------------------------
# Small generic helpers
# ---------------------------------------------------------------------------
# These helpers keep formatting, hashing, CIK matching, and keyword counting
# consistent across the main script and output QA.
def utc_now() -> str:
    """Return a compact UTC timestamp used as the run id."""

    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def sha256_text(text: str) -> str:
    """Hash text so snippets can be audited without storing the full text."""

    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def stable_unit_interval(value: str) -> float:
    """Map a string to a stable 0-to-1 value for reproducible audit sampling."""

    digest = hashlib.sha256(value.encode("utf-8")).hexdigest()
    return int(digest[:16], 16) / float(16 ** 16)


def normalize_whitespace(text: Any) -> str:
    """Convert missing values to empty strings and collapse noisy whitespace."""

    if text is None or (isinstance(text, float) and pd.isna(text)):
        return ""
    return WHITESPACE_RE.sub(" ", str(text).replace("\x00", " ")).strip()


def normalize_cik(value: Any) -> str:
    """Normalize CIK values so 1750 and 0001750 match the same firm."""

    if value is None or (isinstance(value, float) and pd.isna(value)):
        return ""
    text = str(value).strip()
    if text.endswith(".0"):
        text = text[:-2]
    text = re.sub(r"\D", "", text)
    return text.lstrip("0") or ("0" if text else "")


def count_ai_keywords(text: str) -> int:
    """Count broad AI prefilter keyword hits in filing text."""

    return len(list(AI_TRIGGER_KEYWORDS.finditer(text))) if text else 0


def count_ranking_keywords(text: str) -> int:
    """Count broader AI-adjacent keyword hits used for snippet ranking QA."""

    return len(list(AI_RANKING_KEYWORDS.finditer(text))) if text else 0


def chunk_name_from_id(chunk_id: int) -> str:
    """Convert chunk id 1 to extract_df_chunk_00001.rds."""

    if chunk_id < 1:
        raise ValueError("Chunk ids must be positive integers.")
    return f"extract_df_chunk_{chunk_id:05d}.rds"


def normalize_enum(
    value: Any,
    *,
    allowed: set[str],
    aliases: Optional[dict[str, str]] = None,
) -> str:
    """Normalize a categorical value against an allowed set."""

    if value is None or (isinstance(value, float) and pd.isna(value)):
        return ""
    raw = normalize_whitespace(value).lower()

    def canonicalize(text: str) -> str:
        text = text.strip().replace("-", "_").replace("/", "_").replace("&", "and")
        text = re.sub(r"\s+", "_", text)
        if aliases:
            text = aliases.get(text, text)
        return text

    text = canonicalize(raw)
    if text in allowed:
        return text

    multi_tokens = re.split(r"\s*(?:\||,|;| or )\s*", raw)
    for token in multi_tokens:
        candidate = canonicalize(token)
        if candidate in allowed:
            return candidate

    return ""


def normalize_bool(value: Any) -> Optional[bool]:
    """Normalize common truthy/falsey values to bool."""

    if isinstance(value, bool):
        return value
    if value is None or (isinstance(value, float) and pd.isna(value)):
        return None
    if isinstance(value, (int, float)) and value in {0, 1, 0.0, 1.0}:
        return bool(int(value))
    text = normalize_whitespace(value).lower()
    if text in {"true", "yes", "y", "1"}:
        return True
    if text in {"false", "no", "n", "0"}:
        return False
    return None


def canonical_use_case_key(use_case: str, business_area: str) -> str:
    """Create a deterministic key used to deduplicate repeated use-case mentions."""

    text = normalize_whitespace(use_case).lower()
    text = re.sub(r"[^a-z0-9\s]", " ", text)
    tokens = [token for token in text.split() if token not in {"the", "a", "an", "our", "their", "its"}]
    return f"{business_area}|{' '.join(tokens[:12])}"


def normalize_qualifying_use_case(obj: Any) -> dict[str, Any]:
    """Validate and normalize one qualifying AI use-case object."""

    if not isinstance(obj, dict):
        raise ValueError("qualifying_ai_use_cases entries must be JSON objects.")

    normalized = {
        "use_case": normalize_whitespace(obj.get("use_case", "")),
        "business_area": normalize_enum(
            obj.get("business_area"),
            allowed=BUSINESS_AREAS,
            aliases=BUSINESS_AREA_ALIASES,
        ),
        "current_use": normalize_bool(obj.get("current_use")),
        "firm_itself_uses_or_deploys": normalize_bool(obj.get("firm_itself_uses_or_deploys")),
        "evidence_strength": normalize_enum(obj.get("evidence_strength"), allowed=EVIDENCE_STRENGTHS),
        "centrality": normalize_enum(obj.get("centrality"), allowed=CENTRALITY_LEVELS),
        "source_item": normalize_enum(
            obj.get("source_item"),
            allowed=SOURCE_ITEMS,
            aliases=SOURCE_ITEM_ALIASES,
        ),
    }

    missing = [key for key, value in normalized.items() if value in {"", None}]
    if missing:
        raise ValueError(f"qualifying_ai_use_cases entry missing or invalid fields: {missing}")
    return normalized


def normalize_excluded_mention(obj: Any) -> dict[str, str]:
    """Validate and normalize one excluded mention object."""

    if not isinstance(obj, dict):
        raise ValueError("excluded_mentions entries must be JSON objects.")

    normalized = {
        "brief_description": normalize_whitespace(obj.get("brief_description", "")),
        "reason": normalize_enum(obj.get("reason"), allowed=EXCLUSION_REASONS),
    }
    missing = [key for key, value in normalized.items() if not value]
    if missing:
        raise ValueError(f"excluded_mentions entry missing or invalid fields: {missing}")
    return normalized


def deduplicate_qualifying_use_cases(use_cases: Sequence[dict[str, Any]]) -> list[dict[str, Any]]:
    """Deduplicate repeated use-case mentions while preserving the strongest record."""

    best_by_key: dict[str, dict[str, Any]] = {}
    for use_case in use_cases:
        key = canonical_use_case_key(use_case.get("use_case", ""), use_case.get("business_area", "other"))
        current = best_by_key.get(key)
        if current is None:
            best_by_key[key] = dict(use_case)
            continue
        candidate = dict(use_case)
        candidate_rank = (
            CENTRALITY_RANK.get(candidate.get("centrality", ""), 0),
            EVIDENCE_STRENGTH_RANK.get(candidate.get("evidence_strength", ""), 0),
            len(candidate.get("use_case", "")),
        )
        current_rank = (
            CENTRALITY_RANK.get(current.get("centrality", ""), 0),
            EVIDENCE_STRENGTH_RANK.get(current.get("evidence_strength", ""), 0),
            len(current.get("use_case", "")),
        )
        if candidate_rank > current_rank:
            best_by_key[key] = candidate
    return list(best_by_key.values())


def normalized_evidence_object(evidence: Optional[dict[str, Any]] = None) -> dict[str, list[dict[str, Any]]]:
    """Return an evidence object with guaranteed list fields."""

    evidence = evidence or {}
    qualifying = evidence.get("qualifying_ai_use_cases", [])
    excluded = evidence.get("excluded_mentions", [])
    return {
        "qualifying_ai_use_cases": list(qualifying) if isinstance(qualifying, list) else [],
        "excluded_mentions": list(excluded) if isinstance(excluded, list) else [],
    }


def filter_qualifying_current_use_cases(evidence: dict[str, Any]) -> list[dict[str, Any]]:
    """Return deduplicated current firm-use AI cases that qualify for scoring."""

    evidence = normalized_evidence_object(evidence)
    qualifying = [
        dict(use_case)
        for use_case in evidence["qualifying_ai_use_cases"]
        if bool(use_case.get("current_use")) and bool(use_case.get("firm_itself_uses_or_deploys"))
    ]
    return deduplicate_qualifying_use_cases(qualifying)


def determine_main_exclusion_reason(
    evidence: dict[str, Any],
    *,
    fallback_reason: str = "",
) -> str:
    """Choose the main exclusion reason used when final score is zero."""

    evidence = normalized_evidence_object(evidence)
    reasons = [item.get("reason", "") for item in evidence["excluded_mentions"] if item.get("reason")]
    if reasons:
        return Counter(reasons).most_common(1)[0][0]
    return fallback_reason


def classify_ai_adoption_from_evidence(evidence: dict) -> int:
    """Assign the final 0-3 AI adoption code deterministically from structured evidence."""

    qualifying = filter_qualifying_current_use_cases(evidence)
    if not qualifying:
        return 0

    n_use_cases = len(qualifying)
    business_areas = {item.get("business_area", "") for item in qualifying if item.get("business_area")}
    has_core_ai = any(item.get("centrality") == "core" for item in qualifying)
    n_strong_or_moderate = sum(
        1 for item in qualifying if item.get("evidence_strength") in {"moderate", "strong"}
    )

    if has_core_ai and n_use_cases >= 2 and n_strong_or_moderate >= 2:
        return 3
    if n_use_cases >= 2 or len(business_areas) >= 2:
        return 2
    return 1


def summarize_evidence(evidence: dict[str, Any], *, fallback_zero_reason: str = "") -> dict[str, Any]:
    """Return deterministic summary metrics derived from structured evidence."""

    qualifying = filter_qualifying_current_use_cases(evidence)
    ai_level_code = classify_ai_adoption_from_evidence(evidence)
    return {
        "qualifying_ai_use_cases": qualifying,
        "excluded_mentions": normalized_evidence_object(evidence)["excluded_mentions"],
        "n_qualifying_use_cases": len(qualifying),
        "n_business_areas": len({item.get("business_area", "") for item in qualifying if item.get("business_area")}),
        "has_core_ai": any(item.get("centrality") == "core" for item in qualifying),
        "main_exclusion_reason_if_zero": determine_main_exclusion_reason(
            evidence,
            fallback_reason=fallback_zero_reason,
        )
        if ai_level_code == 0
        else "",
        "ai_level_code": ai_level_code,
        "ai_adopted_binary": int(ai_level_code >= 1),
        "ai_adopted_medium": int(ai_level_code >= 2),
        "ai_adopted_core": int(ai_level_code >= 3),
    }


# ---------------------------------------------------------------------------
# Output formatting helpers
# ---------------------------------------------------------------------------
# These functions keep the per-filing CSV columns stable and write JSON summary
# files in a readable format.
def preferred_output_columns(save_raw_json: bool) -> list[str]:
    """Return the preferred CSV column order."""

    # Status fields keep the historical "score" wording for compatibility with
    # older QA outputs and merge scripts, even though the main outputs are now
    # binary and ordinal labels.
    cols = [
        "run_id",
        "script_version",
        "prompt_version",
        "llm_model",
        "llm_checkpoint",
        "temperature",
        "max_new_tokens",
        "source_label",
        "chunk_id",
        "accession_number",
        "filing_accession",
        "cik",
        "year",
        "form_type",
        "has_item1",
        "has_item7",
        "item1_chars",
        "item7_chars",
        "combined_chars",
        "keyword_hits",
        "ranking_keyword_hits",
        "prefilter_mode",
        "prefilter_decision",
        "prefilter_audit_sample",
        "snippet_chars",
        "llm_called",
        "endpoint_attempts",
        "parse_status",
        "initial_score_status",
        "retry_attempted",
        "retry_score_status",
        "ai_adopted",
        "ai_adoption_level",
        "ai_adoption_level_code",
        "ai_adopted_binary",
        "ai_adopted_medium",
        "ai_adopted_core",
        "n_qualifying_use_cases",
        "n_business_areas",
        "has_core_ai",
        "main_exclusion_reason_if_zero",
        "explanation",
        "score_status",
        "endpoint",
        "job_id",
        "retry_job_id",
        "snippet_sha256",
        "raw_json_sha256",
        "evidence_json_sha256",
        "qualifying_ai_use_cases_json",
        "excluded_mentions_json",
    ]
    if save_raw_json:
        cols.append("raw_model_output")
        cols.append("raw_json")
    return cols


def order_columns(df: pd.DataFrame, save_raw_json: bool) -> pd.DataFrame:
    """Put key QA columns first while preserving any extra columns at the end."""

    preferred = preferred_output_columns(save_raw_json)
    if df.empty:
        return pd.DataFrame(columns=preferred)
    existing = [col for col in preferred if col in df.columns]
    extra = [col for col in df.columns if col not in existing]
    return df[existing + extra]


def write_json(path: str, payload: dict[str, Any]) -> None:
    """Write a JSON file with stable formatting."""

    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, ensure_ascii=False, default=str)


# ---------------------------------------------------------------------------
# Data Workspace S3 helpers
# ---------------------------------------------------------------------------
# Data Workspace exposes team S3 folders through dwutils.s3. Reading uses
# dwutils.s3.read. Listing still uses boto3 because dwutils.s3 has read/write
# helpers but no object-listing helper
def get_team_prefix(team: str) -> str:
    """Return the Data Workspace S3 key prefix for a team folder."""

    from dwutils import s3

    teams = s3.list_team_folders()
    if team not in teams:
        raise ValueError(f"Unknown team {team!r}. Available teams: {sorted(teams)}")
    return teams[team]["s3_key"].strip("/")


def list_chunks(team: str, chunk_prefix: str = "", bucket: str = DEFAULT_BUCKET) -> dict[str, ChunkRef]:
    """List valid chunk files under a Data Workspace team folder."""

    import boto3

    team_prefix = get_team_prefix(team)
    prefix = "/".join(part.strip("/") for part in [team_prefix, chunk_prefix] if part.strip("/"))
    paginator = boto3.client("s3").get_paginator("list_objects_v2")

    refs: dict[str, ChunkRef] = {}
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix.rstrip("/") + "/"):
        for obj in page.get("Contents", []):
            path = obj["Key"][len(team_prefix) :].strip("/")
            name = Path(path).name
            if CHUNK_RE.match(name):
                refs[name] = ChunkRef(name=name, path=path)
    return dict(sorted(refs.items()))


# ---------------------------------------------------------------------------
# Chunk selection helpers
# ---------------------------------------------------------------------------
# Users can select chunks by exact filename, numeric id, numeric range, or all
# available chunks. This function turns that choice into concrete ChunkRef rows.
def select_chunks(
    available: dict[str, ChunkRef],
    chunk_names: Optional[Sequence[str]],
    chunk_ids: Optional[Sequence[int]],
    chunk_range: Optional[Sequence[int]],
    all_chunks: bool,
    max_chunks: Optional[int],
) -> list[ChunkRef]:
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
    seen = set()
    for name in names:
        if name not in available:
            raise FileNotFoundError(f"Chunk not found under the team prefix: {name}")
        ref = available[name]
        if ref.path not in seen:
            selected.append(ref)
            seen.add(ref.path)

    return selected[:max_chunks] if max_chunks else selected


# ---------------------------------------------------------------------------
# RDS reading
# ---------------------------------------------------------------------------
# pyreadr reads from a file path, while dwutils.s3.read returns bytes. This
# helper bridges those two APIs using a temporary file.
def read_rds_from_team_s3(path: str, team: str) -> pd.DataFrame:
    """Read one RDS object from Data Workspace team S3 using dwutils.s3."""

    from dwutils import s3
    import pyreadr

    with s3.read(path=path, team=team) as stream:
        with tempfile.NamedTemporaryFile(suffix=".rds", delete=True) as tmp:
            tmp.write(stream.read())
            tmp.flush()
            result = pyreadr.read_r(tmp.name)

    if not result:
        raise ValueError(f"No readable objects found in team={team}, path={path}")

    df = next(iter(result.values()))
    if not isinstance(df, pd.DataFrame):
        raise TypeError(f"First object in team={team}, path={path} is not a DataFrame")
    return df


# ---------------------------------------------------------------------------
# Lookup loading and filing-level data reshaping
# ---------------------------------------------------------------------------
# The lookup filter is where the research sample enters the process. The LLM is
# only called for filing rows that survive this cik/year filter.
def load_cik_year_lookup(path: Optional[str]) -> Optional[pd.DataFrame]:
    """Read the optional research lookup and normalize cik/year match keys."""

    if not path:
        return None

    lookup = pd.read_csv(path)
    lookup.columns = [str(col).strip().lower() for col in lookup.columns]
    missing = {"cik", "year"} - set(lookup.columns)
    if missing:
        raise ValueError(f"Lookup CSV is missing required columns: {sorted(missing)}")

    lookup = lookup[["cik", "year"]].copy()
    lookup["cik_match"] = lookup["cik"].apply(normalize_cik)
    lookup["year_match"] = pd.to_numeric(lookup["year"], errors="coerce").astype("Int64")
    lookup = lookup[(lookup["cik_match"] != "") & lookup["year_match"].notna()]
    lookup = lookup.drop_duplicates(["cik_match", "year_match"]).reset_index(drop=True)
    if lookup.empty:
        raise ValueError(f"Lookup CSV contains no usable cik/year pairs: {path}")

    logging.info("Loaded lookup %s with %d unique cik/year pairs", path, len(lookup))
    return lookup[["cik_match", "year_match"]]


def long_to_wide(df: pd.DataFrame, include_amended: bool) -> pd.DataFrame:
    """
    Convert long-format Item 1 / Item 7 rows into one row per filing.

    The labeling methodology works at filing level, so each accession number
    needs its Item 1 and Item 7 text side by side.
    """

    required = {"item", "year", "accession_number", "cik", "form_type", "text"}
    missing = required - set(df.columns)
    if missing:
        raise ValueError(f"Missing required columns: {sorted(missing)}")

    # Standardise key fields before filtering and grouping.
    work = df.copy()
    work["item"] = work["item"].astype(str).str.strip().str.lower()
    work["form_type"] = work["form_type"].astype(str).str.upper().str.strip()
    work["accession_number"] = work["accession_number"].astype(str).str.strip()
    work["cik"] = work["cik"].astype(str).str.strip()
    work["text"] = work["text"].apply(normalize_whitespace)

    # Keep annual filings and the two disclosure sections used in the label.
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

    # Collapse duplicate section rows, then pivot item1/item7 into columns.
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
    # Add section labels before concatenation so the model sees the source.
    wide["combined_text"] = (
        "ITEM 1 BUSINESS:\n"
        + wide["item1_text"].fillna("").astype(str)
        + "\n\nITEM 7 MD&A:\n"
        + wide["item7_text"].fillna("").astype(str)
    )
    wide["combined_chars"] = wide["combined_text"].astype(str).str.len()
    return wide[base_cols].sort_values(["accession_number"]).reset_index(drop=True)


def filter_to_lookup(wide: pd.DataFrame, lookup: Optional[pd.DataFrame]) -> pd.DataFrame:
    """Keep only filing rows whose normalized cik/year appears in the lookup."""

    if lookup is None or wide.empty:
        return wide

    work = wide.copy()
    work["cik_match"] = work["cik"].apply(normalize_cik)
    work["year_match"] = pd.to_numeric(work["year"], errors="coerce").astype("Int64")
    filtered = work.merge(lookup, on=["cik_match", "year_match"], how="inner")
    filtered = filtered.drop(columns=["cik_match", "year_match"])
    dedupe_cols = [col for col in ["accession_number", "cik", "year", "form_type"] if col in filtered.columns]
    filtered = filtered.drop_duplicates(dedupe_cols)
    return filtered.reset_index(drop=True)


# ---------------------------------------------------------------------------
# Snippet extraction
# ---------------------------------------------------------------------------
# Full filings are too long for practical prompting. These functions find
# AI-related sentences, keep a small context window, and prioritise operational
# evidence over boilerplate.
def split_into_sentences(text: str) -> list[str]:
    """Split text into rough sentences for keyword-window selection."""

    text = normalize_whitespace(text)
    if not text:
        return []
    return [part.strip() for part in SENTENCE_SPLIT_RE.split(text) if part and part.strip()] or [text]


def extract_relevant_snippets(full_text: str, max_chars: int, sentence_window: int) -> str:
    """Extract a prompt-sized excerpt from the filing text."""

    full_text = normalize_whitespace(full_text)
    if not full_text:
        return ""

    sentences = split_into_sentences(full_text)
    hit_idx = [i for i, sentence in enumerate(sentences) if AI_RANKING_KEYWORDS.search(sentence)]
    if not hit_idx:
        return full_text[:max_chars]

    # Build context windows around every AI keyword hit.
    windows = []
    for idx in hit_idx:
        lo = max(0, idx - sentence_window)
        hi = min(len(sentences), idx + sentence_window + 1)
        indices = list(range(lo, hi))
        window_text = " ".join(sentences[i] for i in indices)
        # Rank windows with operational cues above risk/future-looking text.
        score = 0
        if AI_TRIGGER_KEYWORDS.search(window_text):
            score += 5
        if AI_TRIGGER_KEYWORDS.search(sentences[idx]):
            score += 3
        if AI_RANKING_ONLY_KEYWORDS.search(sentences[idx]):
            score += 1
        if OPERATIONAL_CUES.search(window_text):
            score += 4
        if OPERATIONAL_CUES.search(sentences[idx]):
            score += 2
        if LOW_VALUE_CUES.search(sentences[idx]):
            score -= 2
        if LOW_VALUE_CUES.search(window_text):
            score -= 1
        windows.append((score, idx, indices))

    windows.sort(key=lambda item: (-item[0], item[1]))

    # Select best-ranked windows without repeating sentences.
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

    # Return selected sentences in original filing order for readability.
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
# Prompt construction
# ---------------------------------------------------------------------------
# The extraction instructions are kept in one shared helper so the first pass
# and retry pass apply the same evidence rule while differing only in formatting
# strictness.
def _evidence_extraction_rules() -> str:
    """Return the shared structured-evidence extraction rules."""

    return (
        "Extract structured evidence of the firm's current AI adoption from the filing text.\n"
        "The text comes from Form 10-K Item 1 (Business) and Item 7 (MD&A).\n\n"
        "A qualifying AI use case must satisfy all of the following:\n"
        "1. The text describes a concrete AI system, model, feature, workflow, product function, or operational process.\n"
        "2. The firm itself currently uses, deploys, embeds, or operates it in its own products, services, or internal operations.\n"
        "3. The evidence refers to current or already implemented use, not only future plans.\n\n"
        "Treat the following as AI evidence only when clearly described as such: machine learning, deep learning, generative AI, NLP, computer vision, predictive models, recommendation systems, autonomous systems, or algorithmic decision systems.\n\n"
        "Do not count:\n"
        "1. Generic AI discussion or market trends.\n"
        "2. Risk factor language only.\n"
        "3. Future plans, pilots, intentions, or exploration only.\n"
        "4. Customer use of AI unless the firm's own product or service embeds AI functionality.\n"
        "5. Chips, cloud, data centres, software, or infrastructure that merely enable customers to build or run AI.\n"
        "6. AI talent, partnerships, acquisitions, or investments without a concrete deployed use case.\n"
        "7. Vague innovation, automation, analytics, algorithm, or digital transformation language unless clearly tied to AI or ML use.\n\n"
        "Count distinct use cases by business function, product, or workflow, not by repeated wording.\n"
        "If there is no qualifying evidence, return an empty qualifying_ai_use_cases list.\n"
        "If unsure, exclude the mention rather than include it.\n"
    )


def _evidence_output_schema() -> str:
    """Return the required evidence JSON schema."""

    return (
        "{\n"
        '  "qualifying_ai_use_cases": [\n'
        "    {\n"
        '      "use_case": "short description",\n'
        '      "business_area": "product_service|operations|customer_service|marketing_sales|risk_fraud|finance|supply_chain|r_and_d|other",\n'
        '      "current_use": true,\n'
        '      "firm_itself_uses_or_deploys": true,\n'
        '      "evidence_strength": "weak|moderate|strong",\n'
        '      "centrality": "peripheral|operational|core",\n'
        '      "source_item": "item_1|item_7|unknown"\n'
        "    }\n"
        "  ],\n"
        '  "excluded_mentions": [\n'
        "    {\n"
        '      "brief_description": "short description",\n'
        '      "reason": "future_only|risk_only|generic_market_discussion|customer_only|enabling_infrastructure|vague|not_ai|other"\n'
        "    }\n"
        "  ]\n"
        "}\n"
    )


def build_ai_prompt(text: str) -> str:
    """Build the main evidence-extraction prompt for one filing text."""

    return (
        "You are extracting structured evidence of firm AI adoption from filing text.\n\n"
        f"{_evidence_extraction_rules()}\n"
        "FILING TEXT TO EVALUATE:\n"
        "<filing_text>\n"
        f"{text}\n"
        "</filing_text>\n\n"
        "Return ONLY one valid JSON object and no other text.\n"
        "Use exactly this schema:\n"
        f"{_evidence_output_schema()}"
        "Do not return markdown, bullets, commentary, code fences, or any text before or after the JSON object."
    )


def build_ai_retry_prompt(text: str) -> str:
    """Build a stricter JSON-only retry prompt with the same evidence rule."""

    return (
        "Return ONLY one valid JSON object.\n"
        "Do not explain your answer.\n"
        "Do not return markdown.\n"
        "Do not return multiple JSON objects.\n\n"
        f"{_evidence_extraction_rules()}\n"
        "FILING TEXT TO EVALUATE:\n"
        "<filing_text>\n"
        f"{text}\n"
        "</filing_text>\n\n"
        "Use exactly this schema:\n"
        f"{_evidence_output_schema()}"
        "Output the JSON object only."
    )


# ---------------------------------------------------------------------------
# Model response parsing
# ---------------------------------------------------------------------------
# Model endpoints can return strings, dictionaries, lists, prompt echoes, or
# repeated JSON. These helpers extract the generated text, validate candidate
# JSON label objects, and reject conflicting label codes.
def extract_text_from_response(resp: Any) -> str:
    """Extract generated text from common endpoint response shapes."""

    if resp is None:
        return ""
    if isinstance(resp, str):
        return resp
    if isinstance(resp, list):
        for item in resp:
            text = extract_text_from_response(item)
            if text:
                return text
        return json.dumps(resp, ensure_ascii=False)
    if isinstance(resp, dict):
        for key in ["generated_text", "text", "output", "response", "completion", "content"]:
            if key in resp and resp[key] is not None:
                text = extract_text_from_response(resp[key])
                if text:
                    return text
        for key in ["choices", "message", "outputs"]:
            if key in resp:
                text = extract_text_from_response(resp[key])
                if text:
                    return text
        return json.dumps(resp, ensure_ascii=False)
    return str(resp)


def extract_balanced_json_objects(text: str) -> list[str]:
    """Find balanced JSON-looking objects while respecting quoted strings."""

    objects: list[str] = []
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
            objects.append(text[start : found_end + 1])
            start = found_end + 1
    return objects


def parse_level_code(value: Any) -> Any:
    """Parse ai_level_code into an integer 0/1/2/3 when possible."""

    if isinstance(value, bool):
        return pd.NA
    if isinstance(value, int) and value in {0, 1, 2, 3}:
        return int(value)
    if isinstance(value, float) and value in {0.0, 1.0, 2.0, 3.0}:
        return int(value)
    if value is None or (isinstance(value, float) and pd.isna(value)):
        return pd.NA

    lowered = str(value).strip().lower()
    alias_map = {
        "0": 0,
        "none": 0,
        "no adoption": 0,
        "non-adopter": 0,
        "non adopter": 0,
        "1": 1,
        "low": 1,
        "2": 2,
        "medium": 2,
        "med": 2,
        "3": 3,
        "high": 3,
    }
    return alias_map.get(lowered, pd.NA)


def adoption_level_code(level: Any) -> Any:
    """Return the integer code for a normalized adoption level."""

    normalized = str(level).strip().lower()
    if normalized in AI_ADOPTION_LEVEL_CODES:
        return AI_ADOPTION_LEVEL_CODES[normalized]
    return pd.NA


def adoption_level_label(code: Any) -> str:
    """Return the normalized label for a valid adoption level code."""

    parsed = parse_level_code(code)
    if pd.isna(parsed):
        return ""
    return AI_LEVEL_CODE_LABELS[int(parsed)]


def derive_adoption_outputs(level_code: Any) -> tuple[Any, Any, Any]:
    """Derive ai_adopted, label, and code from one valid ordinal level code."""

    parsed = parse_level_code(level_code)
    if pd.isna(parsed):
        return pd.NA, pd.NA, pd.NA
    parsed = int(parsed)
    return int(parsed > 0), adoption_level_label(parsed), parsed


def parse_evidence_object(obj: Any) -> dict[str, list[dict[str, Any]]]:
    """Validate one parsed JSON object as a structured AI-evidence response."""

    if not isinstance(obj, dict):
        raise ValueError("Parsed JSON was not an object.")

    # Salvage the common Llama pattern where it returns one qualifying use case
    # object directly instead of wrapping it in the requested top-level lists.
    use_case_keys = {
        "use_case",
        "business_area",
        "current_use",
        "firm_itself_uses_or_deploys",
        "evidence_strength",
        "centrality",
        "source_item",
    }
    if use_case_keys.issubset(obj.keys()):
        obj = {
            "qualifying_ai_use_cases": [obj],
            "excluded_mentions": [],
        }
    elif "qualifying_ai_use_cases" not in obj or "excluded_mentions" not in obj:
        raise ValueError("JSON object must contain qualifying_ai_use_cases and excluded_mentions.")

    qualifying_raw = obj.get("qualifying_ai_use_cases")
    excluded_raw = obj.get("excluded_mentions")
    if not isinstance(qualifying_raw, list) or not isinstance(excluded_raw, list):
        raise ValueError("qualifying_ai_use_cases and excluded_mentions must both be lists.")

    qualifying = [normalize_qualifying_use_case(item) for item in qualifying_raw]
    excluded = [normalize_excluded_mention(item) for item in excluded_raw]
    return {
        "qualifying_ai_use_cases": deduplicate_qualifying_use_cases(qualifying),
        "excluded_mentions": excluded,
    }


def explain_evidence_summary(summary: dict[str, Any]) -> str:
    """Create a short deterministic explanation from derived evidence metrics."""

    n_use_cases = int(summary.get("n_qualifying_use_cases", 0) or 0)
    n_business_areas = int(summary.get("n_business_areas", 0) or 0)
    if n_use_cases == 0:
        reason = summary.get("main_exclusion_reason_if_zero", "") or "no_qualifying_current_firm_use"
        return f"No qualifying current firm-use AI cases were extracted. Main exclusion reason: {reason}."

    level_code = int(summary.get("ai_level_code", 0) or 0)
    label = adoption_level_label(level_code)
    return (
        f"Extracted {n_use_cases} distinct qualifying current AI use case(s) "
        f"across {n_business_areas} business area(s); derived filing-level label: {label}."
    )


def build_parse_result_from_evidence(
    evidence: dict[str, Any],
    *,
    raw_json: str,
    parse_error_code: str,
    fallback_zero_reason: str = "",
) -> dict[str, Any]:
    """Build the standardized parse result payload from validated evidence."""

    summary = summarize_evidence(evidence, fallback_zero_reason=fallback_zero_reason)
    ai_adopted, ai_adoption_level, ai_level_code = derive_adoption_outputs(summary["ai_level_code"])
    explanation = explain_evidence_summary(summary)
    evidence_json = {
        "qualifying_ai_use_cases": summary["qualifying_ai_use_cases"],
        "excluded_mentions": normalized_evidence_object(evidence)["excluded_mentions"],
    }
    return {
        "evidence": evidence_json,
        "ai_adopted": ai_adopted,
        "ai_adoption_level": ai_adoption_level,
        "ai_adoption_level_code": ai_level_code,
        "ai_adopted_binary": summary["ai_adopted_binary"],
        "ai_adopted_medium": summary["ai_adopted_medium"],
        "ai_adopted_core": summary["ai_adopted_core"],
        "n_qualifying_use_cases": summary["n_qualifying_use_cases"],
        "n_business_areas": summary["n_business_areas"],
        "has_core_ai": summary["has_core_ai"],
        "main_exclusion_reason_if_zero": summary["main_exclusion_reason_if_zero"],
        "explanation": explanation,
        "status": parse_error_code,
        "raw_json": raw_json,
    }


def extract_level_code_from_text(text: str) -> Any:
    """Loosely extract one direct ai_level_code assignment from non-JSON text."""

    if TEMPLATE_OUTPUT_CUES.search(text):
        return pd.NA

    direct_matches = re.findall(
        r'(?is)\bai_level_code\b\s*["\']?\s*[:=]\s*["\']?(0|1|2|3|none|low|medium|med|high|no adoption|non-adopter|non adopter)\b',
        text,
    )
    phrase_matches = re.findall(
        r'(?is)\b(?:ai adoption classification code|classification code)\b[^0-9a-z]{0,20}(?:is|=|:)?[^0-9a-z]{0,20}(0|1|2|3|none|low|medium|med|high|no adoption|non-adopter|non adopter)\b',
        text,
    )
    matches = [parse_level_code(match) for match in direct_matches + phrase_matches]
    matches = [int(match) for match in matches if pd.notna(match)]
    distinct_matches = sorted(set(matches))
    if len(distinct_matches) != 1:
        return pd.NA
    return distinct_matches[0]


def parse_model_output_payload(text: str, *, fallback_zero_reason: str = "") -> dict[str, Any]:
    """Parse raw model output into validated evidence plus derived filing-level outputs."""

    if not text:
        return {
            "evidence": normalized_evidence_object(),
            "ai_adopted": pd.NA,
            "ai_adoption_level": pd.NA,
            "ai_adoption_level_code": pd.NA,
            "ai_adopted_binary": pd.NA,
            "ai_adopted_medium": pd.NA,
            "ai_adopted_core": pd.NA,
            "n_qualifying_use_cases": 0,
            "n_business_areas": 0,
            "has_core_ai": False,
            "main_exclusion_reason_if_zero": "",
            "explanation": "No model output returned.",
            "status": "missing_output",
            "raw_json": "",
        }

    candidates = extract_balanced_json_objects(text)
    valid_candidates: list[tuple[dict[str, list[dict[str, Any]]], str]] = []
    for candidate in candidates:
        try:
            obj = json.loads(candidate)
        except Exception:
            continue
        try:
            evidence = parse_evidence_object(obj)
        except Exception:
            continue
        valid_candidates.append((evidence, candidate))

    if valid_candidates:
        normalized_raw_jsons = {json.dumps(item[0], sort_keys=True) for item in valid_candidates}
        if len(normalized_raw_jsons) > 1:
            return {
                "evidence": normalized_evidence_object(),
                "ai_adopted": pd.NA,
                "ai_adoption_level": pd.NA,
                "ai_adoption_level_code": pd.NA,
                "ai_adopted_binary": pd.NA,
                "ai_adopted_medium": pd.NA,
                "ai_adopted_core": pd.NA,
                "n_qualifying_use_cases": 0,
                "n_business_areas": 0,
                "has_core_ai": False,
                "main_exclusion_reason_if_zero": "",
                "explanation": "Model output contained conflicting evidence JSON objects.",
                "status": "conflicting_level_codes",
                "raw_json": valid_candidates[-1][1],
            }
        evidence, raw_json = valid_candidates[-1]
        return build_parse_result_from_evidence(
            evidence,
            raw_json=raw_json,
            parse_error_code="ok",
            fallback_zero_reason=fallback_zero_reason,
        )

    status = "no_json_found" if not candidates else "no_valid_score_json"
    explanation = (
        "Model output did not contain valid JSON."
        if status == "no_json_found"
        else "Model output did not contain usable evidence JSON."
    )
    return {
        "evidence": normalized_evidence_object(),
        "ai_adopted": pd.NA,
        "ai_adoption_level": pd.NA,
        "ai_adoption_level_code": pd.NA,
        "ai_adopted_binary": pd.NA,
        "ai_adopted_medium": pd.NA,
        "ai_adopted_core": pd.NA,
        "n_qualifying_use_cases": 0,
        "n_business_areas": 0,
        "has_core_ai": False,
        "main_exclusion_reason_if_zero": "",
        "explanation": explanation,
        "status": status,
        "raw_json": candidates[-1] if candidates else "",
    }


def parse_model_output(text: str) -> tuple[Any, Any, Any, str, str, str]:
    """Compatibility wrapper that returns the historical tuple shape."""

    result = parse_model_output_payload(text)
    if result["status"] != "ok":
        level_code = extract_level_code_from_text(text)
        if pd.notna(level_code):
            ai_adopted, ai_adoption_level, ai_adoption_level_code = derive_adoption_outputs(level_code)
            return (
                ai_adopted,
                ai_adoption_level,
                ai_adoption_level_code,
                "Recovered filing-level classification code from non-JSON model output.",
                "ok",
                "",
            )
    return (
        result["ai_adopted"],
        result["ai_adoption_level"],
        result["ai_adoption_level_code"],
        result["explanation"],
        result["status"],
        result["raw_json"],
    )


# ---------------------------------------------------------------------------
# Per-filing record preparation
# ---------------------------------------------------------------------------
# These helpers create the output row for each filing, apply empty-text and
# prefilter rules, and build prompts only for filings that need the LLM.
def base_output_record(
    row: pd.Series,
    *,
    run_id: str,
    source_label: str,
    chunk_id: str,
    llm_model: str,
    llm_checkpoint: str,
    temperature: float,
    max_new_tokens: int,
    endpoint: str,
    prefilter_mode: str,
    prefilter_audit_sample: bool,
) -> dict[str, Any]:
    """Create the standard output record before labeling decisions are applied."""

    year = row.get("year", pd.NA)
    year = int(year) if pd.notna(year) else pd.NA
    return {
        "run_id": run_id,
        "script_version": SCRIPT_VERSION,
        "prompt_version": PROMPT_VERSION,
        "llm_model": llm_model,
        "llm_checkpoint": llm_checkpoint,
        "temperature": float(temperature),
        "max_new_tokens": int(max_new_tokens),
        "source_label": source_label,
        "chunk_id": chunk_id,
        "accession_number": str(row.get("accession_number", "")).strip(),
        "filing_accession": str(row.get("accession_number", "")).strip(),
        "cik": str(row.get("cik", "")).strip(),
        "year": year,
        "form_type": str(row.get("form_type", "")).strip(),
        "has_item1": bool(row.get("has_item1", False)),
        "has_item7": bool(row.get("has_item7", False)),
        "item1_chars": int(row.get("item1_chars", 0) or 0),
        "item7_chars": int(row.get("item7_chars", 0) or 0),
        "combined_chars": int(row.get("combined_chars", 0) or 0),
        "keyword_hits": 0,
        "ranking_keyword_hits": 0,
        "prefilter_mode": prefilter_mode,
        "prefilter_decision": "not_applicable",
        "prefilter_audit_sample": bool(prefilter_audit_sample),
        "snippet_chars": 0,
        "llm_called": False,
        "endpoint_attempts": 0,
        "parse_status": "not_called",
        "initial_score_status": "",
        "retry_attempted": False,
        "retry_score_status": "",
        "ai_adopted": pd.NA,
        "ai_adoption_level": pd.NA,
        "ai_adoption_level_code": pd.NA,
        "ai_adopted_binary": pd.NA,
        "ai_adopted_medium": pd.NA,
        "ai_adopted_core": pd.NA,
        "n_qualifying_use_cases": 0,
        "n_business_areas": 0,
        "has_core_ai": False,
        "main_exclusion_reason_if_zero": "",
        "explanation": "",
        "score_status": "",
        "endpoint": endpoint,
        "job_id": "",
        "retry_job_id": "",
        "snippet_sha256": "",
        "raw_json_sha256": "",
        "evidence_json_sha256": "",
        "qualifying_ai_use_cases_json": "[]",
        "excluded_mentions_json": "[]",
    }


def build_sagemaker_payload(prompt: str, parameters: dict[str, Any]) -> str:
    """Wrap a prompt and generation parameters in the JSON SageMaker expects."""

    return json.dumps({"inputs": prompt, "parameters": parameters})


# ---------------------------------------------------------------------------
# Bulk invocation argument preparation
# ---------------------------------------------------------------------------
# bulk_invoke_endpoint_async expects an iterable of (linked object, kwargs)
# pairs. The linked object is a row identifier that lets us join results back to
# the correct output record after SageMaker returns.
def iter_bulk_invoke_args(
    pending: dict[str, dict[str, Any]],
    *,
    endpoint: str,
    temperature: float,
    max_new_tokens: int,
) -> Iterable[tuple[str, dict[str, Any]]]:
    """Yield arguments for dwutils.sm.bulk_invoke_endpoint_async."""

    parameters = {
        "temperature": temperature,
        "max_new_tokens": max_new_tokens,
        "return_full_text": False,
    }
    for linked_obj, item in pending.items():
        yield (
            linked_obj,
            {
                "EndpointName": endpoint,
                "Input": build_sagemaker_payload(item["prompt"], parameters),
                "ContentType": "application/json",
            },
        )


def prepare_records_and_prompts(
    wide: pd.DataFrame,
    *,
    run_id: str,
    chunk_id: str,
    source_label: str,
    llm_model: str,
    llm_checkpoint: str,
    temperature: float,
    max_new_tokens: int,
    endpoint: str,
    prefilter_mode: str,
    audit_seed: str,
    prefilter_audit_rate: float,
    prefilter_audit_limit: int,
    max_prompt_chars: int,
    sentence_window: int,
) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]]]:
    """
    Prepare output records and collect pending LLM prompts.

    Returns:
        records: one output row per filing, including prefilter-zero rows
        pending: only rows that need a bulk LLM call
    """

    records: list[dict[str, Any]] = []
    pending: dict[str, dict[str, Any]] = {}
    audit_calls = 0

    for row_number, (_, row) in enumerate(wide.iterrows(), start=1):
        # Work out whether this filing should be skipped, audited, or sent to
        # the LLM.
        accession = str(row.get("accession_number", "")).strip()
        full_text = normalize_whitespace(row.get("combined_text", ""))
        keyword_hits = count_ai_keywords(full_text)
        ranking_keyword_hits = count_ranking_keywords(full_text)

        # Audit mode sends a stable sample of no-keyword filings to the LLM so
        # the false-zero risk of the prefilter can be measured.
        audit_sample = False
        if prefilter_mode == "audit" and keyword_hits == 0:
            sampled = stable_unit_interval(f"{audit_seed}|{accession}") < prefilter_audit_rate
            under_limit = prefilter_audit_limit <= 0 or audit_calls < prefilter_audit_limit
            audit_sample = sampled and under_limit
            if audit_sample:
                audit_calls += 1

        # Start with the standard output fields, then fill in the labeling path.
        record = base_output_record(
            row,
            run_id=run_id,
            source_label=source_label,
            chunk_id=chunk_id,
            llm_model=llm_model,
            llm_checkpoint=llm_checkpoint,
            temperature=temperature,
            max_new_tokens=max_new_tokens,
            endpoint=endpoint,
            prefilter_mode=prefilter_mode,
            prefilter_audit_sample=audit_sample,
        )
        record["keyword_hits"] = keyword_hits
        record["ranking_keyword_hits"] = ranking_keyword_hits

        # Empty filings get a transparent zero without an LLM call.
        if not full_text:
            record.update(
                ai_adopted=0,
                ai_adoption_level="none",
                ai_adoption_level_code=0,
                ai_adopted_binary=0,
                ai_adopted_medium=0,
                ai_adopted_core=0,
                n_qualifying_use_cases=0,
                n_business_areas=0,
                has_core_ai=False,
                main_exclusion_reason_if_zero="empty_text",
                explanation="No text was available after combining Item 1 and Item 7.",
                score_status="empty_text_zero",
                prefilter_decision="empty_text",
            )
        # No-keyword filings are skipped in hard_zero mode and mostly skipped
        # in audit mode.
        elif keyword_hits == 0 and prefilter_mode in {"hard_zero", "audit"} and not audit_sample:
            record.update(
                ai_adopted=0,
                ai_adoption_level="none",
                ai_adoption_level_code=0,
                ai_adopted_binary=0,
                ai_adopted_medium=0,
                ai_adopted_core=0,
                n_qualifying_use_cases=0,
                n_business_areas=0,
                has_core_ai=False,
                main_exclusion_reason_if_zero="no_ai_keywords_prefilter",
                explanation="No AI dictionary keywords were detected by the prefilter, so the filing was labeled as a non-adopter without an LLM call.",
                score_status="prefilter_zero_no_keyword",
                prefilter_decision=f"{prefilter_mode}_zero_no_keyword",
            )
        # All remaining filings need snippets and LLM prompts.
        else:
            snippet = extract_relevant_snippets(full_text, max_prompt_chars, sentence_window)
            if not snippet:
                record.update(
                    parse_status="failed",
                    explanation="Snippet extraction returned empty text.",
                    score_status="snippet_extraction_failed",
                )
            else:
                job_id = f"{run_id}_{chunk_id}_{row_number:06d}"
                record.update(
                    prefilter_decision="audit_call_no_keyword"
                    if audit_sample
                    else ("llm_call_no_trigger_prefilter_off" if keyword_hits == 0 else "keyword_hit_llm_call"),
                    snippet_chars=len(snippet),
                    llm_called=True,
                    endpoint_attempts=1,
                    job_id=job_id,
                    snippet_sha256=sha256_text(snippet),
                )
                # linked_obj is the bridge between the bulk result and this row.
                linked_obj = str(len(records))
                pending[linked_obj] = {
                    "record_index": len(records),
                    "prompt": build_ai_prompt(snippet),
                    "retry_prompt": build_ai_retry_prompt(snippet),
                }

        records.append(record)

    return records, pending


# ---------------------------------------------------------------------------
# Bulk result handling
# ---------------------------------------------------------------------------
# This function takes the iterator returned by bulk_invoke_endpoint_async,
# matches each result back to the correct filing row, and fills in the label
# status, adoption outputs, explanation, and raw JSON hashes.
def apply_bulk_results(
    records: list[dict[str, Any]],
    pending: dict[str, dict[str, Any]],
    results: Iterable[tuple[Any, Any, Any, Any, str, str]],
    *,
    save_raw_json: bool,
    is_retry: bool = False,
) -> None:
    """Apply SageMaker bulk results to the prepared output records in place."""

    for linked_obj, _invoke_kwargs, _job_id, _inference_id, response_type, result_body in results:
        item = pending[str(linked_obj)]
        record = records[item["record_index"]]
        if is_retry:
            record["retry_attempted"] = True
            record["endpoint_attempts"] = int(record.get("endpoint_attempts", 0) or 0) + 1
        if _job_id and is_retry:
            record["retry_job_id"] = str(_job_id)
        elif _job_id:
            record["job_id"] = str(_job_id)
        if _inference_id:
            record["inference_id"] = str(_inference_id)

        # Non-success responses are kept as endpoint_error rows rather than
        # stopping the whole chunk.
        if response_type != "success":
            try:
                body = json.loads(result_body)
                error = body.get("error", result_body)
            except Exception:
                error = result_body
            if save_raw_json:
                record["raw_model_output"] = str(result_body)
            status = "endpoint_error"
            if is_retry:
                record.update(
                    parse_status="failed",
                    retry_score_status=status,
                    explanation=f"Retry endpoint error: {str(error)[:500]}",
                    score_status="retry_endpoint_error",
                )
            else:
                record.update(
                    parse_status="failed",
                    ai_adopted=pd.NA,
                    ai_adoption_level=pd.NA,
                    ai_adoption_level_code=pd.NA,
                    explanation=f"Endpoint error: {str(error)[:500]}",
                    initial_score_status=status,
                    score_status=status,
                )
            continue

        # Successful responses still need JSON parsing and validation.
        try:
            response_body = json.loads(result_body)
        except Exception:
            response_body = result_body
        raw_text = extract_text_from_response(response_body)
        result = parse_model_output_payload(
            raw_text,
            fallback_zero_reason="no_qualifying_current_firm_use",
        )
        status = result["status"]
        raw_json = result["raw_json"]
        if save_raw_json:
            record["raw_model_output"] = raw_text
            record["raw_json"] = raw_json
        record["raw_json_sha256"] = sha256_text(raw_json) if raw_json else ""

        if status == "ok":
            evidence = normalized_evidence_object(result["evidence"])
            qualifying_json = json.dumps(evidence["qualifying_ai_use_cases"], ensure_ascii=False)
            excluded_json = json.dumps(evidence["excluded_mentions"], ensure_ascii=False)
            evidence_json = json.dumps(evidence, ensure_ascii=False, sort_keys=True)
            success_updates = {
                "parse_status": "retry_success" if is_retry else "success",
                "ai_adopted": result["ai_adopted"],
                "ai_adoption_level": result["ai_adoption_level"],
                "ai_adoption_level_code": result["ai_adoption_level_code"],
                "ai_adopted_binary": result["ai_adopted_binary"],
                "ai_adopted_medium": result["ai_adopted_medium"],
                "ai_adopted_core": result["ai_adopted_core"],
                "n_qualifying_use_cases": result["n_qualifying_use_cases"],
                "n_business_areas": result["n_business_areas"],
                "has_core_ai": result["has_core_ai"],
                "main_exclusion_reason_if_zero": result["main_exclusion_reason_if_zero"],
                "explanation": result["explanation"],
                "raw_json_sha256": sha256_text(raw_json) if raw_json else "",
                "evidence_json_sha256": sha256_text(evidence_json),
                "qualifying_ai_use_cases_json": qualifying_json,
                "excluded_mentions_json": excluded_json,
            }
            if is_retry:
                success_updates["retry_score_status"] = status
                success_updates["score_status"] = (
                    "prefilter_audit_ok_after_retry" if record.get("prefilter_audit_sample") else "ok_after_retry"
                )
            else:
                initial_status = "prefilter_audit_ok" if record.get("prefilter_audit_sample") else "ok"
                success_updates["initial_score_status"] = initial_status
                success_updates["score_status"] = initial_status
            record.update(success_updates)
            continue

        failure_updates = {
            "parse_status": "failed",
            "explanation": result["explanation"],
            "raw_json_sha256": sha256_text(raw_json) if raw_json else "",
        }
        if is_retry:
            failure_updates["retry_score_status"] = status
            failure_updates["score_status"] = f"retry_{status}"
            record.update(failure_updates)
            continue

        failure_updates["initial_score_status"] = status
        failure_updates["score_status"] = status
        record.update(failure_updates)


# ---------------------------------------------------------------------------
# Chunk summary
# ---------------------------------------------------------------------------
# The JSON summary gives reviewers a quick chunk-level QA view without opening
# the full filing-level CSV.
def summarize_output(
    out_df: pd.DataFrame,
    *,
    run_id: str,
    chunk_name: str,
    source_label: str,
    endpoint: str,
    prefilter_mode: str,
    prefilter_audit_rate: float,
    prefilter_audit_limit: int,
    lookup_csv: Optional[str],
    n_filings_before_lookup: int,
    n_filings_after_lookup: int,
    output_csv: str,
) -> dict[str, Any]:
    """Build the per-chunk JSON summary."""

    adopted_series = pd.to_numeric(out_df["ai_adopted"], errors="coerce") if not out_df.empty else pd.Series(dtype=float)
    n_scored = int(adopted_series.notna().sum()) if not out_df.empty else 0
    n_adopted = int((adopted_series == 1).sum()) if not out_df.empty else 0
    n_non_adopted = int((adopted_series == 0).sum()) if not out_df.empty else 0
    return {
        "run_id": run_id,
        "chunk_name": chunk_name,
        "source_label": source_label,
        "script_version": SCRIPT_VERSION,
        "prompt_version": PROMPT_VERSION,
        "endpoint": endpoint,
        "prefilter_mode": prefilter_mode,
        "prefilter_audit_rate": prefilter_audit_rate,
        "prefilter_audit_limit": prefilter_audit_limit,
        "lookup_csv": lookup_csv,
        "n_filings_before_lookup": int(n_filings_before_lookup),
        "n_filings_after_lookup": int(n_filings_after_lookup),
        "n_filings": int(len(out_df)),
        "n_unique_cik": int(out_df["cik"].nunique()) if not out_df.empty else 0,
        "n_llm_called": int(out_df["llm_called"].sum()) if not out_df.empty else 0,
        "n_scored": n_scored,
        "n_unscored": int(len(out_df) - n_scored),
        "n_ai_adopted": n_adopted,
        "n_ai_non_adopted": n_non_adopted,
        "n_level_low": int((out_df["ai_adoption_level"] == "low").sum()) if not out_df.empty else 0,
        "n_level_medium": int((out_df["ai_adoption_level"] == "medium").sum()) if not out_df.empty else 0,
        "n_level_high": int((out_df["ai_adoption_level"] == "high").sum()) if not out_df.empty else 0,
        "n_ok": int((out_df["score_status"] == "ok").sum()) if not out_df.empty else 0,
        "n_ok_after_retry": int((out_df["score_status"] == "ok_after_retry").sum()) if not out_df.empty else 0,
        "n_prefilter_audit_ok_after_retry": int((out_df["score_status"] == "prefilter_audit_ok_after_retry").sum()) if not out_df.empty else 0,
        "n_prefilter_audit_ok": int((out_df["score_status"] == "prefilter_audit_ok").sum()) if not out_df.empty else 0,
        "n_prefilter_zero": int((out_df["score_status"] == "prefilter_zero_no_keyword").sum()) if not out_df.empty else 0,
        "n_retry_attempted": int(out_df["retry_attempted"].sum()) if not out_df.empty and "retry_attempted" in out_df.columns else 0,
        "n_missing_item1": int((~out_df["has_item1"]).sum()) if not out_df.empty else 0,
        "n_missing_item7": int((~out_df["has_item7"]).sum()) if not out_df.empty else 0,
        "status_counts": out_df["score_status"].value_counts(dropna=False).to_dict() if not out_df.empty else {},
        "adoption_rate": None if n_scored == 0 else float(n_adopted / n_scored),
        "output_csv": output_csv,
    }
