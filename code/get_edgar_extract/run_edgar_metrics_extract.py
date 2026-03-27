#!/usr/bin/env python3
"""
Wrapper for mmcodesso/edgar-metrics-parser to:
1. write config.ini
2. run step1_downloader.py
3. run step2_extract.py
4. optionally flatten/copy Item 1 and Item 7 outputs

This uses the repo's native process:
- step1_downloader.py
- step2_extract.py

Expected output from the repo:
<data_dir>/extract/10-K/item1/<YEAR>/*.txt
<data_dir>/extract/10-K/item7/<YEAR>/*.txt
"""

from __future__ import annotations

import argparse
import configparser
import shutil
import subprocess
import sys
from datetime import date
from pathlib import Path


def write_config(
    repo_dir: Path,
    data_dir: Path,
    email: str,
    company: str,
    start_date: str,
    end_date: str,
    overwrite: bool,
    num_doc: int,
    log_level: str = "INFO",
) -> Path:
    """
    Write config.ini in the parser repo format.
    """
    config = configparser.ConfigParser()

    config["settings"] = {
        "email": email,
        "company": company,
        "data_dir": str(data_dir),
        "start_date": start_date,
        "end_date": end_date,
        "form_type": "10-K",
        "overwrite": str(overwrite),
        "num_doc": str(num_doc),
        "log_level": log_level,
        "last_update": start_date,
    }

    config_path = repo_dir / "config.ini"
    with config_path.open("w", encoding="utf-8") as f:
        config.write(f)

    return config_path


def run_script(script_path: Path, cwd: Path) -> None:
    cmd = [sys.executable, str(script_path)]
    print("Running:", " ".join(cmd))
    subprocess.run(cmd, cwd=str(cwd), check=True)


def flatten_extracted_outputs(data_dir: Path, flat_dir: Path) -> None:
    """
    Copy extracted item1 and item7 files into flatter directories:

    <flat_dir>/item1/<YEAR>/<filename>.txt
    <flat_dir>/item7/<YEAR>/<filename>.txt
    """
    src_item1 = data_dir / "extract" / "10-K" / "item1"
    src_item7 = data_dir / "extract" / "10-K" / "item7"

    for label, src_root in [("item1", src_item1), ("item7", src_item7)]:
        if not src_root.exists():
            print(f"Skipping flatten for {label}: source not found -> {src_root}")
            continue

        for txt_file in src_root.rglob("*.txt"):
            year = txt_file.parent.name
            dest_dir = flat_dir / label / year
            dest_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(txt_file, dest_dir / txt_file.name)

    print(f"Flattened outputs copied to: {flat_dir}")


def validate_repo(repo_dir: Path) -> None:
    needed = [
        repo_dir / "step1_downloader.py",
        repo_dir / "step2_extract.py",
    ]
    missing = [str(p) for p in needed if not p.exists()]
    if missing:
        raise FileNotFoundError(
            "Missing required repo files:\n" + "\n".join(missing)
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--repo-dir",
        required=True,
        help="Path to the edgar-metrics-parser repo",
    )
    parser.add_argument(
        "--data-dir",
        required=True,
        help="Directory where downloaded forms and extracted items will be stored",
    )
    parser.add_argument(
        "--email",
        required=True,
        help="Email for SEC User-Agent",
    )
    parser.add_argument(
        "--company",
        required=True,
        help="Company/organization name for SEC User-Agent",
    )
    parser.add_argument(
        "--start-date",
        required=True,
        help="Start date in YYYY-MM-DD",
    )
    parser.add_argument(
        "--end-date",
        default=str(date.today()),
        help="End date in YYYY-MM-DD. Defaults to today.",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="If set, re-download files even if they already exist",
    )
    parser.add_argument(
        "--num-doc",
        type=int,
        default=-1,
        help="Optional document cap. Use -1 for no limit.",
    )
    parser.add_argument(
        "--flatten-output-dir",
        default="",
        help="Optional directory to copy item1/item7 files into a flatter layout",
    )

    args = parser.parse_args()

    repo_dir = Path(args.repo_dir).expanduser().resolve()
    data_dir = Path(args.data_dir).expanduser().resolve()
    flat_dir = Path(args.flatten_output_dir).expanduser().resolve() if args.flatten_output_dir else None

    validate_repo(repo_dir)
    data_dir.mkdir(parents=True, exist_ok=True)

    config_path = write_config(
        repo_dir=repo_dir,
        data_dir=data_dir,
        email=args.email,
        company=args.company,
        start_date=args.start_date,
        end_date=args.end_date,
        overwrite=args.overwrite,
        num_doc=args.num_doc,
    )

    print(f"Config written to: {config_path}")

    step1 = repo_dir / "step1_downloader.py"
    step2 = repo_dir / "step2_extract.py"

    run_script(step1, cwd=repo_dir)
    run_script(step2, cwd=repo_dir)

    item1_dir = data_dir / "extract" / "10-K" / "item1"
    item7_dir = data_dir / "extract" / "10-K" / "item7"

    print("\nDone.")
    print(f"Item 1 output: {item1_dir}")
    print(f"Item 7 output: {item7_dir}")

    if flat_dir is not None:
        flatten_extracted_outputs(data_dir=data_dir, flat_dir=flat_dir)


if __name__ == "__main__":
    main()
