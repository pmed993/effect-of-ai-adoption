#!/usr/bin/env python3
"""Merge chunk-level LLM label outputs into filing-level and firm-year datasets.

This script is designed for the bulk AI-adoption labeling workflow.
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
      --llama-dir output/final_llama \
      --out-dir output/final_merged
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
from typing import Iterable

import pandas as pd


LLAMA_PATTERN = "*_llama_scores.csv"
MISTRAL_PATTERN = "*_mistral_scores.csv"

IDENTITY_COLS = ["accession_number", "cik", "year"]
FILING_BASE_COLS = [
    "source_label",
    "chunk_id",
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

ADOPTION_LEVEL_CODES = {
    "none": 0,
    "low": 1,
    "medium": 2,
    "high": 3,
}


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Merge AI-adoption chunk outputs into final datasets.")
    ap.add_argument("--llama-dir", required=True, help="Root folder containing Llama chunk outputs.")
    ap.add_argument("--mistral-dir", default=None, help="Optional root folder containing Mistral chunk outputs.")
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
        help="How to handle duplicate accession_number rows before building the filing master. max_llama prefers adopted rows and stronger adoption labels.",
    )
    ap.add_argument(
        "--firm-year-rule",
        choices=["error", "first", "last", "max_llama"],
        default="error",
        help="How to handle duplicate cik-year rows when building the firm-year panel. max_llama prefers adopted rows and stronger adoption labels.",
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
    return ap.parse_args()


def find_score_files(root: str, pattern: str) -> list[Path]:
    files = sorted(Path(root).rglob(pattern))
    if not files:
        raise FileNotFoundError(f"No files found under {root!r} matching {pattern!r}")
    return files


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


def model_priority_columns(df: pd.DataFrame, prefix: str) -> tuple[pd.Series, pd.Series]:
    """Return adoption and intensity priority series for duplicate resolution."""

    adopted_col = f"{prefix}_ai_adopted"
    level_code_col = f"{prefix}_ai_adoption_level_code"
    level_col = f"{prefix}_ai_adoption_level"
    legacy_score_col = f"{prefix}_score"

    if adopted_col in df.columns:
        adopted = pd.to_numeric(df[adopted_col], errors="coerce").fillna(-1)
    elif legacy_score_col in df.columns:
        legacy_score = pd.to_numeric(df[legacy_score_col], errors="coerce")
        adopted = legacy_score.gt(0).astype(float).fillna(-1)
    else:
        adopted = pd.Series(-1, index=df.index, dtype=float)

    if level_code_col in df.columns:
        level_code = pd.to_numeric(df[level_code_col], errors="coerce").fillna(-1)
    elif level_col in df.columns:
        level_code = df[level_col].astype("string").str.lower().map(ADOPTION_LEVEL_CODES).fillna(-1)
    elif legacy_score_col in df.columns:
        legacy_score = pd.to_numeric(df[legacy_score_col], errors="coerce")
        level_code = legacy_score.fillna(float("-inf"))
    else:
        level_code = pd.Series(-1, index=df.index, dtype=float)

    return adopted, level_code


def rename_llama_columns(df: pd.DataFrame) -> pd.DataFrame:
    out = ensure_identity_types(df)
    rename_map = {
        "run_id": "llama_run_id",
        "script_version": "llama_script_version",
        "prompt_version": "llama_prompt_version",
        "llm_called": "llama_llm_called",
        "endpoint_attempts": "llama_endpoint_attempts",
        "initial_score_status": "llama_initial_score_status",
        "retry_attempted": "llama_retry_attempted",
        "retry_score_status": "llama_retry_score_status",
        "ai_adopted": "llama_ai_adopted",
        # Legacy compatibility for older chunk files.
        "explicit_operational_ai": "llama_explicit_operational_ai",
        "ai_adoption_level": "llama_ai_adoption_level",
        "ai_adoption_level_code": "llama_ai_adoption_level_code",
        "explanation": "llama_explanation",
        "score_status": "llama_score_status",
        "endpoint": "llama_endpoint",
        "job_id": "llama_job_id",
        "retry_job_id": "llama_retry_job_id",
        "raw_json_sha256": "llama_raw_json_sha256",
        "source_csv": "llama_source_csv",
    }
    out = out.rename(columns=rename_map)
    preferred = (
        IDENTITY_COLS
        + FILING_BASE_COLS
        + [
            "llama_run_id",
            "llama_script_version",
            "llama_prompt_version",
            "llama_llm_called",
            "llama_endpoint_attempts",
            "llama_initial_score_status",
            "llama_retry_attempted",
            "llama_retry_score_status",
            "llama_ai_adopted",
            "llama_ai_adoption_level",
            "llama_ai_adoption_level_code",
            "llama_explanation",
            "llama_score_status",
            "llama_endpoint",
            "llama_job_id",
            "llama_retry_job_id",
            "llama_raw_json_sha256",
            "llama_source_csv",
        ]
    )
    existing = [col for col in preferred if col in out.columns]
    extra = [col for col in out.columns if col not in existing]
    return out[existing + extra]


def rename_mistral_columns(df: pd.DataFrame) -> pd.DataFrame:
    out = ensure_identity_types(df)
    rename_map = {
        "run_id": "mistral_run_id",
        "script_version": "mistral_script_version",
        "prompt_version": "mistral_prompt_version",
        "llm_called": "mistral_llm_called",
        "endpoint_attempts": "mistral_endpoint_attempts",
        "initial_score_status": "mistral_initial_score_status",
        "retry_attempted": "mistral_retry_attempted",
        "retry_score_status": "mistral_retry_score_status",
        "ai_adopted": "mistral_ai_adopted",
        # Legacy compatibility for older chunk files.
        "explicit_operational_ai": "mistral_explicit_operational_ai",
        "ai_adoption_level": "mistral_ai_adoption_level",
        "ai_adoption_level_code": "mistral_ai_adoption_level_code",
        "explanation": "mistral_explanation",
        "score_status": "mistral_score_status",
        "endpoint": "mistral_endpoint",
        "job_id": "mistral_job_id",
        "retry_job_id": "mistral_retry_job_id",
        "raw_json_sha256": "mistral_raw_json_sha256",
        "source_csv": "mistral_source_csv",
    }
    out = out.rename(columns=rename_map)
    keep = (
        IDENTITY_COLS
        + FILING_BASE_COLS
        + [
            "mistral_run_id",
            "mistral_script_version",
            "mistral_prompt_version",
            "mistral_llm_called",
            "mistral_endpoint_attempts",
            "mistral_initial_score_status",
            "mistral_retry_attempted",
            "mistral_retry_score_status",
            "mistral_ai_adopted",
            "mistral_ai_adoption_level",
            "mistral_ai_adoption_level_code",
            "mistral_explanation",
            "mistral_score_status",
            "mistral_endpoint",
            "mistral_job_id",
            "mistral_retry_job_id",
            "mistral_raw_json_sha256",
            "mistral_source_csv",
        ]
    )
    existing = [col for col in keep if col in out.columns]
    extra = [col for col in out.columns if col not in existing]
    return out[existing + extra]


def load_model_outputs(root: str, pattern: str, model: str) -> pd.DataFrame:
    files = find_score_files(root, pattern)
    print(f"Found {len(files)} {model} output files under {root}")
    df = read_concat(files)
    if model == "llama":
        return rename_llama_columns(df)
    if model == "mistral":
        return rename_mistral_columns(df)
    raise ValueError(f"Unsupported model: {model}")


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
    adopted_rank, level_rank = model_priority_columns(out, label.lower())

    out = out.assign(
        _section_count=section_count,
        _combined_chars_num=combined_chars,
        _snippet_chars_num=snippet_chars,
        _llm_called_num=llm_called,
        _adopted_rank=adopted_rank,
        _level_rank=level_rank,
    )

    if rule == "best_context":
        out = out.sort_values(
            [
                "accession_number",
                "_adopted_rank",
                "_level_rank",
                "_section_count",
                "_combined_chars_num",
                "_snippet_chars_num",
                "_llm_called_num",
            ],
            ascending=[True, False, False, False, False, False, False],
        )
    elif rule == "max_llama":
        out = out.sort_values(
            ["accession_number", "_adopted_rank", "_level_rank", "_section_count", "_combined_chars_num", "_snippet_chars_num"],
            ascending=[True, False, False, False, False, False],
        )
    else:
        raise ValueError(f"Unsupported filing duplicate rule: {rule}")

    out = out.drop_duplicates(subset=["accession_number"], keep="first").reset_index(drop=True)
    out = out.drop(columns=["_section_count", "_combined_chars_num", "_snippet_chars_num", "_llm_called_num", "_adopted_rank", "_level_rank"])
    return out


def merge_models(llama_df: pd.DataFrame, mistral_df: pd.DataFrame | None, filing_duplicate_rule: str, out_dir: str) -> pd.DataFrame:
    llama_df = deduplicate_accessions(llama_df, "Llama", filing_duplicate_rule, out_dir)
    if mistral_df is None:
        return llama_df

    mistral_df = deduplicate_accessions(mistral_df, "Mistral", filing_duplicate_rule, out_dir)
    merged = llama_df.merge(
        mistral_df,
        on=IDENTITY_COLS,
        how="outer",
        validate="one_to_one",
    )
    return merged


def build_firm_year_panel(filing_df: pd.DataFrame, rule: str, out_dir: str) -> pd.DataFrame:
    out = filing_df.copy()
    out = ensure_identity_types(out)

    key = ["cik", "year"]
    dupes = out[out.duplicated(subset=key, keep=False)].sort_values(key + ["accession_number"])
    if dupes.empty:
        return out

    dupes_path = write_duplicate_report(dupes, out_dir, "firm_year_duplicates.csv")
    print(f"Found duplicate cik-year rows. Wrote report to {dupes_path}")

    if rule == "error":
        raise ValueError(
            "Duplicate cik-year rows found when building the firm-year panel. "
            f"Review {dupes_path} and rerun with --firm-year-rule last or --firm-year-rule max_llama."
        )

    out = out.sort_values(["cik", "year", "accession_number"])
    if rule == "first":
        return out.groupby(key, as_index=False).head(1).reset_index(drop=True)

    if rule == "last":
        return out.groupby(key, as_index=False).tail(1).reset_index(drop=True)

    if rule == "max_llama":
        adopted_rank, level_rank = model_priority_columns(out, "llama")
        out = out.assign(_llama_adopted_rank=adopted_rank, _llama_level_rank=level_rank)
        out = out.sort_values(["cik", "year", "_llama_adopted_rank", "_llama_level_rank", "accession_number"])
        out = out.groupby(key, as_index=False).tail(1).drop(columns=["_llama_adopted_rank", "_llama_level_rank"]).reset_index(drop=True)
        return out

    raise ValueError(f"Unsupported firm-year rule: {rule}")


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

    llama_df = load_model_outputs(args.llama_dir, LLAMA_PATTERN, "llama")
    llama_df = filter_to_lookup(llama_df, lookup, "Llama")
    mistral_df = None
    if args.mistral_dir:
        mistral_df = load_model_outputs(args.mistral_dir, MISTRAL_PATTERN, "mistral")
        mistral_df = filter_to_lookup(mistral_df, lookup, "Mistral")

    filing_df = merge_models(llama_df, mistral_df, args.filing_duplicate_rule, args.out_dir)
    filing_df = filing_df.sort_values(["year", "cik", "accession_number"]).reset_index(drop=True)

    all_chunks_out = os.path.join(args.out_dir, "ai_adoption_all_chunk_outputs.csv")
    filing_df.to_csv(all_chunks_out, index=False)
    print(f"Wrote all-chunk merged output: {all_chunks_out} ({len(filing_df)} rows)")

    filing_out = os.path.join(args.out_dir, "ai_adoption_filing_master.csv")
    filing_df.to_csv(filing_out, index=False)
    print(f"Wrote filing-level master: {filing_out} ({len(filing_df)} rows)")

    panel_df = build_firm_year_panel(filing_df, args.firm_year_rule, args.out_dir)
    panel_df = panel_df.sort_values(["year", "cik", "accession_number"]).reset_index(drop=True)
    panel_out = os.path.join(args.out_dir, "ai_adoption_firm_year_panel.csv")
    panel_df.to_csv(panel_out, index=False)
    print(f"Wrote firm-year panel: {panel_out} ({len(panel_df)} rows)")

    if args.compustat_csv:
        comp_out = os.path.join(args.out_dir, "compustat_ai_adoption_merged.csv")
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
