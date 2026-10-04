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
    Entry("zh", "检索、增强、生成", "retrieval-augmented generation"),
    Entry("zh", "检索，增强，生成", "retrieval-augmented generation"),
    Entry("zh", "微调", "fine-tuning"),
)
DOMAIN_PRESETS = {
    "ai": PRESET,
    "software": (
        Entry("en", "application programming interface", "应用程序编程接口"),
        Entry("en", "API endpoint", "API 端点"),
        Entry("en", "version control", "版本控制"),
        Entry("en", "continuous integration", "持续集成"),
        # Selected titles adapted from CNCF Cloud Native Glossary contributors,
        # documentation CC BY 4.0. Reviewed terms only, no definitions imported.
        # https://creativecommons.org/licenses/by/4.0/
        # https://github.com/cncf/glossary/tree/dea5192058add96711c7cbf874f1a18b2c29acdb/content/zh-cn
        Entry("en", "observability", "可观测性"),
        Entry("en", "container orchestration", "容器编排"),
        Entry("en", "service mesh", "服务网格"),
        Entry("en", "load balancer", "负载均衡器"),
        Entry("en", "event-driven architecture", "事件驱动架构"),
        Entry("en", "idempotence", "幂等性"),
        Entry("en", "continuous delivery", "持续交付"),
        Entry("zh", "版本控制", "version control"),
        Entry("zh", "持续集成", "continuous integration"),
        Entry("zh", "接口端点", "API endpoint"),
    ),
    "data": (
        Entry("en", "confidence interval", "置信区间"),
        Entry("en", "sample size", "样本量"),
        Entry("en", "standard deviation", "标准差"),
        Entry("en", "p-value", "p 值"),
        Entry("zh", "置信区间", "confidence interval"),
        Entry("zh", "样本量", "sample size"),
        Entry("zh", "标准差", "standard deviation"),
        Entry("zh", "机器学习", "machine learning"),
    ),
    "finance": (
        Entry("en", "basis points", "基点"),
        Entry("en", "interest rates", "利率"),
        Entry("en", "cash flow", "现金流"),
        Entry("en", "price-to-earnings ratio", "市盈率"),
        Entry("zh", "市盈率", "price-to-earnings ratio"),
        Entry("zh", "现金流", "cash flow"),
        Entry("zh", "基点", "basis points"),
        Entry("zh", "利率", "interest rate"),
    ),
    "quant": (
        Entry("en", "Sharpe ratio", "夏普比率"),
        Entry("en", "backtesting", "回测"),
        Entry("en", "volatility", "波动率"),
        Entry("en", "risk-adjusted return", "风险调整后收益"),
        Entry("zh", "夏普比率", "Sharpe ratio"),
        Entry("zh", "回测", "backtesting"),
        Entry("zh", "波动率", "volatility"),
        Entry("zh", "风险调整后收益", "risk-adjusted return"),
    ),
    "blockchain": (
        Entry("en", "security token", "证券型代币"),
        Entry("en", "smart contract", "智能合约"),
        Entry("en", "proof of stake", "权益证明"),
        Entry("zh", "证券型代币", "security token"),
        Entry("zh", "智能合约", "smart contract"),
        Entry("zh", "权益证明", "proof of stake"),
    ),
}
TOKEN_CUES = re.compile(r"\b(?:next|input|output) tokens?\b|\btoken (?:budget|limit|count|prediction)\b", re.I)
LLM_CUES = re.compile(r"\b(?:LLMs?|GPT\w*|Qwen\w*|tokeniz\w*|prompts?|inference|embeddings?)\b|\blanguage models?\b|\bcontext windows?\b|大语言模型|语言模型|上下文窗口|提示词|分词|推理", re.I)
AGENT_CUES = re.compile(r"\b(?:AI|artificial intelligence|software|computational|multi-agent|tool calls?|tool use|autonomous system)\b|智能体|人工智能|工具调用", re.I)
NON_AI_AGENT = re.compile(r"\b(?:real[ -]estate|travel|insurance|secret|literary|sales|customer service|chemical|infectious)\b|房地产|保险|旅行社", re.I)
NON_LLM_TOKEN = re.compile(r"\b(?:authentication|authorization|access|refresh|bearer|security|OAuth|JWT|API|crypto\w*|blockchain|subway|arcade|bus|gratitude|appreciation)\b|身份验证|访问令牌|代币", re.I)


