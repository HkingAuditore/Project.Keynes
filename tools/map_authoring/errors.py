"""Structured authoring / compile failures."""

from __future__ import annotations


class AuthoringError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message

    def as_dict(self) -> dict:
        return {"ok": False, "code": self.code, "message": self.message}
