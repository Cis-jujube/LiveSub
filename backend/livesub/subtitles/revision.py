"""Revision rules that keep each translation tied to its source snapshot."""

from dataclasses import dataclass, field


@dataclass(slots=True)
class SegmentRevisionState:
    source_text: str = ""
    source_revision: int = 0
    source_final: bool = False
    translated_source_text: str = ""
    translated_source_revision: int = 0
    target_text: str = ""
    translation_state: str = "pending"
    source_snapshots: dict[int, str] = field(default_factory=dict)

    def skip_translation(self) -> None:
        self.translated_source_text = ""
        self.translated_source_revision = 0
        self.target_text = ""
        self.translation_state = "skipped"

    def request_translation(self) -> None:
        if self.translation_state == "skipped":
            self.translation_state = "pending"

    def apply_source(self, revision: int, text: str, *, final: bool) -> bool:
        if self.source_final or revision <= self.source_revision or not text.strip():
            return False
        self.source_revision = revision
        self.source_text = text
        self.source_final = final
        if final:
            # Older previews cannot be accepted after the source is final.
            self.source_snapshots = {revision: text}
        else:
            self.source_snapshots[revision] = text
        return True

    def apply_translation(
        self,
        *,
        source_revision: int,
        translated_source_text: str,
        target_text: str,
        translation_state: str,
    ) -> bool:
        if translation_state not in {"preview", "final", "failed"}:
            return False
        if source_revision > self.source_revision or source_revision <= 0:
            return False
        if self.source_snapshots.get(source_revision) != translated_source_text:
            return False
        if source_revision < self.translated_source_revision:
            return False
        if self.source_final and translation_state == "preview" and source_revision < self.source_revision:
            return False
        if translation_state == "final" and (not self.source_final or source_revision != self.source_revision):
            return False
        if self.translation_state == "final":
            return False
        if source_revision == self.translated_source_revision:
            if self.translation_state != "preview" or translation_state == "preview":
                return False
        self.translated_source_revision = source_revision
        self.translated_source_text = translated_source_text
        self.target_text = target_text
        self.translation_state = translation_state
        return True
