#!/usr/bin/env python3
"""Rewrite OpenAI-style `response_format` to a llama_cpp.server-compatible body.

`llama_cpp.server`'s pydantic schema only accepts `response_format.type` of
`text` or `json_object`. The newer OpenAI spec adds `json_schema` with a
strict JSON Schema. We translate that into a GBNF grammar (via the vendored
`json_schema_to_grammar.py`) and pass it through as the `grammar` field,
which `llama_cpp.server` accepts and enforces at the token-decoding level —
a stricter guarantee than post-hoc compliance.

The rewriter is intentionally silent on success (returns a new body) and on
soft failure (returns the original body and a warning string). It NEVER
raises: a malformed schema must not 500 the proxy; let the upstream return
its own error if any.
"""
from __future__ import annotations

import logging
from typing import Any, Dict, Tuple

try:
    # Package-style import (proxy is run as `runtime.auth_proxy:app` in some setups)
    from .json_schema_to_grammar import SchemaConverter
except ImportError:  # pragma: no cover - direct-script fallback
    from json_schema_to_grammar import SchemaConverter


_logger = logging.getLogger("llamaserve.response_format")


def compile_schema(schema: Dict[str, Any]) -> str:
    """Convert a JSON Schema dict to a GBNF grammar string."""
    converter = SchemaConverter(
        prop_order={},
        allow_fetch=False,
        dotall=False,
        raw_pattern=False,
    )
    resolved = converter.resolve_refs(schema, "inline")
    converter.visit(resolved, "")
    return converter.format_grammar()


def rewrite_body_for_json_schema(payload: Dict[str, Any]) -> Tuple[Dict[str, Any], str]:
    """Return (new_payload, note). `note` is empty on success; non-empty
    string on no-op/failure, suitable for logging.

    Does NOT mutate the caller's dict.
    """
    response_format = payload.get("response_format")
    if not isinstance(response_format, dict):
        return payload, ""
    if response_format.get("type") != "json_schema":
        return payload, ""

    spec = response_format.get("json_schema")
    if not isinstance(spec, dict):
        return payload, "json_schema response_format missing 'json_schema' object"

    schema = spec.get("schema")
    if not isinstance(schema, dict):
        return payload, "json_schema response_format missing 'schema'"

    try:
        grammar = compile_schema(schema)
    except Exception as exc:  # noqa: BLE001 — converter raises many types
        _logger.warning("json_schema → grammar conversion failed: %s", exc)
        return payload, f"conversion failed: {exc}"

    # Build a new body so the caller can re-encode it. Preserve any
    # existing `grammar` the caller already set (rare; honour it).
    new_payload = dict(payload)
    if "grammar" not in new_payload or not new_payload.get("grammar"):
        new_payload["grammar"] = grammar
    # Replace response_format with json_object so llama_cpp.server's
    # pydantic literal accepts it. The actual structural enforcement is
    # done by `grammar` at the token level.
    new_payload["response_format"] = {"type": "json_object"}
    return new_payload, ""
