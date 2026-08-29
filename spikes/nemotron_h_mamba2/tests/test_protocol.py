from pathlib import Path

import pytest

from nemotron_protocol import ReasoningStreamParser, parse_tool_calls, render_chat


CHECKPOINT = Path(".build/checkpoints/NVIDIA-Nemotron-3-Nano-4B-BF16")


def test_reasoning_parser_streams_split_markers() -> None:
    parser = ReasoningStreamParser()
    for chunk in ("<thi", "nk>plan", " first</thi", "nk>answer"):
        parser.feed(chunk)
    reasoning, response = parser.finish()
    assert reasoning == "plan first"
    assert response == "answer"


def test_reasoning_off_discards_empty_trace_marker() -> None:
    parser = ReasoningStreamParser(reasoning_enabled=False)
    parser.feed("<think></think>Hello")
    assert parser.finish() == ("", "Hello")


def test_tool_call_parser_handles_multiline_parameters() -> None:
    calls = parse_tool_calls(
        "<tool_call>\n<function=searchWeb>\n<parameter=query>\nApple\nCore AI"
        "\n</parameter>\n</function>\n</tool_call>"
    )
    assert calls[0].name == "searchWeb"
    assert calls[0].arguments == {"query": "Apple\nCore AI"}


def test_checkpoint_template_controls_reasoning_and_renders_tools() -> None:
    if not CHECKPOINT.exists():
        pytest.skip(f"pinned checkpoint is not available at {CHECKPOINT}")
    messages = [{"role": "user", "content": "Find current Core AI news"}]
    tool = {
        "type": "function",
        "function": {
            "name": "searchWeb",
            "description": "Search the web",
            "parameters": {
                "type": "object",
                "properties": {"query": {"type": "string"}},
                "required": ["query"],
            },
        },
    }
    thinking = render_chat(CHECKPOINT, messages, tools=[tool], reasoning=True)
    direct = render_chat(CHECKPOINT, messages, tools=[tool], reasoning=False)
    assert "<function>\n<name>searchWeb</name>" in thinking
    assert thinking.endswith("<|im_start|>assistant\n<think>\n")
    assert direct.endswith("<|im_start|>assistant\n<think></think>")
