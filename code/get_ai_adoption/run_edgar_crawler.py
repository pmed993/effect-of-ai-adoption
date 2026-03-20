#!/usr/bin/env python3
"""
Run EDGAR-CRAWLER from a CIK-year input file and save:
- Item 1 / Business Description
- Item 7 / Management's Discussion and Analysis

Expected project structure example:
effect-of-genai/
├─ cache/
│  ├─ edgar_link_final.csv   # or .rds
│  └─ ...
├─ external/
│  └─ edgar-crawler/
│     ├─ config.json
│     ├─ download_filings.py
│     └─ extract_items.py
└─ code/
   └─ get_ai_adoption/
      └─ run_edgar_crawler_from_pairs.py

This wrapper uses the:
- edgar-crawler works by year / quarter / CIK filters via config.json
- combined with my COMPUSTAT CIK-year pairs
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Iterable

import pandas as pd

try:
    import pyreadr  # only needed if input is .rds
except ImportError:
    pyreadr = None

def read_pairs(path: Path) -> pd.DataFrame:
    """
    Read a CIK-year file.
    Supported:
    - .csv
    - .rds (requires pyreadr)

    Required columns:
    - cik
    - year
    """
    suffix = path.suffix.lower()

    if suffix == ".csv":
        df = pd.read_csv(path)
    elif suffix == ".rds":
        if pyreadr is None:
            raise ImportError(
                "pyreadr is required to read .rds files. Install with: pip install pyreadr"
            )
        result = pyreadr.read_r(str(path))
        # first object in the RDS
        df = next(iter(result.values()))
    else:
        raise ValueError(f"Unsupported input format: {path.suffix}")

    required = {"cik", "year"}
    missing = required - set(df.columns)
    if missing:
        raise ValueError(f"Missing required columns: {sorted(missing)}")

    df = df.copy()
    df["cik"] = df["cik"].astype(str).str.replace(r"\.0$", "", regex=True).str.strip()
    df["year"] = df["year"].astype(int)

    df = df[["cik", "year"]].drop_duplicates().sort_values(["year", "cik"]).reset_index(drop=True)
    return df


def write_cik_file(ciks: Iterable[str], out_file: Path) -> None:
    out_file.parent.mkdir(parents=True, exist_ok=True)
    with out_file.open("w", encoding="utf-8") as f:
        for cik in sorted(set(ciks)):
            f.write(f"{cik}\n")


def build_config(
    pairs_df: pd.DataFrame,
    user_agent: str,
    crawler_workdir: Path,
    raw_folder: str,
    extracted_folder: str,
    indices_folder: str,
    metadata_file: str,
) -> dict:
    start_year = int(pairs_df["year"].min())
    end_year = int(pairs_df["year"].max())

    cik_file = crawler_workdir / "tmp_ciks.txt"
    write_cik_file(pairs_df["cik"].tolist(), cik_file)

    return {
        "download_filings": {
            "start_year": start_year,
            "end_year": end_year,
            "quarters": [1, 2, 3, 4],
            "filing_types": ["10-K"],
            "cik_tickers": str(cik_file),
            "user_agent": user_agent,
            "raw_filings_folder": raw_folder,
            "indices_folder": indices_folder,
            "filings_metadata_file": metadata_file,
            "skip_present_indices": True,
        },
        "extract_items": {
            "raw_filings_folder": raw_folder,
            "extracted_filings_folder": extracted_folder,
            "filings_metadata_file": metadata_file,
            "filing_types": ["10-K"],
            "include_signature": False,
            "items_to_extract": ["1", "7"],
            "remove_tables": False,
            "skip_extracted_filings": True,
        },
    }


def run_python_script(script_path: Path, cwd: Path) -> None:
    cmd = [sys.executable, str(script_path)]
    print("Running:", " ".join(cmd))
    subprocess.run(cmd, cwd=str(cwd), check=True)


def load_metadata(metadata_path: Path) -> pd.DataFrame:
    if not metadata_path.exists():
        raise FileNotFoundError(f"Metadata file not found: {metadata_path}")

    meta = pd.read_csv(metadata_path)
    meta.columns = [c.strip() for c in meta.columns]

    lower_map = {c.lower(): c for c in meta.columns}

    cik_col = lower_map.get("cik")
    filing_type_col = lower_map.get("filing_type") or lower_map.get("type")
    filing_date_col = lower_map.get("filing_date") or lower_map.get("date") or lower_map.get("filing date")
    filename_col = lower_map.get("filename")

    needed = {
        "cik": cik_col,
        "filing_type": filing_type_col,
        "filing_date": filing_date_col,
        "filename": filename_col,
    }
    missing = [k for k, v in needed.items() if v is None]
    if missing:
        raise ValueError(
            f"Metadata file is missing expected columns: {missing}. "
            f"Available columns: {list(meta.columns)}"
        )

    out = meta[[cik_col, filing_type_col, filing_date_col, filename_col]].copy()
    out.columns = ["cik", "filing_type", "filing_date", "filename"]

    out["cik"] = out["cik"].astype(str).str.replace(r"\.0$", "", regex=True).str.strip()
    out["filing_type"] = out["filing_type"].astype(str).str.strip()
    out["filing_date"] = pd.to_datetime(out["filing_date"], errors="coerce")
    out["year"] = out["filing_date"].dt.year

    out = out[out["filing_type"].str.upper() == "10-K"].copy()
    return out


def load_extracted_jsons(extracted_dir: Path) -> pd.DataFrame:
    rows = []

    for fp in extracted_dir.glob("*.json"):
        try:
            with fp.open("r", encoding="utf-8") as f:
                obj = json.load(f)
        except Exception as e:
            print(f"Skipping unreadable JSON: {fp.name} ({e})")
            continue

        rows.append(
            {
                "json_file": fp.name,
                "filename": obj.get("filename"),
                "cik": str(obj.get("cik", "")).replace(".0", ""),
                "filing_type": obj.get("filing_type"),
                "filing_date": obj.get("filing_date"),
                "item_1": obj.get("item_1", ""),
                "item_7": obj.get("item_7", ""),
                "full_json": obj,
            }
        )

    if not rows:
        return pd.DataFrame(
            columns=["json_file", "filename", "cik", "filing_type", "filing_date", "item_1", "item_7", "full_json"]
        )

    df = pd.DataFrame(rows)
    df["filing_date"] = pd.to_datetime(df["filing_date"], errors="coerce")
    df["year"] = df["filing_date"].dt.year
    return df


def safe_text(x: object) -> str:
    if x is None:
        return ""
    if isinstance(x, str):
        return x.strip()
    return str(x).strip()


def save_outputs(
    matched: pd.DataFrame,
    out_bus_dir: Path,
    out_mgmt_dir: Path,
    out_csv: Path,
) -> None:
    out_bus_dir.mkdir(parents=True, exist_ok=True)
    out_mgmt_dir.mkdir(parents=True, exist_ok=True)
    out_csv.parent.mkdir(parents=True, exist_ok=True)

    flat_rows = []

    for _, row in matched.iterrows():
        cik = row["cik"]
        year = int(row["year"])
        base = f"{cik}-10-K-{year}"

        item_1 = safe_text(row.get("item_1", ""))
        item_7 = safe_text(row.get("item_7", ""))

        bus_file = out_bus_dir / f"{base}_BusDesc.txt"
        mgmt_file = out_mgmt_dir / f"{base}_MgmtDisc.txt"

        bus_status = "missing"
        mgmt_status = "missing"

        if item_1:
            bus_file.write_text(item_1, encoding="utf-8")
            bus_status = "ok"

        if item_7:
            mgmt_file.write_text(item_7, encoding="utf-8")
            mgmt_status = "ok"

        flat_rows.append(
            {
                "cik": cik,
                "year": year,
                "filename": row.get("filename", ""),
                "json_file": row.get("json_file", ""),
                "bus_status": bus_status,
                "mgmt_status": mgmt_status,
                "bus_file": str(bus_file),
                "mgmt_file": str(mgmt_file),
            }
        )

    out_df = pd.DataFrame(flat_rows)

    if out_df.empty:
        out_df = pd.DataFrame(columns=[
            "cik", "year", "filename", "json_file",
            "bus_status", "mgmt_status", "bus_file", "mgmt_file"
        ])
    
    out_df.sort_values(["year", "cik"]).to_csv(out_csv, index=False)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--project-root",
        required=True,
        help="Path to your project root, e.g. /Users/piomedolla/Desktop/effect-of-genai",
    )
    parser.add_argument(
        "--pairs-file",
        required=True,
        help="Path to CSV or RDS containing cik/year columns",
    )
    parser.add_argument(
        "--crawler-dir",
        default="external/edgar-crawler",
        help="Path to edgar-crawler repo relative to project root or absolute path",
    )
    parser.add_argument(
        "--user-agent",
        required=True,
        help='SEC user agent, e.g. "Pio Medolla pio.medolla@kcl.ac.uk"',
    )
    parser.add_argument(
        "--force-redownload",
        action="store_true",
        help="If set, do not skip existing raw files / extracted files / indices",
    )
    args = parser.parse_args()

    project_root = Path(args.project_root).expanduser().resolve()
    pairs_file = Path(args.pairs_file).expanduser().resolve()

    crawler_dir = Path(args.crawler_dir)
    if not crawler_dir.is_absolute():
        crawler_dir = (project_root / crawler_dir).resolve()

    if not crawler_dir.exists():
        raise FileNotFoundError(f"edgar-crawler repo not found: {crawler_dir}")

    download_script = crawler_dir / "download_filings.py"
    extract_script = crawler_dir / "extract_items.py"
    config_path = crawler_dir / "config.json"

    for fp in [download_script, extract_script]:
        if not fp.exists():
            raise FileNotFoundError(f"Required edgar-crawler script not found: {fp}")

    pairs_df = read_pairs(pairs_file)
    print(f"Loaded {len(pairs_df):,} unique cik-year pairs")

    cache_root = project_root / "cache" / "edgar_crawler"
    raw_folder = str(cache_root / "RAW_FILINGS")
    extracted_folder = str(cache_root / "EXTRACTED_FILINGS")
    indices_folder = str(cache_root / "INDICES")
    metadata_file = str(cache_root / "filings_metadata.csv")

    cache_root.mkdir(parents=True, exist_ok=True)

    config = build_config(
        pairs_df=pairs_df,
        user_agent=args.user_agent,
        crawler_workdir=crawler_dir,
        raw_folder=raw_folder,
        extracted_folder=extracted_folder,
        indices_folder=indices_folder,
        metadata_file=metadata_file,
    )

    if args.force_redownload:
        config["download_filings"]["skip_present_indices"] = False
        config["extract_items"]["skip_extracted_filings"] = False

    backup_path = None
    if config_path.exists():
        backup_path = crawler_dir / "config.json.bak_chatgpt"
        shutil.copy2(config_path, backup_path)

    try:
        with config_path.open("w", encoding="utf-8") as f:
            json.dump(config, f, indent=2)

        run_python_script(download_script, cwd=crawler_dir)
        run_python_script(extract_script, cwd=crawler_dir)

        metadata_df = load_metadata(Path(metadata_file))
        json_df = load_extracted_jsons(Path(extracted_folder))

        print("json_df columns:", list(json_df.columns))
        print("metadata_df columns:", list(metadata_df.columns))

        # Prefer JSON metadata if present, but merge on filename when possible
        if "filename" in json_df.columns and json_df["filename"].notna().any():
            merged = json_df.merge(
                metadata_df[["filename", "year"]].drop_duplicates(),
                on="filename",
                how="left",
            )
        else:
            merged = json_df.copy()

        print("merged columns:", list(merged.columns))

        if "cik" not in merged.columns:
            raise ValueError(f"No cik column after merge. Columns: {list(merged.columns)}")

        merged["cik"] = merged["cik"].astype(str).str.replace(r"\.0$", "", regex=True)

        if "year" not in merged.columns:
            if "filename" in merged.columns:
                merged["year"] = (
                    merged["filename"]
                    .astype(str)
                    .str.extract(r"^[^_]+_[^_]+_(\d{4})_", expand=False)
                )
                merged["year"] = pd.to_numeric(merged["year"], errors="coerce").astype("Int64")
            elif "filing_date" in merged.columns:
                merged["filing_date"] = pd.to_datetime(merged["filing_date"], errors="coerce")
                merged["year"] = merged["filing_date"].dt.year.astype("Int64")
            else:
                raise ValueError(
                    f"No year, filename, or filing_date column after merge. Columns: {list(merged.columns)}"
                )
        else:
            merged["year"] = pd.to_numeric(merged["year"], errors="coerce").astype("Int64")
        
        
        # build both candidate years
        merged["filing_year"] = pd.to_datetime(merged["filing_date"], errors="coerce").dt.year.astype("Int64")
        merged["report_year"] = (
            merged["filename"]
            .astype(str)
            .str.extract(r"^[^_]+_[^_]+_(\d{4})_", expand=False)
        )
        merged["report_year"] = pd.to_numeric(merged["report_year"], errors="coerce").astype("Int64")
        
        target_pairs = pairs_df.copy()
        target_pairs["cik"] = target_pairs["cik"].astype(str).str.replace(r"\.0$", "", regex=True).str.strip()
        
        target_pairs["pair_key_filing"] = (
            target_pairs["cik"].astype(str) + "_" + target_pairs["year"].astype(str)
        )
        target_pairs["pair_key_report"] = (
            target_pairs["cik"].astype(str) + "_" + target_pairs["year"].astype(str)
        )
        
        merged["pair_key_filing"] = (
            merged["cik"].astype(str) + "_" + merged["filing_year"].astype(str)
        )
        merged["pair_key_report"] = (
            merged["cik"].astype(str) + "_" + merged["report_year"].astype(str)
        )
        
        n_filing = merged["pair_key_filing"].isin(set(target_pairs["pair_key_filing"])).sum()
        n_report = merged["pair_key_report"].isin(set(target_pairs["pair_key_report"])).sum()
        
        print("Matches using filing_year:", n_filing)
        print("Matches using report_year:", n_report)
        
        print("\nSample target pairs:")
        print(target_pairs[["cik", "year"]].head(10).to_string(index=False))
        
        print("\nSample extracted pairs:")
        print(
            merged[["cik", "filing_date", "filing_year", "report_year", "filename"]]
            .head(10)
            .to_string(index=False)
        )
                
        
        
        
        
        
        target_pairs = pairs_df.copy()
        target_pairs["cik"] = target_pairs["cik"].astype(str).str.replace(r"\.0$", "", regex=True).str.strip()
        
        if n_report >= n_filing:
            merged["year"] = merged["report_year"]
            print("Using report_year for matching")
        else:
            merged["year"] = merged["filing_year"]
            print("Using filing_year for matching")
        
        target_pairs["pair_key"] = (
            target_pairs["cik"].astype(str) + "_" + target_pairs["year"].astype(str)
        )
        
        merged["pair_key"] = (
            merged["cik"].astype(str) + "_" + merged["year"].astype(str)
        )
        
        matched = merged[merged["pair_key"].isin(set(target_pairs["pair_key"]))].copy()




        print("Matched rows:", len(matched))
        print(matched[["cik", "year", "filename"]].head(10).to_string(index=False))

        out_bus_dir = project_root / "cache" / "edgar_BusDesc_edgarcrawler"
        out_mgmt_dir = project_root / "cache" / "edgar_MgmtDisc_edgarcrawler"
        out_csv = project_root / "cache" / "logs" / "edgar_crawler_extraction_summary.csv"
        
        print("Matched rows:", len(matched))
        print(matched[["cik", "year", "filename"]].head())

        save_outputs(
            matched=matched,
            out_bus_dir=out_bus_dir,
            out_mgmt_dir=out_mgmt_dir,
            out_csv=out_csv,
        )

        print("\nFinished.")
        print(f"Matched pairs: {len(matched):,}")
        print(f"Business output dir: {out_bus_dir}")
        print(f"MD&A output dir: {out_mgmt_dir}")
        print(f"Summary file: {out_csv}")

    finally:
        if backup_path is not None and backup_path.exists():
            shutil.move(str(backup_path), str(config_path))


if __name__ == "__main__":
    main()
