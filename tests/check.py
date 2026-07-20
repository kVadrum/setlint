#!/usr/bin/env python3
"""Assertion evaluator for the settingslint test harness.

Reads a `settingslint --json` payload on stdin and an `expected.txt` path as
argv[1]. Prints one line per failed assertion and exits nonzero if any failed,
so the bash harness can report the fixture as failing. A separate file rather
than an inline heredoc for the same reason weave uses one: `python3 - <<EOF`
would consume the heredoc as the program and leave json.load with no stdin.

Assertion grammar (one `key=value` per line; blank lines and `#` comments
ignored):
  errors / warnings              summary counts
  findings                       total number of findings
  has.<check>=1                  at least one finding with that check name
  absent.<check>=1               no finding with that check name
  count.<check>=<n>              exactly n findings with that check name
  level.<check>=error|warn       the level of the first finding with that check
"""

import json
import sys


def main() -> int:
    data = json.load(sys.stdin)
    findings = data["findings"]
    summary = data["summary"]

    def check_names():
        return [f["check"] for f in findings]

    fails = 0
    with open(sys.argv[1], encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            key, _, want = line.partition("=")
            key, want = key.strip(), want.strip()

            if key in ("errors", "warnings"):
                got = summary[key]
            elif key == "findings":
                got = len(findings)
            elif key.startswith("has."):
                name = key[len("has."):]
                got = "1" if name in check_names() else "0"
            elif key.startswith("absent."):
                name = key[len("absent."):]
                got = "1" if name not in check_names() else "0"
            elif key.startswith("count."):
                name = key[len("count."):]
                got = sum(1 for c in check_names() if c == name)
            elif key.startswith("level."):
                name = key[len("level."):]
                got = next((f["level"] for f in findings if f["check"] == name), "<absent>")
            else:
                print(f"{key}: unknown assertion key")
                fails += 1
                continue

            if str(got) != want:
                print(f"{key}: got {got!r} want {want!r}")
                fails += 1

    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