def parse_settings(value: object) -> tuple[tuple[str, ...], tuple[Entry, ...]]:
    if not isinstance(value, dict) or type(value.get("version")) is not int or value["version"] not in (1, 2):
        raise ValueError("terminology version must be 1 or 2")
    if value["version"] == 1:
        profile = value.get("profile")
        if profile not in ("ai", "general"):
            raise ValueError("invalid terminology profile")
        domains = ("ai",) if profile == "ai" else ()
    else:
        raw_domains = value.get("domains")
        if (not isinstance(raw_domains, list) or len(raw_domains) > len(DOMAIN_PRESETS)
                or any(not isinstance(domain, str) or domain not in DOMAIN_PRESETS for domain in raw_domains)
                or len(set(raw_domains)) != len(raw_domains)):
            raise ValueError("invalid terminology domains")
        domains = tuple(raw_domains)
    entries = value.get("entries")
    if not isinstance(entries, list) or len(entries) > MAX_ENTRIES:
        raise ValueError("invalid terminology entry count")
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
    return domains, tuple(parsed.values())


class Terminology:
    def __init__(self, path: Path | None = None):
        self.path = path or default_terminology_path()
        self._settings: tuple[tuple[str, ...], tuple[Entry, ...]] = (("ai",), ())
        self._last_warning: str | None = None
        self._file_signature: tuple[int, int, int, int, int] | None = None
        self._matcher_settings = None
        self._matchers: tuple[tuple[Entry, re.Pattern], ...] = ()

    def load(self) -> tuple[tuple[str, ...], tuple[Entry, ...]]:
        try:
            metadata = self.path.stat()
            signature = (metadata.st_dev, metadata.st_ino, metadata.st_size,
                         metadata.st_mtime_ns, metadata.st_ctime_ns)
            if signature == self._file_signature:
                return self._settings
            with self.path.open("rb") as stream:
                data = stream.read(MAX_FILE_BYTES + 1)
            # The UI replaces the file atomically. Cache the signature checked
            # before opening: a concurrent replacement is reread next time.
            self._file_signature = signature
            if len(data) > MAX_FILE_BYTES:
                raise ValueError("terminology file exceeds 64 KiB")
            self._settings = parse_settings(json.loads(data))
            self._last_warning = None
        except FileNotFoundError:
            self._settings = (("ai",), ())
            self._last_warning = None
            self._file_signature = None
        except (OSError, UnicodeError, ValueError, RecursionError) as error:
            # Atomic UI writes avoid partial reads; external malformed edits retain last good state.
            warning = type(error).__name__
            if warning != self._last_warning:
                LOG.warning("Could not read terminology settings (%s); using last valid settings", warning)
                self._last_warning = warning
        return self._settings

    def spans(self, language: str, source: str, context_sources: list[str]) -> list[tuple[int, int, Entry]]:
        settings = self.load()
        if settings != self._matcher_settings:
            domains, custom = settings
            entries = {(e.source_language, normalize(e.source)): e
                       for domain in DOMAIN_PRESETS for e in DOMAIN_PRESETS[domain] if domain in domains}
            entries.update({(e.source_language, normalize(e.source)): e for e in custom})
            matchers = []
            for entry in entries.values():
                term = normalize(entry.source)
                # ASCII word boundaries permit terms adjacent to Chinese while
                # excluding tokenization/agency. Compile once per settings.
                left = r"(?<![a-z0-9_])" if term[0].isascii() and term[0].isalnum() else ""
                right = r"(?![a-z0-9_])" if term[-1].isascii() and term[-1].isalnum() else ""
                matchers.append((entry, re.compile(left + re.escape(term) + right)))
            self._matchers = tuple(matchers)
            self._matcher_settings = settings
        text, offsets = normalized_offsets(source)
        history = " ".join(context_sources)
        matches = []
        for entry, pattern in self._matchers:
            if entry.source_language != language:
                continue
            for match in pattern.finditer(text):
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

    def term_only_output(self) -> str | None:
        """One complete preferred term needs no model to translate surrounding text."""
        if len(self.replacements) != 1:
            return None
        marker = next(iter(self.replacements))
        match = re.fullmatch(re.escape(marker) + r"\s*([.!?。！？]?)", self.source.strip())
        if match is None:
            return None
        return marker + match[1].translate(str.maketrans(".!?", "。！？"))

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
