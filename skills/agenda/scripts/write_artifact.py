#!/usr/bin/env python3
"""Write a daily planning artifact to the agenda state directory."""

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo


def main() -> None:
    parser = argparse.ArgumentParser(description="Write daily planning artifact.")
    parser.add_argument("state_dir", help="Path to the agenda state directory")
    parser.add_argument(
        "--timezone",
        default="America/Montreal",
        help="Timezone for the completion timestamp",
    )
    args = parser.parse_args()

    raw = sys.stdin.read().strip()
    if not raw:
        print("Error: no artifact JSON on stdin", file=sys.stderr)
        sys.exit(1)

    try:
        artifact = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"Error: invalid JSON on stdin: {e}", file=sys.stderr)
        sys.exit(1)

    if not isinstance(artifact, dict):
        print("Error: artifact must be a JSON object", file=sys.stderr)
        sys.exit(1)

    now = datetime.now(ZoneInfo(args.timezone))
    artifact["completed_at"] = now.isoformat(timespec="seconds")
    date_str = artifact.get("date") or now.strftime("%Y-%m-%d")
    artifact["date"] = date_str

    state_dir = Path(args.state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    out_path = state_dir / f"{date_str}.json"
    out_path.write_text(json.dumps(artifact, indent=2) + "\n")
    print(json.dumps({"written": str(out_path)}, indent=2))


if __name__ == "__main__":
    main()
