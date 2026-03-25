from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class LocalizedText:
    text: str
    zh_cn: str = ""
    en_us: str = ""

    def localized(self, lang: str) -> str:
        if lang == "zh_cn" and self.zh_cn:
            return self.zh_cn
        if lang == "en_us" and self.en_us:
            return self.en_us
        return self.text

    @classmethod
    def from_raw(cls, raw: Any) -> "LocalizedText":
        if isinstance(raw, dict):
            return cls(
                text=str(raw.get("text") or ""),
                zh_cn=str(raw.get("zh_cn") or ""),
                en_us=str(raw.get("en_us") or ""),
            )
        return cls(text=str(raw or ""))


@dataclass
class ManifestCommand:
    id: str
    label: LocalizedText
    command: str

    @classmethod
    def from_raw(cls, raw: dict[str, Any]) -> "ManifestCommand":
        return cls(
            id=str(raw.get("id") or ""),
            label=LocalizedText.from_raw(raw.get("label")),
            command=str(raw.get("command") or ""),
        )


@dataclass
class ManifestOption:
    id: str
    label: LocalizedText
    value: str

    @classmethod
    def from_raw(cls, raw: dict[str, Any]) -> "ManifestOption":
        return cls(
            id=str(raw.get("id") or ""),
            label=LocalizedText.from_raw(raw.get("label")),
            value=str(raw.get("value") or ""),
        )


@dataclass
class ManifestBlock:
    id: str
    type: str
    title: LocalizedText = field(default_factory=lambda: LocalizedText(text=""))
    subtitle: LocalizedText = field(default_factory=lambda: LocalizedText(text=""))
    prompt: LocalizedText = field(default_factory=lambda: LocalizedText(text=""))
    footer: LocalizedText = field(default_factory=lambda: LocalizedText(text=""))
    commands: list[ManifestCommand] = field(default_factory=list)
    options: list[ManifestOption] = field(default_factory=list)
    supports_freeform: bool = False
    context: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_raw(cls, raw: dict[str, Any]) -> "ManifestBlock":
        return cls(
            id=str(raw.get("id") or ""),
            type=str(raw.get("type") or ""),
            title=LocalizedText.from_raw(raw.get("title")),
            subtitle=LocalizedText.from_raw(raw.get("subtitle")),
            prompt=LocalizedText.from_raw(raw.get("prompt")),
            footer=LocalizedText.from_raw(raw.get("footer")),
            commands=[
                ManifestCommand.from_raw(item)
                for item in list(raw.get("commands") or [])
            ],
            options=[
                ManifestOption.from_raw(item)
                for item in list(raw.get("options") or [])
            ],
            supports_freeform=bool(raw.get("supports_freeform")),
            context=dict(raw.get("context") or {}),
        )

    def context_text(self, key: str, fallback: str = "") -> str:
        value = self.context.get(key)
        if isinstance(value, dict):
            return str(value.get("text") or fallback)
        if isinstance(value, str):
            return value
        return fallback

    def context_text_localized(self, key: str, lang: str, fallback: str = "") -> str:
        value = self.context.get(key)
        if isinstance(value, dict):
            if lang == "zh_cn" and value.get("zh_cn"):
                return str(value["zh_cn"])
            if lang == "en_us" and value.get("en_us"):
                return str(value["en_us"])
            return str(value.get("text") or fallback)
        if isinstance(value, str):
            return value
        return fallback


@dataclass
class UXManifest:
    schema_version: str
    manifest_version: str
    flow_id: str
    context: dict[str, Any]
    onboarding: dict[str, Any]
    feedback: dict[str, Any]
    runtime: dict[str, Any]
    background: dict[str, Any]
    controls: dict[str, Any]
    blocks: dict[str, ManifestBlock]
    raw: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_raw(cls, raw: dict[str, Any]) -> "UXManifest":
        return cls(
            schema_version=str(raw.get("schema_version") or ""),
            manifest_version=str(raw.get("manifest_version") or ""),
            flow_id=str(raw.get("flow_id") or ""),
            context=dict(raw.get("context") or {}),
            onboarding=dict(raw.get("onboarding") or {}),
            feedback=dict(raw.get("feedback") or {}),
            runtime=dict(raw.get("runtime") or {}),
            background=dict(raw.get("background") or {}),
            controls=dict(raw.get("controls") or {}),
            blocks={
                key: ManifestBlock.from_raw(value)
                for key, value in dict(raw.get("blocks") or {}).items()
            },
            raw=raw,
        )

    def text(self, section: str, field: str, fallback: str = "") -> str:
        payload = self.raw.get(section) or {}
        value = payload.get(field)
        if isinstance(value, dict):
            return str(value.get("text") or fallback)
        if isinstance(value, str):
            return value
        return fallback

    def text_localized(self, section: str, field: str, lang: str, fallback: str = "") -> str:
        payload = self.raw.get(section) or {}
        value = payload.get(field)
        if isinstance(value, dict):
            if lang == "zh_cn" and value.get("zh_cn"):
                return str(value["zh_cn"])
            if lang == "en_us" and value.get("en_us"):
                return str(value["en_us"])
            return str(value.get("text") or fallback)
        if isinstance(value, str):
            return value
        return fallback

    def block(self, block_id: str) -> ManifestBlock:
        if block_id not in self.blocks:
            raise KeyError(f"missing manifest block: {block_id}")
        return self.blocks[block_id]
