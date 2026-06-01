#!/usr/bin/env python3
"""Bulk LLM scoring for filing-level AI adoption.

The process estimates firm-level AI adoption from SEC Form 10-K disclosures. 
It reads EDGAR extract chunks from the Data Workspace team S3 folder, 
converts Item 1 and Item 7 text into one row per filing,
optionally filters to a research lookup of `cik` and `year`, 
and sends relevant filing snippets to a Data Workspace SageMaker Llama endpoint.
"""

from __future__ import annotations

import argparse
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
        description="Score selected EDGAR chunk files for AI adoption using Data Workspace bulk async SageMaker invocation."
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

    # QA and sample-filtering options.
    ap.add_argument("--list-only", action="store_true", help="List available chunks and exit.")
    ap.add_argument("--max-chunks", type=int, default=0, help="Cap selected chunks after selection.")
    ap.add_argument("--max-filings-per-chunk", type=int, default=0, help="QA option: score only first N matched filings per chunk.")
    ap.add_argument("--lookup-csv", default=None, help="CSV with cik and year columns. Only matching filings are scored.")
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
    ap.add_argument("--endpoint", default=None, help="Overrise SageMaker endpoint. If omitted, uses the default for --model-label.")
    ap.add_argument("--max-prompt-chars", type=int, default=1500)
    ap.add_argument("--sentence-window", type=int, default=1)
    ap.add_argument("--temperature", type=float, default=0.0)
    ap.add_argument("--max-new-tokens", type=int, default=80)
    ap.add_argument("--max-concurrent-invocations", type=int, default=25)
    ap.add_argument("--max-workers", type=int, default=9)

    # Output and logging settings.
    ap.add_argument("--save-raw-json", action="store_true", help="Store parsed raw model JSON in the score CSV.")
    ap.add_argument("--skip-existing", action="store_true", help="Skip chunks whose score CSV and summary JSON already exist.")
    ap.add_argument("--flat-output", action="store_true", help="Write directly to --out-dir instead of --out-dir/RUN_ID.")
    ap.add_argument("--out-dir", default=os.path.join(os.getcwd(), "output", "llama_scores"))
    ap.add_argument("--log-level", default="INFO", choices=["DEBUG", "INFO", "WARNING", "ERROR"])

    args = ap.parse_args(argv)

    # Fail early for invalid arguments so the run does not start half-configured.
    if args.endpoint is None:
        args.endpoint = u.DEFAULT_ENDPOINTS[args.model_label]  
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
    # This happens before any LLM calls, so irrelevant filings are never scored.
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
    else:
        logging.info("No LLM calls needed for %s", ref.name)

    # Write the filing-level score CSV.
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
        "n_ok": int((out_df["score_status"] == "ok").sum()) if not out_df.empty else 0,
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
            manifest_rows.append(process_chunk(ref, args=args, run_id=run_id, lookup=lookup))
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

    # Write a run-level manifest summarising all chunk outcomes.
    manifest = pd.DataFrame(manifest_rows)
    manifest_path = os.path.join(run_out_dir, f"run_manifest_{run_id}.csv")
    manifest.to_csv(manifest_path, index=False)
    logging.info("Wrote run manifest: %s", manifest_path)
    return 0


# Standard Python entry point. This lets the file be run as a script.
if __name__ == "__main__":
    sys.exit(main())
