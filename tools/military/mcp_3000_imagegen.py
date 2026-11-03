#!/usr/bin/env python3
"""Call the optional 3000 MCP image service without persisting its token.

The token is read from MCP3000_TOKEN. This helper only brokers upload,
generation, polling and download; image content is always model-generated.
"""

from __future__ import annotations

import argparse
import base64
import json
import mimetypes
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


DEFAULT_ENDPOINT = "https://3000.mcp.it.woa.com"
DEFAULT_APP_ID = "383"
PROTOCOL_VERSION = "2025-06-18"


class McpError(RuntimeError):
    """Raised when the MCP service returns an invalid or failed response."""


class McpClient:
    def __init__(self, endpoint: str, token: str) -> None:
        self.endpoint = endpoint
        self.token = token
        self.session_id = ""
        self._next_id = 1

    def _post(self, payload: dict[str, Any]) -> tuple[str, dict[str, str]]:
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/json, text/event-stream",
            "Content-Type": "application/json",
        }
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id
        request = urllib.request.Request(
            self.endpoint,
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                body = response.read().decode("utf-8")
                response_headers = {
                    key.lower(): value for key, value in response.headers.items()
                }
                if not self.session_id:
                    self.session_id = response_headers.get("mcp-session-id", "")
                return body, response_headers
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise McpError(f"HTTP {exc.code}: {detail}") from exc
        except urllib.error.URLError as exc:
            raise McpError(f"MCP connection failed: {exc}") from exc

    def initialize(self) -> None:
        payload = {
            "jsonrpc": "2.0",
            "id": self._next_id,
            "method": "initialize",
            "params": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "project-keynes-tools", "version": "1.0"},
            },
        }
        self._next_id += 1
        body, _headers = self._post(payload)
        parsed = json.loads(body)
        if "error" in parsed:
            raise McpError(f"initialize failed: {parsed['error']}")
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def call_tool(self, name: str, arguments: dict[str, Any]) -> Any:
        payload = {
            "jsonrpc": "2.0",
            "id": self._next_id,
            "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        }
        self._next_id += 1
        body, _headers = self._post(payload)
        parsed = json.loads(body)
        if "error" in parsed:
            raise McpError(f"{name} failed: {parsed['error']}")
        result = parsed.get("result", {})
        if bool(result.get("isError", False)):
            raise McpError(f"{name} returned isError=true: {result}")
        content = result.get("content", [])
        texts = [
            str(item.get("text", ""))
            for item in content
            if isinstance(item, dict) and item.get("type") == "text"
        ]
        text = "\n".join(texts).strip()
        if not text:
            return result
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return text


def _token() -> str:
    token = os.environ.get("MCP3000_TOKEN", "").strip()
    if not token:
        raise McpError("MCP3000_TOKEN is not set")
    return token


def _upload_reference(
    client: McpClient,
    app_id: str,
    reference: Path,
) -> str:
    payload = client.call_tool("3000_get_upload_token", {"app_id": int(app_id)})
    upload_url = ""
    token = ""
    if isinstance(payload, dict):
        data = payload.get("data", payload)
        upload_url = str(data.get("upload_url", "")).strip()
        token = str(data.get("token", "")).strip()
    elif isinstance(payload, str):
        for line in payload.splitlines():
            if line.startswith("upload_url:"):
                upload_url = line.split(":", 1)[1].strip()
            elif line.startswith("token"):
                _label, separator, value = line.partition(":")
                if separator:
                    token = value.strip()
    if not upload_url or not token:
        raise McpError(f"upload-token response lacks url/token: {payload!r}")
    mime = mimetypes.guess_type(reference.name)[0] or "application/octet-stream"
    encoded = base64.b64encode(reference.read_bytes()).decode("ascii")
    upload_body = {
        "token": token,
        "image": f"data:{mime};base64,{encoded}",
    }
    request = urllib.request.Request(
        upload_url,
        data=json.dumps(upload_body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            uploaded = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise McpError(f"reference upload HTTP {exc.code}: {detail}") from exc
    inner_url = str(uploaded.get("data", {}).get("inner_url", "")).strip()
    if int(uploaded.get("ret", 0)) != 1 or not inner_url:
        raise McpError(f"reference upload failed: {uploaded!r}")
    return inner_url


def _submit(
    client: McpClient,
    args: argparse.Namespace,
    prompt: str,
) -> dict[str, Any]:
    image_urls: list[str] = []
    for reference in args.reference:
        image_urls.append(
            _upload_reference(client, args.app_id, reference.resolve())
        )
    generation_args: dict[str, Any] = {
        "app_id": args.app_id,
        "prompt": prompt,
        "model_name": args.model,
        "image_size": args.image_size,
        "quality": args.quality,
        "background": args.background,
        "size": args.size,
        "image": image_urls,
        "batch_size": args.batch_size,
    }
    response = client.call_tool("3000_generate_image", generation_args)
    return {
        "references": [
            str(reference.resolve())
            for reference in args.reference
        ],
        "response": response,
    }


def _query(
    client: McpClient,
    app_id: str,
    trigger_id: str,
) -> Any:
    return client.call_tool(
        "3000_query_generate_async_task_result",
        {"app_id": app_id, "trigger_id": trigger_id},
    )


def _status_text(response: Any) -> str:
    if isinstance(response, dict):
        status = response.get("status")
        if status is None:
            data = response.get("data")
            if isinstance(data, dict):
                status = data.get("status")
        return str(status or "").lower()
    return str(response).lower()


def _extract_urls(value: Any) -> list[str]:
    urls: list[str] = []

    def visit(node: Any) -> None:
        if isinstance(node, str):
            if node.startswith(("http://", "https://")):
                urls.append(node)
            return
        if isinstance(node, list):
            for item in node:
                visit(item)
            return
        if isinstance(node, dict):
            for item in node.values():
                visit(item)

    visit(value)
    unique: list[str] = []
    for url in urls:
        if url not in unique:
            unique.append(url)
    return unique


def _download(url: str, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url, timeout=180) as response:
        destination.write_bytes(response.read())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", default=DEFAULT_ENDPOINT)
    parser.add_argument("--app-id", default=DEFAULT_APP_ID)
    parser.add_argument("--model", default="gpt-image-2.5-sunburst")
    parser.add_argument("--image-size", default="2K")
    parser.add_argument("--size", default="1792x896")
    parser.add_argument("--quality", default="max")
    parser.add_argument("--background", default="transparent")
    parser.add_argument("--batch-size", type=int, default=1)
    parser.add_argument(
        "--reference",
        type=Path,
        action="append",
        default=[],
        help="Repeat to upload multiple ordered reference images (A, B, ...).",
    )
    parser.add_argument("--prompt-file", type=Path)
    parser.add_argument("--trigger-id", default="")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--prefix", default="image")
    parser.add_argument("--poll-seconds", type=int, default=300)
    args = parser.parse_args()

    client = McpClient(args.endpoint, _token())
    client.initialize()
    trigger_id = args.trigger_id.strip()
    response: Any = None
    if not trigger_id:
        if args.prompt_file is None:
            raise McpError("--prompt-file is required when submitting a new job")
        prompt = args.prompt_file.read_text(encoding="utf-8")
        submitted = _submit(client, args, prompt)
        response = submitted["response"]
        if isinstance(response, dict):
            trigger_id = str(response.get("trigger_id", ""))
            data = response.get("data")
            if not trigger_id and isinstance(data, dict):
                trigger_id = str(data.get("trigger_id", ""))
            trigger_data = response.get("trigger_data")
            if not trigger_id and isinstance(trigger_data, dict):
                trigger_id = str(trigger_data.get("trigger_id", ""))
    if not trigger_id:
        raise McpError(f"generation response lacks trigger_id: {response!r}")
    print(
        json.dumps(
            {
                "trigger_id": trigger_id,
                "references": [
                    str(reference.resolve())
                    for reference in args.reference
                ],
                "model": args.model,
                "quality": args.quality,
            },
            ensure_ascii=False,
        ),
        flush=True,
    )

    deadline = time.monotonic() + args.poll_seconds
    delay = 10
    final_response: Any = response
    while time.monotonic() < deadline:
        time.sleep(delay)
        final_response = _query(client, args.app_id, trigger_id)
        status = _status_text(final_response)
        print(
            json.dumps(
                {"trigger_id": trigger_id, "status": status},
                ensure_ascii=False,
            ),
            flush=True,
        )
        if status not in {"pending", "processing", "running", "queued", "submitted"}:
            break
        delay = min(80, delay * 2)
    else:
        raise McpError(f"generation timed out after {args.poll_seconds}s")

    print(json.dumps(final_response, ensure_ascii=False, indent=2))
    if args.output_dir:
        urls = _extract_urls(final_response)
        for index, url in enumerate(urls):
            suffix = Path(urllib.parse.urlparse(url).path).suffix or ".png"
            destination = args.output_dir / f"{args.prefix}_{index:02d}{suffix}"
            _download(url, destination)
            print(f"downloaded {destination}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except McpError as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
