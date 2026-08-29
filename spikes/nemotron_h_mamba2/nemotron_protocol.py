from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from transformers import AutoTokenizer


def load_tokenizer(checkpoint: Path):
    return AutoTokenizer.from_pretrained(checkpoint)


def render_chat(
    checkpoint: Path,
    messages: list[dict[str, Any]],
    *,
    tools: list[dict[str, Any]] | None = None,
    reasoning: bool = True,
) -> str:
    tokenizer = load_tokenizer(checkpoint)
    return tokenizer.apply_chat_template(
        messages,
        tools=tools,
        tokenize=False,
        enable_thinking=reasoning,
        add_generation_prompt=True,
    )


@dataclass
class ReasoningStreamParser:
    """Incrementally separates the checkpoint's <think> trace from final output."""

    reasoning_enabled: bool = True
    buffer: str = ""
    in_reasoning: bool = False
    reasoning: str = ""
    response: str = ""

    def feed(self, text: str) -> tuple[str, str]:
        self.buffer += text
        while self.buffer:
            if not self.reasoning_enabled:
                if self.buffer.startswith("<think></think>"):
                    self.buffer = self.buffer[len("<think></think>") :]
                    continue
                self.response += self.buffer
                self.buffer = ""
                break
            marker = "</think>" if self.in_reasoning else "<think>"
            index = self.buffer.find(marker)
            if index < 0:
                keep = max(len(marker) - 1, 0)
                emit_length = max(len(self.buffer) - keep, 0)
                emitted, self.buffer = self.buffer[:emit_length], self.buffer[emit_length:]
                if self.in_reasoning:
                    self.reasoning += emitted
                else:
                    self.response += emitted
                break
            emitted, self.buffer = self.buffer[:index], self.buffer[index + len(marker) :]
            if self.in_reasoning:
                self.reasoning += emitted
            else:
                self.response += emitted
            self.in_reasoning = not self.in_reasoning
        return self.reasoning, self.response

    def finish(self) -> tuple[str, str]:
        if self.in_reasoning:
            self.reasoning += self.buffer
        else:
            self.response += self.buffer
        self.buffer = ""
        return self.reasoning, self.response


@dataclass(frozen=True)
class ToolCall:
    name: str
    arguments: dict[str, str] = field(default_factory=dict)


_TOOL = re.compile(r"<tool_call>\s*<function=([^>]+)>(.*?)</function>\s*</tool_call>", re.S)
_PARAMETER = re.compile(r"<parameter=([^>]+)>\s*(.*?)\s*</parameter>", re.S)


def parse_tool_calls(text: str) -> list[ToolCall]:
    return [
        ToolCall(name=name.strip(), arguments={key.strip(): value for key, value in _PARAMETER.findall(body)})
        for name, body in _TOOL.findall(text)
    ]
