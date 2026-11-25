#!/usr/bin/env python3
"""Shared GitHub REST client for the apk-bump workflow jobs' heredoc scripts.

Both jobs of `.github/workflows/apk-bump.yaml` talk to the GitHub API – PR/file reads in both, the
rebase-comment post in the nudge job – and this module is their single copy of the request plumbing
(the same dedupe rationale as the pin parser, `apk_pins.py`). Heredoc scripts import it via a
runtime sys.path insert of `.github/scripts`, like `apk_pins`.
"""

from __future__ import annotations

import base64
import json
import os
import urllib.parse
import urllib.request
from typing import Any

# The REST API root – path arguments are repo-relative and joined under /repos/<repo>/ below.
API = "https://api.github.com"


class GhApi:
    """Minimal authenticated GitHub REST client over repo-relative paths.

    Reads `GH_TOKEN` and `GITHUB_REPOSITORY` from the environment (both jobs export them) and sends
    `user_agent` as the User-Agent so abuse reports stay attributable per job.
    """

    def __init__(self, user_agent: str) -> None:
        """Read the token and repository from the environment and fix the request headers."""
        self._repo = os.environ["GITHUB_REPOSITORY"]
        self._headers = {
            "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
            "Accept": "application/vnd.github+json",
            "User-Agent": user_agent,
        }

    def api(self, path: str, params: dict[str, str | int] | None = None) -> Any:  # noqa: ANN401 – dynamic JSON shape
        """GET one repo-relative path; `params` become the query string."""
        url = f"{API}/repos/{self._repo}/{path}"
        if params:
            url += "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, headers=self._headers)  # noqa: S310 – fixed https api.github.com root
        with urllib.request.urlopen(req, timeout=60) as resp:  # noqa: S310 – fixed https api.github.com root
            return json.load(resp)

    def api_list(self, path: str, params: dict[str, str | int]) -> list[Any]:
        """GET all pages of a paginated repo-relative path."""
        out: list[Any] = []
        page = 1
        while True:
            batch = self.api(path, {**params, "per_page": 100, "page": page})
            out.extend(batch)
            if len(batch) < 100:
                return out
            page += 1

    def contents(self, path: str, ref: str) -> str:
        """A file's text content at `ref`, via the contents API (base64-decoded)."""
        data = self.api(f"contents/{path}", {"ref": ref})
        return base64.b64decode(data["content"]).decode()

    def post(self, path: str, body: dict[str, str]) -> None:
        """POST a JSON body to a repo-relative path; the response body is discarded."""
        req = urllib.request.Request(  # noqa: S310 – fixed https api.github.com root
            f"{API}/repos/{self._repo}/{path}",
            data=json.dumps(body).encode(),
            headers={**self._headers, "Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=60) as resp:  # noqa: S310 – fixed https api.github.com root
            resp.read()
