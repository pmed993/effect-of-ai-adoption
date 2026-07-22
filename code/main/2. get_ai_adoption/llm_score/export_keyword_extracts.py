#!/usr/bin/env python3
"""Export scored filing snippets for keyword-hit audit review.

This script reads one existing score CSV, reloads the original filing chunk(s),
rebuilds the exact snippet text used for scoring, and writes a compact audit CSV
with the filing accession, firm name, year, score, and snippet text.
"""

from __future__ import annotations

import argparse
import logging
import os
from pathlib import Path
from typing import Optional, Sequence

import pandas as pd

import ai_adoption_utils as u


FIRM_NAME_CANDIDATES = [
    "firm_name",
    "company_name",
    "company",
    "conm",
    "coname",
    "issuer_name",
    "name",
]


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        description=(
            "Rebuild and export the filing text snippet used for keyword-hit AI "
            "scoring rows, along with firm name, year, and score."
        )
    )
    ap.add_argument("--scores-csv", required=True, help="Existing score CSV from get_ai_score_bulk.py.")
    ap.add_argument(
        "--team",
        default="effect_of_ai",
        help="Fallback Data Workspace team if source_label is missing team=... metadata.",
    )
    ap.add_argument(
        "--include-all-rows",
        action="store_true",
        help="Include all rows in the score CSV. Default keeps only keyword-hit rows.",
    )
    ap.add_argument(
        "--out-csv",
        default=None,
        help="Output CSV path. Default appends _keyword_extracts.csv next to --scores-csv.",
    )
    ap.add_argument("--log-level", default="INFO", choices=["DEBUG", "INFO", "WARNING", "ERROR"])
    args = ap.parse_args(argv)

    if not os.path.exists(args.scores_csv):
        ap.error(f"--scores-csv does not exist: {args.scores_csv}")
    return args


def default_output_path(scores_csv: str) -> str:
    """Derive a readable default output path from the score CSV path."""

    path = Path(scores_csv)
    suffix = "_scores.csv"
    if path.name.endswith(suffix):
        return str(path.with_name(path.name[: -len(suffix)] + "_keyword_extracts.csv"))
    return str(path.with_suffix("")) + "_keyword_extracts.csv"


def parse_team_and_path_from_source_label(source_label: str, fallback_team: str) -> tuple[str, str]:
    """Parse team and chunk path from stored score metadata."""

    text = str(source_label).strip()
    if text.startswith("team=") and ":" in text:
        team_part, path = text.split(":", 1)
        team = team_part.replace("team=", "", 1).strip() or fallback_team
        return team, path.strip()
    return fallback_team, Path(text).name


def first_nonempty(series: pd.Series) -> object:
    """Return the first non-empty value in a series, or missing if none exists."""

    for value in series:
        text = u.normalize_whitespace(value)
        if text:
            return text
    return pd.NA


def int_or_default(value: object, default: int) -> int:
    """Parse an integer-like value, falling back to a default when missing."""

    parsed = pd.to_numeric(pd.Series([value]), errors="coerce").iloc[0]
    return default if pd.isna(parsed) else int(parsed)


def extract_firm_names(raw: pd.DataFrame) -> pd.DataFrame:
    """Build a one-row-per-accession map of firm names when available."""

    if "accession_number" not in raw.columns:
        return pd.DataFrame(columns=["accession_number", "firm_name"])

    work = raw.copy()
    work["accession_number"] = work["accession_number"].astype(str).str.strip()
    name_col = next((col for col in FIRM_NAME_CANDIDATES if col in work.columns), None)
    if name_col is None:
        logging.warning("No firm-name column found in raw chunk. Tried: %s", ", ".join(FIRM_NAME_CANDIDATES))
        return work[["accession_number"]].drop_duplicates().assign(firm_name=pd.NA)

    firm_names = (
        work.groupby("accession_number", as_index=False)
        .agg(firm_name=(name_col, first_nonempty))
        .reset_index(drop=True)
    )
    logging.info("Using raw column %s as firm name", name_col)
    return firm_names


