#!/usr/bin/env python3
import json
import re
from typing import Any, Callable, Dict, List, Optional, Tuple


_TOOL_TARGET_RE = re.compile(r"to=functions\.([A-Za-z0-9_.-]+)")
_MESSAGE_TAG = "<|message|>"


def _decode_json_arguments(content: str, start_index: int) -> Optional[Tuple[str, int]]:
    candidate = content[start_index:].lstrip()
    if not candidate:
        return None

    consumed_ws = len(content[start_index:]) - len(candidate)
    try:
        parsed, end_index = json.JSONDecoder().raw_decode(candidate)
    except json.JSONDecodeError:
        return None

    if not isinstance(parsed, dict):
        return None

    normalized = json.dumps(parsed, separators=(",", ":"))
    return normalized, start_index + consumed_ws + end_index


def parse_channel_tag_tools(content: str, allowed_tool_names: List[str]) -> Optional[List[Dict[str, str]]]:
    if not content or not allowed_tool_names:
        return None

    parsed_calls: List[Dict[str, str]] = []
    for match in _TOOL_TARGET_RE.finditer(content):
        tool_name = match.group(1)
        if tool_name not in allowed_tool_names:
            continue

        message_index = content.find(_MESSAGE_TAG, match.end())
        if message_index == -1:
            continue

        parsed = _decode_json_arguments(content, message_index + len(_MESSAGE_TAG))
        if parsed is None:
            continue

        arguments, _ = parsed
        parsed_calls.append({"name": tool_name, "arguments": arguments})

    if not parsed_calls:
        return None
    return parsed_calls


def _no_op_parser(content: str, allowed_tool_names: List[str]) -> Optional[List[Dict[str, str]]]:
    return None


PARSER_REGISTRY: Dict[str, Callable[[str, List[str]], Optional[List[Dict[str, str]]]]] = {
    "none": _no_op_parser,
    "channel-tag-tools": parse_channel_tag_tools,
    "commentary-to-functions": parse_channel_tag_tools,
}


def normalize_chat_completion(
    request_payload: Dict[str, Any],
    response_payload: Dict[str, Any],
    parser_name: str,
) -> Tuple[Dict[str, Any], bool]:
    parser = PARSER_REGISTRY.get(parser_name or "none")
    if parser is None:
        return response_payload, False

    allowed_tool_names = [
        tool["function"]["name"]
        for tool in request_payload.get("tools", [])
        if isinstance(tool, dict)
        and tool.get("type") == "function"
        and isinstance(tool.get("function"), dict)
        and isinstance(tool["function"].get("name"), str)
    ]
    if not allowed_tool_names:
        return response_payload, False

    choices = response_payload.get("choices")
    if not isinstance(choices, list):
        return response_payload, False

    changed = False
    for choice in choices:
        if not isinstance(choice, dict):
            continue
        message = choice.get("message")
        if not isinstance(message, dict):
            continue
        if message.get("tool_calls") or message.get("function_call"):
            continue
        content = message.get("content")
        if not isinstance(content, str) or not content.strip():
            continue

        parsed_calls = parser(content, allowed_tool_names)
        if not parsed_calls:
            continue

        tool_calls = []
        for idx, parsed_call in enumerate(parsed_calls):
            tool_calls.append(
                {
                    "id": f"call_{idx}_{parsed_call['name']}",
                    "type": "function",
                    "function": {
                        "name": parsed_call["name"],
                        "arguments": parsed_call["arguments"],
                    },
                }
            )

        message["content"] = None
        message["tool_calls"] = tool_calls
        if len(tool_calls) == 1:
            message["function_call"] = {
                "name": tool_calls[0]["function"]["name"],
                "arguments": tool_calls[0]["function"]["arguments"],
            }
        choice["finish_reason"] = "tool_calls"
        changed = True

    return response_payload, changed
