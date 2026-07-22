#!/usr/bin/env python3
"""Merge chunk-level LLM extraction outputs into filing-level and firm-year datasets.

This script is designed for the bulk LLM extraction scoring workflow.
It:
1. collects all chunk CSVs under a model output folder,
2. builds a filing-level master dataset,
3. optionally merges in a second model's labels,
4. optionally re-filters the merged outputs to a research cik-year lookup,
5. writes one all-chunk merged output file,
6. builds a firm-year panel for Compustat joins, and
7. optionally merges that panel into a Compustat CSV.

Typical usage:
    python3 merge_outputs.py \
      --primary-dir output/final_claude \
      --primary-label claude \
      --out-dir output/final_merged
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
from typing import Iterable

import pandas as pd


IDENTITY_COLS = ["accession_number", "cik", "year"]
FILING_BASE_COLS = [
    "source_label",
    "chunk_id",
    "filing_accession",
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
    "snippet_sha256",
]

AI_SCORE_LABELS = {
    1: "no_current_adoption",
    2: "limited_or_targeted_adoption",
    3: "production_or_strategic_adoption",
}

MODEL_METADATA_FIELDS = [
    "run_id",
    "script_version",
    "prompt_version",
    "research_profile",
    "llm_model",
    "llm_checkpoint",
    "temperature",
    "max_new_tokens",
    "max_prompt_chars",
    "sentence_window",
    "llm_called",
    "endpoint_attempts",
    "parse_status",
    "initial_score_status",
    "retry_attempted",
    "retry_score_status",
    "ai_score",
    "ai_score_label",
    "score_explanation",
    "score_status",
    "endpoint",
    "job_id",
    "retry_job_id",
    "raw_json_sha256",
    "source_csv",
]


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Merge AI-adoption chunk outputs into final datasets.")
    ap.add_argument("--primary-dir", default=None, help="Root folder containing the main model's chunk outputs.")
    ap.add_argument("--primary-label", default="claude", help="Short label used in score filenames and merged columns, e.g. claude.")
    ap.add_argument("--secondary-dir", default=None, help="Optional root folder containing a second model's chunk outputs.")
    ap.add_argument("--secondary-label", default="secondary", help="Short label used in filenames and merged columns for the optional second model.")
    ap.add_argument("--llama-dir", dest="primary_dir", default=None, help=argparse.SUPPRESS)
    ap.add_argument("--mistral-dir", dest="secondary_dir", default=None, help=argparse.SUPPRESS)
    ap.add_argument("--out-dir", required=True, help="Folder for merged outputs.")
    ap.add_argument(
        "--lookup-csv",
        default=None,
        help="Optional cik-year lookup CSV. If provided, merged outputs are filtered to lookup keys after concatenation.",
    )
    ap.add_argument(
        "--filing-duplicate-rule",
        choices=["error", "best_context", "max_llama"],
        default="error",
        help="How to handle duplicate accession_number rows before building the filing master. max_llama prefers higher AI scores and richer filing context.",
    )
    ap.add_argument(
        "--firm-year-rule",
        choices=["error", "first", "last", "max_llama"],
        default="error",
        help="How to handle duplicate cik-year rows when building the firm-year panel. max_llama prefers higher AI scores.",
    )
    ap.add_argument(
        "--compustat-csv",
        default=None,
        help="Optional Compustat CSV to merge with the firm-year panel.",
    )
    ap.add_argument("--compustat-cik-col", default="cik", help="Compustat CIK column name.")
    ap.add_argument("--compustat-year-col", default="year", help="Compustat fiscal year column name.")
    ap.add_argument(
        "--compustat-merge-how",
        default="left",
        choices=["left", "inner", "right", "outer"],
        help="Pandas merge how= for the optional Compustat merge.",
    )
    args = ap.parse_args()
    if not args.primary_dir:
        ap.error("--primary-dir is required")
    return args


def find_score_files(root: str, pattern: str) -> list[Path]:
    files = sorted(Path(root).rglob(pattern))
    if not files:
        raise FileNotFoundError(f"No files found under {root!r} matching {pattern!r}")
    return files


def pattern_for_label(label: str) -> str:
    return f"*_{label}_scores.csv"


def read_concat(files: Iterable[Path]) -> pd.DataFrame:
    frames = []
    for path in files:
        df = pd.read_csv(path)
        if df.empty:
            continue
        df["source_csv"] = str(path)
        frames.append(df)
    if not frames:
        return pd.DataFrame()
    return pd.concat(frames, ignore_index=True)


def ensure_identity_types(df: pd.DataFrame) -> pd.DataFrame:
    out = df.copy()
    if "accession_number" in out.columns:
        out["accession_number"] = out["accession_number"].astype("string")
    if "cik" in out.columns:
        out["cik"] = pd.to_numeric(out["cik"], errors="coerce").astype("Int64")
    if "year" in out.columns:
        out["year"] = pd.to_numeric(out["year"], errors="coerce").astype("Int64")
    return out


def normalize_cik(value: object) -> str:
    if value is None or pd.isna(value):
        return ""
    text = str(value).strip()
    if text.endswith(".0"):
        text = text[:-2]
    text = "".join(ch for ch in text if ch.isdigit())
    return text.lstrip("0") or ("0" if text else "")


def load_lookup(path: str | None) -> pd.DataFrame | None:
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

    return lookup[["cik_match", "year_match"]]


def filter_to_lookup(df: pd.DataFrame, lookup: pd.DataFrame | None, label: str) -> pd.DataFrame:
    if lookup is None or df.empty:
        return df

    out = ensure_identity_types(df)
    before = len(out)

    out["cik_match"] = out["cik"].apply(normalize_cik)
    out["year_match"] = pd.to_numeric(out["year"], errors="coerce").astype("Int64")
    out = out.merge(lookup, on=["cik_match", "year_match"], how="inner")
    out = out.drop(columns=["cik_match", "year_match"])
    out = out.reset_index(drop=True)

    print(f"Lookup filter kept {len(out)}/{before} {label} rows")
    return out


def model_priority_columns(df: pd.DataFrame, prefix: str) -> pd.Series:
    """Return the filing score priority series used for duplicate resolution."""

    score_col = f"{prefix}_ai_score"
    label_col = f"{prefix}_ai_score_label"

    if score_col in df.columns:
        return pd.to_numeric(df[score_col], errors="coerce").fillna(-1)
    if label_col in df.columns:
        reverse_map = {label: score for score, label in AI_SCORE_LABELS.items()}
        return df[label_col].astype("string").str.lower().map(reverse_map).fillna(-1)
    return pd.Series(-1, index=df.index, dtype=float)


def rename_model_columns(df: pd.DataFrame, prefix: str) -> pd.DataFrame:
    out = ensure_identity_types(df)
    rename_map = {field: f"{prefix}_{field}" for field in MODEL_METADATA_FIELDS}
    rename_map["explicit_operational_ai"] = f"{prefix}_explicit_operational_ai"
    out = out.rename(columns=rename_map)
    preferred = (
        IDENTITY_COLS
        + FILING_BASE_COLS
        + [f"{prefix}_{field}" for field in MODEL_METADATA_FIELDS]
    )
    existing = [col for col in preferred if col in out.columns]
    extra = [col for col in out.columns if col not in existing]
    return out[existing + extra]

def load_model_outputs(root: str, pattern: str, model: str) -> pd.DataFrame:
    files = find_score_files(root, pattern)
    print(f"Found {len(files)} {model} output files under {root}")
    df = read_concat(files)
    return rename_model_columns(df, model)


def write_duplicate_report(dupes: pd.DataFrame, out_dir: str, filename: str) -> str:
    path = os.path.join(out_dir, filename)
    dupes.to_csv(path, index=False)
    return path


def deduplicate_accessions(df: pd.DataFrame, label: str, rule: str, out_dir: str) -> pd.DataFrame:
    out = ensure_identity_types(df)
    dupes = out[out.duplicated(subset=["accession_number"], keep=False)].sort_values(
        ["accession_number", "cik", "year"]
    )
    if dupes.empty:
        return out

    filename = f"{label.lower()}_accession_duplicates.csv"
    dupes_path = write_duplicate_report(dupes, out_dir, filename)
    n_dupe_accessions = dupes["accession_number"].nunique()
    print(f"Found {n_dupe_accessions} duplicate {label} accession_number values. Wrote report to {dupes_path}")

    if rule == "error":
        raise ValueError(
            f"{label} outputs contain duplicate accession_number rows ({n_dupe_accessions} duplicated accessions). "
            f"Review {dupes_path} and rerun with --filing-duplicate-rule best_context or --filing-duplicate-rule max_llama."
        )

    has_item1 = pd.Series(False, index=out.index)
    has_item7 = pd.Series(False, index=out.index)
    if "has_item1" in out.columns:
        has_item1 = out["has_item1"].fillna(False).astype(bool)
    if "has_item7" in out.columns:
        has_item7 = out["has_item7"].fillna(False).astype(bool)

    section_count = has_item1.astype(int) + has_item7.astype(int)
    combined_chars = pd.to_numeric(out.get("combined_chars"), errors="coerce").fillna(-1)
    snippet_chars = pd.to_numeric(out.get("snippet_chars"), errors="coerce").fillna(-1)
    llm_called_col = f"{label.lower()}_llm_called"
    llm_called = out.get(llm_called_col, pd.Series(False, index=out.index)).fillna(False).astype(bool).astype(int)
    score_rank = model_priority_columns(out, label.lower())

    out = out.assign(
        _section_count=section_count,
        _combined_chars_num=combined_chars,
        _snippet_chars_num=snippet_chars,
        _llm_called_num=llm_called,
        _score_rank=score_rank,
    )

    if rule == "best_context":
        out = out.sort_values(
            [
                "accession_number",
                "_score_rank",
                "_section_count",
                "_combined_chars_num",
                "_snippet_chars_num",
                "_llm_called_num",
            ],
            ascending=[True, False, False, False, False, False],
        )
    elif rule == "max_llama":
        out = out.sort_values(
            ["accession_number", "_score_rank", "_section_count", "_combined_chars_num", "_snippet_chars_num"],
            ascending=[True, False, False, False, False],
        )
    else:
        raise ValueError(f"Unsupported filing duplicate rule: {rule}")

    out = out.drop_duplicates(subset=["accession_number"], keep="first").reset_index(drop=True)
    out = out.drop(columns=["_section_count", "_combined_chars_num", "_snippet_chars_num", "_llm_called_num", "_score_rank"])
    return out


def merge_models(primary_df: pd.DataFrame, secondary_df: pd.DataFrame | None, filing_duplicate_rule: str, out_dir: str) -> pd.DataFrame:
    primary_df = deduplicate_accessions(primary_df, "Primary", filing_duplicate_rule, out_dir)
    if secondary_df is None:
        return primary_df

    secondary_df = deduplicate_accessions(secondary_df, "Secondary", filing_duplicate_rule, out_dir)
    merge_keys = [col for col in IDENTITY_COLS + FILING_BASE_COLS if col in primary_df.columns and col in secondary_df.columns]
    merged = primary_df.merge(
        secondary_df,
        on=merge_keys,
        how="outer",
        validate="one_to_one",
    )
    return merged


def first_non_null(series: pd.Series) -> object:
    for value in series:
        if value is None or pd.isna(value):
            continue
        if isinstance(value, str) and not value.strip():
            continue
        return value
    return pd.NA


def aggregate_parse_status(series: pd.Series) -> str:
    statuses = {
        str(value).strip()
        for value in series
        if value is not None and not pd.isna(value) and str(value).strip()
    }
    if "retry_success" in statuses:
        return "retry_success"
    if "success" in statuses or "not_called" in statuses:
        return "success"
    return "failed"


def combine_evidence_summaries(series: pd.Series, limit: int = 3) -> str:
    summaries: list[str] = []
    for value in series:
        text = str(value).strip() if value is not None and not pd.isna(value) else ""
        if not text or text in summaries:
            continue
        summaries.append(text)
        if len(summaries) >= limit:
            break
    return " | ".join(summaries)


def aggregate_model_firm_year(
    filing_df: pd.DataFrame,
    prefix: str,
    *,
    generic_output: bool,
) -> pd.DataFrame:
    """Aggregate filing-level 1-3 AI scores into one firm-year score."""

    score_col = f"{prefix}_ai_score"
    label_col = f"{prefix}_ai_score_label"
    explanation_col = f"{prefix}_score_explanation"
    parse_status_col = f"{prefix}_parse_status"
    if score_col not in filing_df.columns and parse_status_col not in filing_df.columns:
        return pd.DataFrame(columns=["cik", "year"])

    out = ensure_identity_types(filing_df)
    rows: list[dict[str, object]] = []

    for (cik, year), group in out.groupby(["cik", "year"], dropna=False, sort=True):
        if score_col in group.columns:
            score_series = pd.to_numeric(group[score_col], errors="coerce")
        else:
            score_series = pd.Series(pd.NA, index=group.index, dtype="Float64")
        accessions = sorted(
            {
                str(value).strip()
                for value in group.get("accession_number", pd.Series(dtype="string"))
                if value is not None and not pd.isna(value) and str(value).strip()
            }
        )
        parse_status_series = group.get(parse_status_col, pd.Series(dtype="string"))
        n_chunks = int(len(group))
        n_chunks_scored = int(parse_status_series.isin(["success", "retry_success"]).sum())
        n_chunks_failed = int((parse_status_series == "failed").sum())
        valid_scores = score_series.dropna()
        ai_score = int(valid_scores.max()) if not valid_scores.empty else pd.NA
        ai_score_label = AI_SCORE_LABELS.get(int(ai_score), pd.NA) if pd.notna(ai_score) else pd.NA
        max_score_explanation = ""
        if pd.notna(ai_score) and explanation_col in group.columns:
            explanation_series = group.loc[score_series == ai_score, explanation_col]
            max_score_explanation = str(first_non_null(explanation_series) or "").strip()
        row = {
            "cik": cik,
            "year": year,
            "filing_accession": ";".join(accessions),
            "run_id": first_non_null(group.get(f"{prefix}_run_id", pd.Series(dtype="object"))),
            "script_version": first_non_null(group.get(f"{prefix}_script_version", pd.Series(dtype="object"))),
            "prompt_version": first_non_null(group.get(f"{prefix}_prompt_version", pd.Series(dtype="object"))),
            "research_profile": first_non_null(group.get(f"{prefix}_research_profile", pd.Series(dtype="object"))),
            "llm_model": first_non_null(group.get(f"{prefix}_llm_model", pd.Series(dtype="object"))),
            "llm_checkpoint": first_non_null(group.get(f"{prefix}_llm_checkpoint", pd.Series(dtype="object"))),
            "temperature": first_non_null(group.get(f"{prefix}_temperature", pd.Series(dtype="object"))),
            "max_new_tokens": first_non_null(group.get(f"{prefix}_max_new_tokens", pd.Series(dtype="object"))),
            "max_prompt_chars": first_non_null(group.get(f"{prefix}_max_prompt_chars", pd.Series(dtype="object"))),
            "sentence_window": first_non_null(group.get(f"{prefix}_sentence_window", pd.Series(dtype="object"))),
            "n_chunks": n_chunks,
            "n_chunks_scored": n_chunks_scored,
            "n_chunks_failed": n_chunks_failed,
            "parse_status": aggregate_parse_status(parse_status_series),
            "ai_score": ai_score,
            "ai_score_label": ai_score_label,
            "score_explanation": max_score_explanation,
        }
        if generic_output:
            rows.append(row)
        else:
            prefixed = {"cik": cik, "year": year}
            prefixed.update({f"{prefix}_{key}": value for key, value in row.items() if key not in {"cik", "year"}})
            rows.append(prefixed)

    return pd.DataFrame(rows)


def build_firm_year_panel(filing_df: pd.DataFrame, rule: str, out_dir: str) -> pd.DataFrame:
    """
    Aggregate all filing-level AI scores within each firm-year.

    The `rule` argument is retained for CLI compatibility, but firm-years are no
    longer reduced by picking one row. A firm-year receives the maximum filing
    score observed within the same cik-year.
    """

    del rule, out_dir
    prefixes = sorted(
        {
            col[: -len("_ai_score")]
            for col in filing_df.columns
            if col.endswith("_ai_score")
        }
    )
    if not prefixes:
        return ensure_identity_types(filing_df)[["cik", "year"]].drop_duplicates().reset_index(drop=True)

    primary_prefix = prefixes[0]
    panel = aggregate_model_firm_year(filing_df, primary_prefix, generic_output=True)
    for prefix in prefixes:
        if prefix == primary_prefix:
            continue
        extra = aggregate_model_firm_year(filing_df, prefix, generic_output=False)
        panel = panel.merge(extra, on=["cik", "year"], how="outer", validate="one_to_one")
    return ensure_identity_types(panel).reset_index(drop=True)


def merge_with_compustat(
    panel_df: pd.DataFrame,
    compustat_csv: str,
    cik_col: str,
    year_col: str,
    how: str,
) -> pd.DataFrame:
    comp = pd.read_csv(compustat_csv)
    if cik_col not in comp.columns:
        raise KeyError(f"Compustat CSV missing CIK column {cik_col!r}")
    if year_col not in comp.columns:
        raise KeyError(f"Compustat CSV missing year column {year_col!r}")

    comp = comp.copy()
    comp[cik_col] = pd.to_numeric(comp[cik_col], errors="coerce").astype("Int64")
    comp[year_col] = pd.to_numeric(comp[year_col], errors="coerce").astype("Int64")

    panel = panel_df.copy()
    panel["cik"] = pd.to_numeric(panel["cik"], errors="coerce").astype("Int64")
    panel["year"] = pd.to_numeric(panel["year"], errors="coerce").astype("Int64")

    merged = comp.merge(panel, left_on=[cik_col, year_col], right_on=["cik", "year"], how=how)
    return merged


def main() -> int:
    args = parse_args()
    os.makedirs(args.out_dir, exist_ok=True)
    lookup = load_lookup(args.lookup_csv)

    primary_df = load_model_outputs(args.primary_dir, pattern_for_label(args.primary_label), args.primary_label)
    primary_df = filter_to_lookup(primary_df, lookup, args.primary_label)
    secondary_df = None
    if args.secondary_dir:
        secondary_df = load_model_outputs(args.secondary_dir, pattern_for_label(args.secondary_label), args.secondary_label)
        secondary_df = filter_to_lookup(secondary_df, lookup, args.secondary_label)

    filing_df = merge_models(primary_df, secondary_df, args.filing_duplicate_rule, args.out_dir)
    filing_df = filing_df.sort_values(["year", "cik", "accession_number"]).reset_index(drop=True)

    all_chunks_out = os.path.join(args.out_dir, "llm_extraction_all_chunk_outputs.csv")
    filing_df.to_csv(all_chunks_out, index=False)
    print(f"Wrote all-chunk merged output: {all_chunks_out} ({len(filing_df)} rows)")

    filing_out = os.path.join(args.out_dir, "llm_extraction_filing_master.csv")
    filing_df.to_csv(filing_out, index=False)
    print(f"Wrote filing-level master: {filing_out} ({len(filing_df)} rows)")

    panel_df = build_firm_year_panel(filing_df, args.firm_year_rule, args.out_dir)
    panel_sort_cols = [col for col in ["year", "cik", "filing_accession"] if col in panel_df.columns]
    panel_df = panel_df.sort_values(panel_sort_cols).reset_index(drop=True) if panel_sort_cols else panel_df.reset_index(drop=True)
    panel_out = os.path.join(args.out_dir, "llm_extraction_firm_year_panel.csv")
    panel_df.to_csv(panel_out, index=False)
    print(f"Wrote firm-year panel: {panel_out} ({len(panel_df)} rows)")

    if args.compustat_csv:
        comp_out = os.path.join(args.out_dir, "compustat_llm_extraction_merged.csv")
        merged_df = merge_with_compustat(
            panel_df,
            args.compustat_csv,
            cik_col=args.compustat_cik_col,
            year_col=args.compustat_year_col,
            how=args.compustat_merge_how,
        )
        merged_df.to_csv(comp_out, index=False)
        print(f"Wrote Compustat merge: {comp_out} ({len(merged_df)} rows)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
