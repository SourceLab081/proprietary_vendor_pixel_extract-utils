#!/usr/bin/env python3
"""Python replacement for extract-all.sh that uses per-repo Python utils."""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path


def fatal(msg: str, code=1):
    print(f"Error: {msg}")
    sys.exit(code)


def update_proprietary_headers(repo_path: Path, phone_base: str, tablet_base: str):
    for file in repo_path.glob('proprietary-files*.txt'):
        try:
            text = file.read_text().splitlines()
            if 'tablet' in file.name:
                header = f"# Extracted from {tablet_base}"
            else:
                header = f"# Extracted from {phone_base}"
            if text:
                text[0] = header
            else:
                text = [header]
            file.write_text("\n".join(text) + "\n")
        except Exception as e:
            print(f"Warning: failed to update header for {file}: {e}")


def run_repo_extract(repo: str, phone_zip: Path, tablet_zip: Path, phone_base: str, tablet_base: str, android_root: Path):
    repo_path = Path(repo)
    if not repo_path.is_dir():
        print(f"Repo directory {repo} does not exist, skipping.")
        return

    print(f"Processing repo: {repo}")
    extract_py = (repo_path / 'extract-files.py').resolve()
    if not extract_py.exists():
        print(f"Warning: extract-files.py not found in {repo}, skipping")
        return

    cwd = os.getcwd()
    os.chdir(repo_path)
    try:
        subprocess.run([str(extract_py), str(phone_zip), '--keep-dump'], check=False)
        if repo == 'launcher':
            subprocess.run([str(extract_py), str(tablet_zip), '--keep-dump', '-s', 'Launcher-Tablet', '-k'], check=False)

        update_proprietary_headers(repo_path, phone_base, tablet_base)

        subprocess.run(['git', 'add', '.'], check=False)
        if repo == 'launcher':
            msg = f"{repo}: Update from {phone_base} and {tablet_base}"
        else:
            msg = f"{repo}: Update from {phone_base}"
        subprocess.run(['git', 'commit', '-m', msg], check=False)

    finally:
        os.chdir(cwd)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--phone', required=True)
    parser.add_argument('--tablet', required=True)
    args = parser.parse_args()
    android_root = Path(__file__).resolve().parents[2]
    phone_zip = Path(args.phone)
    tablet_zip = Path(args.tablet)

    if not phone_zip.exists():
        fatal(f"Phone zip file not found: {phone_zip}")
    if not tablet_zip.exists():
        fatal(f"Tablet zip file not found: {tablet_zip}")

    phone_base = phone_zip.name.rsplit('-', 1)[0]
    tablet_base = tablet_zip.name.rsplit('-', 1)[0]

    repos = [
        'clocks', 'gms', 'gsans', 'launcher', 'sounds', 'themepicker'
    ]

    for repo in repos:
        run_repo_extract(repo, phone_zip, tablet_zip, phone_base, tablet_base, android_root)


if __name__ == '__main__':
    main()