def rebuild_group_extracts(group: pd.DataFrame, fallback_team: str) -> pd.DataFrame:
    """Rebuild snippet text for one source chunk represented in the score CSV."""

    source_label = str(group["source_label"].iloc[0]).strip()
    team, chunk_path = parse_team_and_path_from_source_label(source_label, fallback_team)
    logging.info("Reading source chunk for audit export: team=%s path=%s", team, chunk_path)

    raw = u.read_rds_from_team_s3(chunk_path, team=team)
    include_amended = group["form_type"].astype(str).str.upper().eq("10-K/A").any() if "form_type" in group.columns else False
    wide = u.long_to_wide(raw, include_amended=include_amended)
    wide["accession_number"] = wide["accession_number"].astype(str).str.strip()

    firm_names = extract_firm_names(raw)
    filing_text = wide.merge(firm_names, on="accession_number", how="left")

    merged = group.merge(
        filing_text[["accession_number", "firm_name", "combined_text"]],
        on="accession_number",
        how="left",
    )

    if merged["combined_text"].isna().any():
        missing = int(merged["combined_text"].isna().sum())
        logging.warning("%d rows could not be matched back to filing text in %s", missing, chunk_path)

    merged["snippet_text"] = merged.apply(
        lambda row: u.extract_relevant_snippets(
            u.normalize_whitespace(row.get("combined_text", "")),
            int_or_default(row.get("max_prompt_chars"), u.DEFAULT_MAX_PROMPT_CHARS),
            int_or_default(row.get("sentence_window"), u.DEFAULT_SENTENCE_WINDOW),
        ),
        axis=1,
    )
    merged["snippet_sha256_rebuilt"] = merged["snippet_text"].apply(u.sha256_text)
    merged["snippet_sha256_match"] = merged["snippet_sha256_rebuilt"].eq(merged.get("snippet_sha256"))
    merged["snippet_chars_rebuilt"] = merged["snippet_text"].astype(str).str.len()

    return merged


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s | %(levelname)s | %(message)s",
    )

    scores = pd.read_csv(args.scores_csv)
    if scores.empty:
        raise ValueError(f"Score CSV is empty: {args.scores_csv}")

    required = {"accession_number", "source_label", "ai_score", "year", "keyword_hits"}
    missing = required - set(scores.columns)
    if missing:
        raise ValueError(f"Score CSV is missing required columns: {sorted(missing)}")

    work = scores.copy()
    work["accession_number"] = work["accession_number"].astype(str).str.strip()

    if not args.include_all_rows:
        work = work[pd.to_numeric(work["keyword_hits"], errors="coerce").fillna(0).gt(0)].copy()
        logging.info("Keeping %d keyword-hit rows from %s", len(work), args.scores_csv)
    else:
        logging.info("Keeping all %d rows from %s", len(work), args.scores_csv)

    if work.empty:
        raise ValueError("No rows remain after filtering.")

    outputs = []
    for source_label, group in work.groupby("source_label", sort=False, dropna=False):
        if pd.isna(source_label) or not str(source_label).strip():
            raise ValueError("source_label is missing for at least one row; cannot locate original chunk.")
        outputs.append(rebuild_group_extracts(group.copy(), fallback_team=args.team))

    result = pd.concat(outputs, ignore_index=True)
    out_csv = args.out_csv or default_output_path(args.scores_csv)
    os.makedirs(os.path.dirname(os.path.abspath(out_csv)), exist_ok=True)

    keep_cols = [
        "run_id",
        "source_label",
        "chunk_id",
        "accession_number",
        "firm_name",
        "cik",
        "year",
        "form_type",
        "keyword_hits",
        "ranking_keyword_hits",
        "prefilter_decision",
        "llm_called",
        "ai_score",
        "ai_score_label",
        "score_status",
        "max_prompt_chars",
        "sentence_window",
        "snippet_chars",
        "snippet_chars_rebuilt",
        "snippet_sha256",
        "snippet_sha256_rebuilt",
        "snippet_sha256_match",
        "snippet_text",
    ]
    existing = [col for col in keep_cols if col in result.columns]
    extra = [col for col in result.columns if col not in existing and col not in {"combined_text"}]
    result = result[existing + extra].sort_values(["year", "firm_name", "accession_number"], na_position="last")
    result.to_csv(out_csv, index=False)

    logging.info("Wrote %s (%d rows)", out_csv, len(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
