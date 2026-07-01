#!/usr/bin/env python3
"""Bulk LLM classification for filing-level AI adoption.

The process estimates firm-level AI adoption from SEC Form 10-K disclosures.
It reads EDGAR extract chunks from the Data Workspace team S3 folder, 
converts Item 1 and Item 7 text into one row per filing,
optionally filters to a research lookup of `cik` and `year`, 
and sends relevant filing text sections to a Data Workspace SageMaker Llama endpoint.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from pathlib import Path
from typing import Optional, Sequence

import pandas as pd

import ai_adoption_utils as u


# ---------------------------------------------------------------------------
# Command-line arguments
# ---------------------------------------------------------------------------
# This function defines all options a user can pass when running the script.
# It also checks that numeric options are sensible before the process starts.
def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        description="Classify selected EDGAR chunk files for AI adoption using Data Workspace bulk async SageMaker invocation."
    )

    # Data Workspace S3 location. In normal use, the team folder is enough.
    ap.add_argument("--team", default="effect_of_ai", help="Data Workspace team folder name, e.g. effect_of_ai.")
    ap.add_argument("--chunk-prefix", default="", help="Optional path under the team folder containing chunk files.")
    ap.add_argument("--s3-bucket", default=u.DEFAULT_BUCKET, help="S3 bucket. Usually leave as the Data Workspace default.")

    # Mutually exclusive chunk selection options. The user should choose one.
    selection = ap.add_mutually_exclusive_group(required=False)
    selection.add_argument("--chunk-names", nargs="+", help="Chunk basenames, e.g. extract_df_chunk_00001.rds")
    selection.add_argument("--chunk-ids", nargs="+", type=int, help="Chunk ids, e.g. 1 2 18 37")
    selection.add_argument("--chunk-range", nargs=2, type=int, metavar=("START", "END"), help="Inclusive chunk id range.")
    selection.add_argument("--all-chunks", action="store_true", help="Process every chunk under the team prefix. Use with care.")
    selection.add_argument(
        "--repair-failed-from-csv",
        nargs="+",
        help="Existing score CSV file(s). Only rows with final parse_status=failed will be resubmitted and repaired in place.",
    )

    # QA and sample-filtering options.
    ap.add_argument("--list-only", action="store_true", help="List available chunks and exit.")
    ap.add_argument("--max-chunks", type=int, default=0, help="Cap selected chunks after selection.")
    ap.add_argument("--max-filings-per-chunk", type=int, default=0, help="QA option: label only first N matched filings per chunk.")
    ap.add_argument("--lookup-csv", default=None, help="CSV with cik and year columns. Only matching filings are labeled.")
    ap.add_argument("--include-amended", action="store_true", help="Include 10-K/A rows. Default keeps only 10-K.")

    # Prefilter options decide when no-keyword filings should skip the LLM.
    ap.add_argument(
        "--prefilter-mode",
        choices=["off", "hard_zero", "audit"],
        default="hard_zero",
        help="hard_zero skips no-keyword filings; audit samples no-keyword filings; off calls LLM on all non-empty filings.",
    )
    ap.add_argument("--prefilter-audit-rate", type=float, default=0.02)
    ap.add_argument("--prefilter-audit-limit", type=int, default=0, help="Per-chunk audit call cap; 0 means no cap.")
    ap.add_argument("--audit-seed", default="ai-adoption-prefilter-audit-v1")

    # LLM and bulk invocation settings.
    ap.add_argument("--model-label", choices=["llama", "mistral"], default="llama", help="Short label used for endpoint defaulting and output naming.")
    ap.add_argument("--endpoint", default=None, help="Override SageMaker endpoint. If omitted, uses the default for --model-label.")
    ap.add_argument("--llm-checkpoint", default=None, help="Exact model checkpoint name to store in outputs. Defaults to the configured checkpoint for --model-label.")
    ap.add_argument("--max-prompt-chars", type=int, default=1500)
    ap.add_argument("--sentence-window", type=int, default=1)
    ap.add_argument("--temperature", type=float, default=u.TEMPERATURE)
    ap.add_argument("--max-new-tokens", type=int, default=u.DEFAULT_MAX_NEW_TOKENS)
    ap.add_argument("--max-concurrent-invocations", type=int, default=25)
    ap.add_argument("--max-workers", type=int, default=9)
    ap.add_argument("--no-retry-pass", action="store_true", help="Disable the automatic second-pass retry for parser failures.")
    ap.add_argument(
        "--repair-failed-after-chunk",
        action="store_true",
        help="After each chunk finishes, run one extra failed-row repair pass against that chunk's output CSV if any rows still have parse_status=failed.",
    )
    ap.add_argument(
        "--repair-failed-after-run",
        action="store_true",
        help="After all selected chunks finish, run one extra failed-row repair pass against each chunk output CSV that still contains parse_status=failed.",
    )

    # Output and logging settings.
    ap.add_argument("--save-raw-json", action="store_true", help="Store parsed JSON and raw model output in the output CSV.")
    ap.add_argument("--skip-existing", action="store_true", help="Skip chunks whose output CSV and summary JSON already exist.")
    ap.add_argument("--flat-output", action="store_true", help="Write directly to --out-dir instead of --out-dir/RUN_ID.")
    ap.add_argument("--out-dir", default=os.path.join(os.getcwd(), "output", "llama_scores"))
    ap.add_argument("--log-level", default="INFO", choices=["DEBUG", "INFO", "WARNING", "ERROR"])

    args = ap.parse_args(argv)

    # Fail early for invalid arguments so the run does not start half-configured.
    if args.endpoint is None:
        args.endpoint = u.DEFAULT_ENDPOINTS[args.model_label]
    if args.llm_checkpoint is None:
        args.llm_checkpoint = u.DEFAULT_MODEL_NAMES[args.model_label]
    if args.max_chunks < 0:
        ap.error("--max-chunks must be >= 0")
    if args.max_filings_per_chunk < 0:
        ap.error("--max-filings-per-chunk must be >= 0")
    if args.max_prompt_chars <= 0:
        ap.error("--max-prompt-chars must be > 0")
    if args.sentence_window < 0:
        ap.error("--sentence-window must be >= 0")
    if not 0.0 <= args.temperature <= 2.0:
        ap.error("--temperature must be between 0 and 2")
    if not 0.0 <= args.prefilter_audit_rate <= 1.0:
        ap.error("--prefilter-audit-rate must be between 0 and 1")
    if args.prefilter_audit_limit < 0:
        ap.error("--prefilter-audit-limit must be >= 0")
    if args.max_concurrent_invocations <= 0:
        ap.error("--max-concurrent-invocations must be > 0")
    if args.max_workers <= 0:
        ap.error("--max-workers must be > 0")
    if args.lookup_csv and not os.path.exists(args.lookup_csv):
        ap.error(f"--lookup-csv does not exist: {args.lookup_csv}")

    return args


# ---------------------------------------------------------------------------
# Output folder helper
# ---------------------------------------------------------------------------
# By default, each run gets its own timestamped output folder. This avoids
# overwriting previous QA runs. --flat-output disables that behaviour.
def output_dir_for_run(args: argparse.Namespace, run_id: str) -> str:
    return args.out_dir if args.flat_output else os.path.join(args.out_dir, run_id)


def parse_team_and_path_from_source_label(source_label: str, fallback_team: str) -> tuple[str, str]:
    """Parse team and chunk path from a stored source label."""

    text = str(source_label).strip()
    if text.startswith("team=") and ":" in text:
        team_part, path = text.split(":", 1)
        team = team_part.replace("team=", "", 1).strip() or fallback_team
        return team, path.strip()
    return fallback_team, Path(text).name


def summary_path_for_output_csv(output_csv: str, model_label: str) -> str:
    """Convert one chunk score CSV path to its summary JSON path."""

    csv_path = Path(output_csv)
    suffix = f"_{model_label}_scores.csv"
    if csv_path.name.endswith(suffix):
        return str(csv_path.with_name(csv_path.name[: -len(suffix)] + f"_{model_label}_summary.json"))
    return str(csv_path.with_suffix(".json"))


def count_failed_rows_in_csv(csv_path: str) -> int:
    """Count final failed parse rows in one existing score CSV."""

    if not os.path.exists(csv_path):
        return 0
    df = pd.read_csv(csv_path, usecols=lambda col: col in {"parse_status", "llm_called"})
    if df.empty or "parse_status" not in df.columns:
        return 0
    failed = df["parse_status"].astype(str).str.strip().eq("failed")
    if "llm_called" in df.columns:
        failed &= df["llm_called"].fillna(False).astype(bool)
    return int(failed.sum())


def repair_failed_rows_from_csv(
    csv_path: str,
    *,
    args: argparse.Namespace,
    run_id: str,
) -> dict[str, object]:
    """Repair only the rows that finished with parse_status=failed in an existing output CSV."""

    from dwutils import sm

    csv_path = os.path.abspath(csv_path)
    if not os.path.exists(csv_path):
        raise FileNotFoundError(f"Repair CSV not found: {csv_path}")

    out_df = pd.read_csv(csv_path)
    if out_df.empty:
        logging.info("Repair skipped for empty CSV: %s", csv_path)
        return {
            "chunk_name": Path(csv_path).name,
            "source_label": "",
            "status": "repair_skipped_empty_csv",
            "output_csv": csv_path,
            "output_summary": summary_path_for_output_csv(csv_path, args.model_label),
        }

    llm_called = out_df.get("llm_called", pd.Series(False, index=out_df.index)).fillna(False).astype(bool)
    parse_status = out_df.get("parse_status", pd.Series("", index=out_df.index)).astype(str).str.strip()
    failed_mask = llm_called & parse_status.eq("failed")
    failed_indices = out_df.index[failed_mask].tolist()
    if not failed_indices:
        logging.info("No failed rows to repair in %s", csv_path)
        return {
            "chunk_name": Path(csv_path).name,
            "source_label": str(out_df["source_label"].iloc[0]) if "source_label" in out_df.columns else "",
            "status": "repair_no_failed_rows",
            "output_csv": csv_path,
            "output_summary": summary_path_for_output_csv(csv_path, args.model_label),
            "n_repaired": 0,
        }

    source_label = str(out_df["source_label"].iloc[0]) if "source_label" in out_df.columns else ""
    team, chunk_path = parse_team_and_path_from_source_label(source_label, args.team)
    logging.info("Repairing %d failed rows from %s using team=%s path=%s", len(failed_indices), csv_path, team, chunk_path)

    raw = u.read_rds_from_team_s3(chunk_path, team=team)
    include_amended = bool(args.include_amended) or (
        "form_type" in out_df.columns and out_df["form_type"].astype(str).str.upper().eq("10-K/A").any()
    )
    wide = u.long_to_wide(raw, include_amended=include_amended)
    wide = wide.assign(accession_number=wide["accession_number"].astype(str).str.strip())
    wide_by_accession = {str(row["accession_number"]).strip(): row for _, row in wide.iterrows()}

    records = out_df.to_dict(orient="records")
    pending: dict[str, dict[str, object]] = {}
    save_raw_json = bool(args.save_raw_json) or "raw_response" in out_df.columns or "raw_json" in out_df.columns

    for idx in failed_indices:
        record = records[idx]
        accession = str(record.get("accession_number", "")).strip()
        wide_row = wide_by_accession.get(accession)
        if wide_row is None:
            logging.warning("Repair could not find accession %s in original chunk %s", accession, chunk_path)
            continue

        snippet = u.extract_relevant_snippets(
            u.normalize_whitespace(wide_row.get("combined_text", "")),
            args.max_prompt_chars,
            args.sentence_window,
        )
        if not snippet:
            logging.warning("Repair snippet extraction failed for accession %s in %s", accession, csv_path)
            continue

        record["run_id"] = run_id
        record["script_version"] = u.SCRIPT_VERSION
        record["prompt_version"] = u.PROMPT_VERSION
        record["llm_model"] = args.llm_checkpoint
        record["llm_checkpoint"] = args.llm_checkpoint
        record["temperature"] = float(args.temperature)
        record["max_new_tokens"] = int(args.max_new_tokens)
        record["endpoint"] = args.endpoint
        record["snippet_chars"] = len(snippet)
        record["snippet_sha256"] = u.sha256_text(snippet)
        pending[str(idx)] = {
            "record_index": idx,
            "prompt": u.build_ai_retry_prompt(snippet),
        }

    if not pending:
        logging.info("Repair found no re-runnable failed rows in %s", csv_path)
        return {
            "chunk_name": Path(csv_path).name,
            "source_label": source_label,
            "status": "repair_no_rerunnable_rows",
            "output_csv": csv_path,
            "output_summary": summary_path_for_output_csv(csv_path, args.model_label),
            "n_repaired": 0,
        }

    invoke_args = u.iter_bulk_invoke_args(
        pending,
        endpoint=args.endpoint,
        temperature=args.temperature,
        max_new_tokens=args.max_new_tokens,
    )
    results = sm.bulk_invoke_endpoint_async(
        invoke_args,
        max_concurrent_invocations=args.max_concurrent_invocations,
        max_workers=args.max_workers,
    )
    u.apply_bulk_results(records, pending, results, save_raw_json=save_raw_json, is_retry=True)

    repaired_df = u.order_columns(pd.DataFrame(records), save_raw_json)
    repaired_df.to_csv(csv_path, index=False)

    summary_path = summary_path_for_output_csv(csv_path, args.model_label)
    summary_kwargs = {
        "run_id": run_id,
        "chunk_name": Path(chunk_path).name,
        "source_label": source_label,
        "endpoint": args.endpoint,
        "prefilter_mode": str(out_df.get("prefilter_mode", pd.Series([args.prefilter_mode])).iloc[0]),
        "prefilter_audit_rate": float(out_df.get("prefilter_audit_rate", pd.Series([args.prefilter_audit_rate])).iloc[0]) if "prefilter_audit_rate" in out_df.columns else args.prefilter_audit_rate,
        "prefilter_audit_limit": int(out_df.get("prefilter_audit_limit", pd.Series([args.prefilter_audit_limit])).iloc[0]) if "prefilter_audit_limit" in out_df.columns else args.prefilter_audit_limit,
        "lookup_csv": args.lookup_csv,
        "n_filings_before_lookup": int(len(repaired_df)),
        "n_filings_after_lookup": int(len(repaired_df)),
        "output_csv": csv_path,
    }
    if os.path.exists(summary_path):
        try:
            old_summary = json.loads(Path(summary_path).read_text())
            summary_kwargs.update(
                {
                    "chunk_name": old_summary.get("chunk_name", summary_kwargs["chunk_name"]),
                    "source_label": old_summary.get("source_label", summary_kwargs["source_label"]),
                    "endpoint": old_summary.get("endpoint", summary_kwargs["endpoint"]),
                    "prefilter_mode": old_summary.get("prefilter_mode", summary_kwargs["prefilter_mode"]),
                    "prefilter_audit_rate": old_summary.get("prefilter_audit_rate", summary_kwargs["prefilter_audit_rate"]),
                    "prefilter_audit_limit": old_summary.get("prefilter_audit_limit", summary_kwargs["prefilter_audit_limit"]),
                    "lookup_csv": old_summary.get("lookup_csv", summary_kwargs["lookup_csv"]),
                    "n_filings_before_lookup": old_summary.get("n_filings_before_lookup", summary_kwargs["n_filings_before_lookup"]),
                    "n_filings_after_lookup": old_summary.get("n_filings_after_lookup", summary_kwargs["n_filings_after_lookup"]),
                }
            )
        except Exception:
            logging.warning("Could not read existing summary JSON for %s; regenerating from CSV only", csv_path)

    summary = u.summarize_output(repaired_df, **summary_kwargs)
    u.write_json(summary_path, summary)
    logging.info("Repaired %s and updated summary %s", csv_path, summary_path)

    return {
        "chunk_name": summary_kwargs["chunk_name"],
        "source_label": source_label,
        "status": "repair_ok",
        "output_csv": csv_path,
        "output_summary": summary_path,
        "n_repaired": int(len(pending)),
        "n_failed_remaining": int((repaired_df.get("parse_status", pd.Series(dtype='string')).astype(str) == "failed").sum()),
        "n_filings": int(len(repaired_df)),
        "n_llm_called": int(repaired_df["llm_called"].sum()) if "llm_called" in repaired_df.columns else 0,
        "n_ai_adopted": int((pd.to_numeric(repaired_df["ai_adoption"], errors="coerce") == 1).sum()) if "ai_adoption" in repaired_df.columns else 0,
        "n_ok": int((repaired_df["score_status"] == "ok").sum()) if "score_status" in repaired_df.columns else 0,
        "n_ok_after_retry": int((repaired_df["score_status"] == "ok_after_retry").sum()) if "score_status" in repaired_df.columns else 0,
        "n_retry_attempted": int(repaired_df["retry_attempted"].sum()) if "retry_attempted" in repaired_df.columns else 0,
    }


def maybe_repair_output_csv(
    row: dict[str, object],
    *,
    args: argparse.Namespace,
    run_id: str,
    phase_label: str,
) -> dict[str, object]:
    """Run one extra failed-row repair pass for a finished chunk output when needed."""

    output_csv = str(row.get("output_csv", "") or "").strip()
    if not output_csv or not os.path.exists(output_csv):
        return row

    n_failed = count_failed_rows_in_csv(output_csv)
    if n_failed <= 0:
        return row

    logging.info(
        "Starting %s repair pass for %s with %d failed row(s)",
        phase_label,
        output_csv,
        n_failed,
    )
    repair_row = repair_failed_rows_from_csv(output_csv, args=args, run_id=run_id)
    merged = dict(row)
    merged["repair_phase"] = phase_label
    merged["repair_status"] = repair_row.get("status", "")
    merged["repair_n_repaired"] = repair_row.get("n_repaired", 0)
    merged["repair_n_failed_remaining"] = repair_row.get("n_failed_remaining", n_failed)
    merged["output_summary"] = repair_row.get("output_summary", row.get("output_summary", ""))
    merged["output_csv"] = repair_row.get("output_csv", output_csv)
    for key in [
        "n_filings",
        "n_llm_called",
        "n_ai_adopted",
        "n_ok",
        "n_ok_after_retry",
        "n_retry_attempted",
    ]:
        if key in repair_row:
            merged[key] = repair_row[key]
    return merged


# ---------------------------------------------------------------------------
# Process one chunk
# ---------------------------------------------------------------------------
# This is the core workflow for one extract_df_chunk_XXXXX.rds file:
# read -> reshape -> lookup filter -> prefilter/prompt prep -> bulk LLM ->
# parse results -> write CSV and JSON summary.
def process_chunk(
    ref: u.ChunkRef,
    *,
    args: argparse.Namespace,
    run_id: str,
    lookup: Optional[pd.DataFrame],
) -> dict[str, object]:
    # Build output paths for this chunk.
    chunk_id = Path(ref.name).stem
    run_out_dir = output_dir_for_run(args, run_id)
    os.makedirs(run_out_dir, exist_ok=True)

    out_csv = os.path.join(run_out_dir, f"{chunk_id}_{args.model_label}_scores.csv")
    out_json = os.path.join(run_out_dir, f"{chunk_id}_{args.model_label}_summary.json")
    source_label = f"team={args.team}:{ref.path}"

    # Optional resume behaviour: skip this chunk if final outputs already exist.
    if args.skip_existing and os.path.exists(out_csv) and os.path.exists(out_json):
        logging.info("Skipping existing output for %s", ref.name)
        return {
            "chunk_name": ref.name,
            "source_label": source_label,
            "status": "skipped_existing",
            "output_csv": out_csv,
            "output_summary": out_json,
        }

    # Read the RDS chunk from Data Workspace S3 and reshape Item 1 / Item 7
    # into one filing-level row per accession number.
    logging.info("Reading %s", source_label)
    raw = u.read_rds_from_team_s3(ref.path, team=args.team)
    wide = u.long_to_wide(raw, include_amended=args.include_amended)

    # Keep only cik/year pairs that appear in the research lookup.
    # This happens before any LLM calls, so irrelevant filings are never labeled.
    n_before_lookup = len(wide)
    wide = u.filter_to_lookup(wide, lookup)
    n_after_lookup = len(wide)
    logging.info("Lookup filter kept %d/%d filing rows", n_after_lookup, n_before_lookup)

    # For QA runs, optionally cap the number of filings processed in the chunk.
    if args.max_filings_per_chunk > 0:
        wide = wide.head(args.max_filings_per_chunk).copy()

    # Create output records for every filing. This also decides which rows need
    # the LLM and prepares prompts only for those rows.
    records, pending = u.prepare_records_and_prompts(
        wide,
        run_id=run_id,
        chunk_id=chunk_id,
        source_label=source_label,
        llm_model=args.llm_checkpoint,
        llm_checkpoint=args.llm_checkpoint,
        temperature=args.temperature,
        max_new_tokens=args.max_new_tokens,
        endpoint=args.endpoint,
        prefilter_mode=args.prefilter_mode,
        audit_seed=args.audit_seed,
        prefilter_audit_rate=args.prefilter_audit_rate,
        prefilter_audit_limit=args.prefilter_audit_limit,
        max_prompt_chars=args.max_prompt_chars,
        sentence_window=args.sentence_window,
    )

    # Submit all required LLM calls in bulk. Rows skipped by the prefilter are
    # already complete and do not appear in pending.
    if pending:
        from dwutils import sm

        logging.info("Submitting %d LLM calls for %s using bulk async invocation", len(pending), ref.name)
        invoke_args = u.iter_bulk_invoke_args(
            pending,
            endpoint=args.endpoint,
            temperature=args.temperature,
            max_new_tokens=args.max_new_tokens,
        )
        results = sm.bulk_invoke_endpoint_async(
            invoke_args,
            max_concurrent_invocations=args.max_concurrent_invocations,
            max_workers=args.max_workers,
        )
        u.apply_bulk_results(records, pending, results, save_raw_json=args.save_raw_json)

        if not args.no_retry_pass:
            retry_pending = {
                linked_obj: {
                    "record_index": item["record_index"],
                    "prompt": item["retry_prompt"],
                }
                for linked_obj, item in pending.items()
                if records[item["record_index"]].get("score_status") in u.RETRYABLE_PARSE_STATUSES
            }
            if retry_pending:
                logging.info("Retrying %d parser-failure rows for %s with stricter JSON retry prompt", len(retry_pending), ref.name)
                retry_invoke_args = u.iter_bulk_invoke_args(
                    retry_pending,
                    endpoint=args.endpoint,
                    temperature=args.temperature,
                    max_new_tokens=args.max_new_tokens,
                )
                retry_results = sm.bulk_invoke_endpoint_async(
                    retry_invoke_args,
                    max_concurrent_invocations=args.max_concurrent_invocations,
                    max_workers=args.max_workers,
                )
                u.apply_bulk_results(
                    records,
                    retry_pending,
                    retry_results,
                    save_raw_json=args.save_raw_json,
                    is_retry=True,
                )
    else:
        logging.info("No LLM calls needed for %s", ref.name)

    # Write the filing-level output CSV.
    out_df = u.order_columns(pd.DataFrame(records), args.save_raw_json)
    out_df.to_csv(out_csv, index=False)

    # Write a compact chunk-level summary for QA.
    summary = u.summarize_output(
        out_df,
        run_id=run_id,
        chunk_name=ref.name,
        source_label=source_label,
        endpoint=args.endpoint,
        prefilter_mode=args.prefilter_mode,
        prefilter_audit_rate=args.prefilter_audit_rate,
        prefilter_audit_limit=args.prefilter_audit_limit,
        lookup_csv=args.lookup_csv,
        n_filings_before_lookup=n_before_lookup,
        n_filings_after_lookup=n_after_lookup,
        output_csv=out_csv,
    )
    u.write_json(out_json, summary)

    # Return one manifest row describing this chunk.
    logging.info("Wrote %s (%d rows)", out_csv, len(out_df))
    return {
        "chunk_name": ref.name,
        "source_label": source_label,
        "status": "ok",
        "output_csv": out_csv,
        "output_summary": out_json,
        "n_filings_before_lookup": n_before_lookup,
        "n_filings_after_lookup": n_after_lookup,
        "n_filings": int(len(out_df)),
        "n_llm_called": int(out_df["llm_called"].sum()) if not out_df.empty else 0,
        "n_ai_adopted": int((pd.to_numeric(out_df["ai_adopted"], errors="coerce") == 1).sum()) if not out_df.empty else 0,
        "n_ok": int((out_df["score_status"] == "ok").sum()) if not out_df.empty else 0,
        "n_ok_after_retry": int((out_df["score_status"] == "ok_after_retry").sum()) if not out_df.empty else 0,
        "n_retry_attempted": int(out_df["retry_attempted"].sum()) if not out_df.empty and "retry_attempted" in out_df.columns else 0,
    }


# ---------------------------------------------------------------------------
# Main process
# ---------------------------------------------------------------------------
# This controls the whole run: parse arguments, list/select chunks, load the
# lookup once, process each chunk, and write the run manifest.
def main(argv: Optional[Sequence[str]] = None) -> int:
    # Parse command-line options and configure logs.
    args = parse_args(argv)
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s | %(levelname)s | %(message)s",
    )

    if args.repair_failed_from_csv:
        run_id = u.utc_now()
        run_out_dir = output_dir_for_run(args, run_id)
        os.makedirs(run_out_dir, exist_ok=True)

        manifest_rows = []
        for csv_path in args.repair_failed_from_csv:
            try:
                manifest_rows.append(repair_failed_rows_from_csv(csv_path, args=args, run_id=run_id))
            except Exception as exc:
                logging.exception("Failed repairing %s", csv_path)
                manifest_rows.append(
                    {
                        "chunk_name": Path(csv_path).name,
                        "source_label": "",
                        "status": "repair_failed",
                        "output_csv": os.path.abspath(csv_path),
                        "output_summary": summary_path_for_output_csv(os.path.abspath(csv_path), args.model_label),
                        "error": str(exc)[:1000],
                    }
                )

        manifest = pd.DataFrame(manifest_rows)
        manifest_path = os.path.join(run_out_dir, f"repair_manifest_{run_id}.csv")
        manifest.to_csv(manifest_path, index=False)
        logging.info("Wrote repair manifest: %s", manifest_path)
        return 0

    # Find available chunks in the Data Workspace team folder.
    available = u.list_chunks(args.team, args.chunk_prefix, bucket=args.s3_bucket)
    if args.list_only:
        if not available:
            print(f"No chunk files found for team={args.team}, chunk_prefix={args.chunk_prefix!r}")
            return 0
        for name in available:
            print(name)
        return 0

    # Resolve the user's chunk selection into actual chunk references.
    max_chunks = args.max_chunks if args.max_chunks > 0 else None
    selected = u.select_chunks(
        available,
        chunk_names=args.chunk_names,
        chunk_ids=args.chunk_ids,
        chunk_range=args.chunk_range,
        all_chunks=args.all_chunks,
        max_chunks=max_chunks,
    )

    # Create one run id and output folder shared by all chunks in this run.
    run_id = u.utc_now()
    run_out_dir = output_dir_for_run(args, run_id)
    os.makedirs(run_out_dir, exist_ok=True)

    # Load the research lookup once, then reuse it for every chunk.
    lookup = u.load_cik_year_lookup(args.lookup_csv)

    # Process chunks one by one. A failed chunk is recorded in the manifest
    # instead of stopping the whole run.
    manifest_rows = []
    for ref in selected:
        try:
            row = process_chunk(ref, args=args, run_id=run_id, lookup=lookup)
            if args.repair_failed_after_chunk and row.get("status") == "ok":
                row = maybe_repair_output_csv(
                    row,
                    args=args,
                    run_id=run_id,
                    phase_label="after_chunk",
                )
            manifest_rows.append(row)
        except Exception as exc:
            logging.exception("Failed processing %s", ref.name)
            manifest_rows.append(
                {
                    "chunk_name": ref.name,
                    "source_label": f"team={args.team}:{ref.path}",
                    "status": "failed",
                    "output_csv": "",
                    "output_summary": "",
                    "error": str(exc)[:1000],
                }
            )

    if args.repair_failed_after_run:
        repaired_manifest_rows = []
        for row in manifest_rows:
            if row.get("status") == "ok":
                try:
                    row = maybe_repair_output_csv(
                        row,
                        args=args,
                        run_id=run_id,
                        phase_label="after_run",
                    )
                except Exception as exc:
                    logging.exception("Failed after-run repair for %s", row.get("output_csv", ""))
                    row = dict(row)
                    row["repair_phase"] = "after_run"
                    row["repair_status"] = "repair_failed"
                    row["repair_error"] = str(exc)[:1000]
            repaired_manifest_rows.append(row)
        manifest_rows = repaired_manifest_rows

    # Write a run-level manifest summarising all chunk outcomes.
    manifest = pd.DataFrame(manifest_rows)
    manifest_path = os.path.join(run_out_dir, f"run_manifest_{run_id}.csv")
    manifest.to_csv(manifest_path, index=False)
    logging.info("Wrote run manifest: %s", manifest_path)
    return 0


# Standard Python entry point. This lets the file be run as a script.
if __name__ == "__main__":
    sys.exit(main())
