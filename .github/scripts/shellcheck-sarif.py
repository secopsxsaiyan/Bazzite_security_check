#!/usr/bin/env python3
"""Turn `shellcheck -f json1` output into SARIF 2.1.0 for code scanning.

Usage: shellcheck -f json1 FILES... | shellcheck-sarif.py > shellcheck.sarif

ShellCheck has no SARIF output of its own. The tool name written here,
"ShellCheck", is the one the "Protect main" ruleset waits for.
"""
import json
import sys

LEVELS = {"error": "error", "warning": "warning", "info": "note", "style": "note"}


def main():
    comments = json.load(sys.stdin).get("comments", [])
    rules = {}
    results = []
    for c in comments:
        rule_id = "SC%d" % c["code"]
        rules.setdefault(rule_id, {
            "id": rule_id,
            "shortDescription": {"text": rule_id},
            "helpUri": "https://www.shellcheck.net/wiki/" + rule_id,
        })
        region = {"startLine": c["line"], "startColumn": c["column"]}
        end_line = c.get("endLine", c["line"])
        end_column = c.get("endColumn", c["column"])
        if (end_line, end_column) > (c["line"], c["column"]):
            region["endLine"] = end_line
            region["endColumn"] = end_column
        results.append({
            "ruleId": rule_id,
            "level": LEVELS.get(c.get("level"), "warning"),
            "message": {"text": c["message"]},
            "locations": [{
                "physicalLocation": {
                    "artifactLocation": {"uri": c["file"].removeprefix("./")},
                    "region": region,
                }
            }],
        })
    sarif = {
        "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
        "version": "2.1.0",
        "runs": [{
            "tool": {"driver": {
                "name": "ShellCheck",
                "informationUri": "https://www.shellcheck.net",
                "rules": sorted(rules.values(), key=lambda r: r["id"]),
            }},
            "results": results,
        }],
    }
    json.dump(sarif, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
