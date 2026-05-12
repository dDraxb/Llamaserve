#!/usr/bin/env python3
"""Stand-alone unit checks for response_format_rewriter.

Run from the repo root:
    runtime/.venv/bin/python bin/test_response_format_rewriter.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from response_format_rewriter import compile_schema, rewrite_body_for_json_schema  # noqa: E402


def assert_eq(label: str, actual, expected) -> None:
    if actual != expected:
        print(f"FAIL {label}: expected {expected!r}, got {actual!r}", file=sys.stderr)
        sys.exit(1)
    print(f"ok   {label}")


def assert_contains(label: str, haystack: str, needle: str) -> None:
    if needle not in haystack:
        print(f"FAIL {label}: {needle!r} not in {haystack[:120]!r}...", file=sys.stderr)
        sys.exit(1)
    print(f"ok   {label}")


SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["name", "params", "body"],
    "properties": {
        "name": {"type": "string"},
        "params": {"type": "array", "items": {"type": "string"}},
        "body": {"type": "string"},
    },
}


def test_compile_emits_root_rule() -> None:
    g = compile_schema(SCHEMA)
    assert_contains("compile: has root", g, "root ::=")
    assert_contains("compile: has body-kv", g, "body-kv")
    assert_contains("compile: has params", g, "params")


def test_passthrough_when_not_json_schema() -> None:
    payload = {"model": "x", "response_format": {"type": "json_object"}}
    new, note = rewrite_body_for_json_schema(payload)
    assert_eq("passthrough: note empty", note, "")
    assert_eq("passthrough: dict identity preserved", new is payload, True)


def test_passthrough_when_no_response_format() -> None:
    payload = {"model": "x"}
    new, note = rewrite_body_for_json_schema(payload)
    assert_eq("no-rf: note empty", note, "")
    assert_eq("no-rf: dict identity preserved", new is payload, True)


def test_rewrite_drops_response_format_and_adds_grammar() -> None:
    payload = {
        "model": "x",
        "response_format": {
            "type": "json_schema",
            "json_schema": {"name": "Spec", "strict": True, "schema": SCHEMA},
        },
    }
    new, note = rewrite_body_for_json_schema(payload)
    assert_eq("rewrite: note empty", note, "")
    assert_eq("rewrite: new dict is different object", new is payload, False)
    assert_eq(
        "rewrite: original unchanged",
        payload["response_format"]["type"],
        "json_schema",
    )
    assert_eq("rewrite: response_format removed", "response_format" in new, False)
    assert_contains("rewrite: grammar present", new["grammar"], "root ::=")


def test_existing_grammar_is_preserved() -> None:
    payload = {
        "model": "x",
        "grammar": "root ::= \"hello\"",
        "response_format": {
            "type": "json_schema",
            "json_schema": {"schema": SCHEMA},
        },
    }
    new, note = rewrite_body_for_json_schema(payload)
    assert_eq("preserve: grammar untouched", new["grammar"], "root ::= \"hello\"")
    assert_eq("preserve: response_format removed", "response_format" in new, False)


def test_missing_schema_is_soft_failure() -> None:
    payload = {
        "model": "x",
        "response_format": {"type": "json_schema", "json_schema": {"name": "x"}},
    }
    new, note = rewrite_body_for_json_schema(payload)
    assert_eq("soft-fail: returns original", new is payload, True)
    if not note:
        print("FAIL soft-fail: expected non-empty note", file=sys.stderr)
        sys.exit(1)
    print(f"ok   soft-fail: note = {note!r}")


def test_invalid_schema_does_not_raise() -> None:
    payload = {
        "model": "x",
        "response_format": {
            "type": "json_schema",
            "json_schema": {"schema": {"type": "not_a_real_type"}},
        },
    }
    # Must not raise. May produce a grammar that errors at runtime, or soft-fail.
    new, note = rewrite_body_for_json_schema(payload)
    # Either path is acceptable; we just verify no exception escaped.
    print(f"ok   no-raise: new_response_format={new.get('response_format')} note={note!r}")


if __name__ == "__main__":
    test_compile_emits_root_rule()
    test_passthrough_when_not_json_schema()
    test_passthrough_when_no_response_format()
    test_rewrite_drops_response_format_and_adds_grammar()
    test_existing_grammar_is_preserved()
    test_missing_schema_is_soft_failure()
    test_invalid_schema_does_not_raise()
    print("all rewriter checks passed.")
