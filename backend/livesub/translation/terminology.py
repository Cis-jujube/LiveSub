"""Small local, reloadable translation glossary. Never changes ASR or stored subtitles."""

from dataclasses import dataclass
import json
import logging
from pathlib import Path
import re
import unicodedata

MAX_FILE_BYTES = 64 * 1024
MAX_ENTRIES = 100
MAX_TERM_CHARACTERS = 80
MAX_GLOSSARY_TOKENS = 384
LOG = logging.getLogger(__name__)


def default_terminology_path() -> Path:
    return Path.home() / "Library/Application Support/LiveSub/terminology.json"


def normalize(text: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", text).casefold().split())


@dataclass(frozen=True, slots=True)
class Entry:
    source_language: str
    source: str
    target: str
    sense: str = ""


# Ambiguous single words are enabled only by domain evidence; custom entries are explicit.
PRESET = (
    Entry("en", "AI agents", "AI Agents"),
    Entry("en", "AI agent", "AI Agent"),
    Entry("en", "agents", "Agents", "agent"),
    Entry("en", "agent", "Agent", "agent"),
    Entry("en", "tokenization", "分词"),
    Entry("en", "tokenizer", "分词器"),
    Entry("en", "tokens", "tokens", "token"),
    Entry("en", "token", "token", "token"),
    Entry("en", "large language model", "大语言模型"),
    Entry("en", "large language models", "大语言模型"),
    Entry("en", "context window", "上下文窗口"),
    Entry("en", "prompt engineering", "提示词工程"),
    Entry("en", "retrieval augmented generation", "检索增强生成"),
    Entry("en", "retrieval-augmented generation", "检索增强生成"),
    Entry("en", "fine-tuning", "微调"),
    Entry("en", "embedding", "嵌入", "token"),
    Entry("zh", "大语言模型", "large language model"),
    Entry("zh", "上下文窗口", "context window"),
    Entry("zh", "提示词工程", "prompt engineering"),
    Entry("zh", "检索增强生成", "retrieval-augmented generation"),
    Entry("zh", "微调", "fine-tuning"),
)
TOKEN_CUES = re.compile(r"\b(?:next|input|output) tokens?\b|\btoken (?:budget|limit|count|prediction)\b", re.I)
LLM_CUES = re.compile(r"\b(?:LLMs?|GPT\w*|Qwen\w*|tokeniz\w*|prompts?|inference|embeddings?)\b|\blanguage models?\b|\bcontext windows?\b|大语言模型|语言模型|上下文窗口|提示词|分词|推理", re.I)
AGENT_CUES = re.compile(r"\b(?:AI|artificial intelligence|software|computational|multi-agent|tool calls?|tool use|autonomous system)\b|智能体|人工智能|工具调用", re.I)
NON_AI_AGENT = re.compile(r"\b(?:real[ -]estate|travel|insurance|secret|literary|sales|customer service|chemical|infectious)\b|房地产|保险|旅行社", re.I)
NON_LLM_TOKEN = re.compile(r"\b(?:authentication|authorization|access|refresh|bearer|security|OAuth|JWT|API|crypto\w*|blockchain|subway|arcade|bus|gratitude|appreciation)\b|身份验证|访问令牌|代币", re.I)


def parse_settings(value: object) -> tuple[str, tuple[Entry, ...]]:
    if not isinstance(value, dict) or type(value.get("version")) is not int or value["version"] != 1:
        raise ValueError("terminology version must be 1")
    profile = value.get("profile")
    entries = value.get("entries")
    if profile not in ("ai", "general") or not isinstance(entries, list) or len(entries) > MAX_ENTRIES:
        raise ValueError("invalid terminology profile or entry count")
    parsed = {}
    for item in entries:
        if not isinstance(item, dict) or item.get("source_language") not in ("en", "zh"):
            raise ValueError("invalid terminology source language")
        source, target = item.get("source"), item.get("target")
        if any(not isinstance(text, str) or not text.strip() or len(text) > MAX_TERM_CHARACTERS
               or any(unicodedata.category(char).startswith("C") for char in text)
               for text in (source, target)):
            raise ValueError("terms must contain 1–80 visible characters")
        entry = Entry(item["source_language"], source.strip(), target.strip())
        parsed[(entry.source_language, normalize(entry.source))] = entry
    return profile, tuple(parsed.values())


class Terminology:
    def __init__(self, path: Path | None = None):
        self.path = path or default_terminology_path()
        self._settings: tuple[str, tuple[Entry, ...]] = ("ai", ())
        self._last_warning: str | None = None

    def load(self) -> tuple[str, tuple[Entry, ...]]:
        try:
            with self.path.open("rb") as stream:
                data = stream.read(MAX_FILE_BYTES + 1)
            if len(data) > MAX_FILE_BYTES:
                raise ValueError("terminology file exceeds 64 KiB")
            self._settings = parse_settings(json.loads(data))
            self._last_warning = None
        except FileNotFoundError:
            self._settings = ("ai", ())
            self._last_warning = None
        except (OSError, UnicodeError, ValueError, RecursionError) as error:
            # Atomic UI writes avoid partial reads; external malformed edits retain last good state.
            warning = type(error).__name__
            if warning != self._last_warning:
                LOG.warning("Could not read terminology settings (%s); using last valid settings", warning)
                self._last_warning = warning
        return self._settings

    def spans(self, language: str, source: str, context_sources: list[str]) -> list[tuple[int, int, Entry]]:
        profile, custom = self.load()
        entries = {(e.source_language, normalize(e.source)): e for e in PRESET} if profile == "ai" else {}
        entries.update({(e.source_language, normalize(e.source)): e for e in custom})
        text, offsets = normalized_offsets(source)
        history = " ".join(context_sources)
        matches = []
        for entry in entries.values():
            if entry.source_language != language:
                continue
            term = normalize(entry.source)
            # ASCII word boundaries allow English terms adjacent to Chinese, but never tokenization/agency.
            left = r"(?<![a-z0-9_])" if term[0].isascii() and term[0].isalnum() else ""
            right = r"(?![a-z0-9_])" if term[-1].isascii() and term[-1].isalnum() else ""
            for match in re.finditer(left + re.escape(term) + right, text):
                # A normalized character may expand to several characters (¼ → 1⁄4),
                # or several source characters may compose (e + accent → é).
                # Never replace only part of that indivisible source span.
                if (
                    match.start() > 0 and offsets[match.start()] == offsets[match.start() - 1]
                    or match.end() < len(offsets) and offsets[match.end() - 1] == offsets[match.end()]
                ):
                    continue
                clause_start = max((text.rfind(mark, 0, match.start()) for mark in ".!?;。！？；"), default=-1) + 1
                ends = [position for mark in ".!?;。！？；" if (position := text.find(mark, match.end())) >= 0]
                clause = text[clause_start:min(ends) if ends else len(text)]
                if entry.sense == "agent":
                    if NON_AI_AGENT.search(clause) or not (AGENT_CUES.search(clause + " " + history) or LLM_CUES.search(clause + " " + history)):
                        continue
                elif entry.sense == "token":
                    if NON_LLM_TOKEN.search(clause) or not (LLM_CUES.search(clause + " " + history) or TOKEN_CUES.search(clause)):
                        continue
                matches.append((match.start(), match.end(), entry))
        occupied = []
        selected = []
        for start, end, entry in sorted(matches, key=lambda item: (-(item[1] - item[0]), item[0])):
            if any(start < other_end and end > other_start for other_start, other_end in occupied):
                continue
            occupied.append((start, end))
            selected.append((offsets[start][0], offsets[end - 1][1], entry))
        return sorted(selected, key=lambda item: item[0])

    def select(self, language: str, source: str, context_sources: list[str]) -> list[dict[str, str]]:
        return list({normalize(entry.source): {"source": entry.source, "target": entry.target}
                     for _, _, entry in self.spans(language, source, context_sources)}.values())


def normalized_offsets(source: str) -> tuple[str, list[tuple[int, int]]]:
    """Normalize complete combining sequences and retain indivisible source spans."""
    clusters: list[tuple[int, int, str]] = []
    for index, char in enumerate(source):
        if clusters:
            start, _, previous = clusters[-1]
            # Marks belong to the preceding sequence. The second check also handles
            # composition without combining marks, such as Hangul Jamo L + V + T.
            if (
                unicodedata.category(char).startswith("M")
                or unicodedata.normalize("NFKC", previous + char)
                != unicodedata.normalize("NFKC", previous) + unicodedata.normalize("NFKC", char)
            ):
                clusters[-1] = (start, index + 1, previous + char)
                continue
        clusters.append((index, index + 1, char))

    chars = []
    offsets = []
    for start, end, cluster in clusters:
        for char in unicodedata.normalize("NFKC", cluster).casefold():
            if char.isspace():
                if not chars:
                    continue
                if chars[-1] == " ":
                    offsets[-1] = (offsets[-1][0], end)
                    continue
                char = " "
            chars.append(char)
            offsets.append((start, end))
    if chars and chars[-1] == " ":
        chars.pop()
        offsets.pop()
    return "".join(chars), offsets


class ProtectedTerms:
    """Restore only verified source-span markers, never words in a free translation."""

    def __init__(self, source: str, spans: list[tuple[int, int, Entry]], context: list[dict]):
        from .base import TranslationError
        self._error = TranslationError
        collision_text = source + json.dumps(context, ensure_ascii=False) + " ".join(e.target for _, _, e in spans)
        number = 0
        while f"__LS{number}_" in collision_text:
            number += 1
        self.prefix = f"__LS{number}_"
        self.literal_markers = set(re.findall(r"__LS[0-9]+_[0-9]+__", source))
        self.replacements = {}
        chunks = []
        previous = 0
        for index, (start, end, entry) in enumerate(spans):
            marker = f"{self.prefix}{index}__"
            chunks.extend((source[previous:start], marker))
            self.replacements[marker] = entry.target
            previous = end
        chunks.append(source[previous:])
        self.source = "".join(chunks)

    def restore(self, output: str) -> str:
        for marker in self.replacements:
            if output.count(marker) != 1:
                raise self._error("translation did not preserve a protected terminology marker exactly once")
        unknown = set(re.findall(r"__LS[0-9]+_[0-9]+__", output)) - self.replacements.keys() - self.literal_markers
        if unknown:
            raise self._error("translation returned an unknown terminology marker")
        cleaned = output
        for marker in self.replacements:
            cleaned = cleaned.replace(marker, "")
        if self.prefix in cleaned:
            raise self._error("translation returned an unknown terminology marker")
        for marker, target in self.replacements.items():
            output = output.replace(marker, target)
        return output
