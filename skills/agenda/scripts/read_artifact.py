#!/usr/bin/env python3
"""Read a daily planning artifact from the agenda state directory.

Default: reads yesterday's artifact. Use --date to read a specific day.
Returns empty JSON object {} if no artifact exists for the requested date.
"""

import argparse
import json
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo


def main() -> None:
    parser = argparse.ArgumentParser(description="Read daily planning artifact.")
    parser.add_argument("state_dir", help="Path to the agenda state directory")
    parser.add_argument(
        "--date",
        help="Date to read (YYYY-MM-DD). Default: yesterday.",
    )
    parser.add_argument(
        "--timezone",
        default="America/Montreal",
        help="Timezone for computing 'yesterday'",
    )
    parser.add_argument(
        "--field",
        help="Print a single top-level field instead of full JSON",
    )
    args = parser.parse_args()

    if args.date:
        date_str = args.date
    else:
        yesterday = datetime.now(ZoneInfo(args.timezone)) - timedelta(days=1)
        date_str = yesterday.strftime("%Y-%m-%d")

    artifact_path = Path(args.state_dir) / f"{date_str}.json"

    if not artifact_path.exists():
        if args.field:
            print("")
        else:
            print(json.dumps({"date": date_str, "found": False}))
        return

    try:
        artifact = json.loads(artifact_path.read_text())
    except (json.JSONDecodeError, OSError):
        if args.field:
            print("")
        else:
            print(json.dumps({"date": date_str, "found": False, "error": "corrupt"}))
        return

    artifact["found"] = True

    if args.field:
        value = artifact.get(args.field)
        if value is None:
            print("")
        elif isinstance(value, (dict, list)):
            print(json.dumps(value, indent=2))
        else:
            print(value)
        return

    print(json.dumps(artifact, indent=2))


if __name__ == "__main__":
    main()
