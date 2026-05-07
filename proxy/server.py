"""Thin proxy between Anthropic SDK clients and Kie.ai.

Kie.ai is almost a drop-in Anthropic clone: it accepts the same request
format and returns real Anthropic-shaped responses (including streaming
SSE with `toolu_` ids and `input_json_delta` events). So this proxy does
only what's actually broken:

  1. Remap models whose names Kie doesn't recognize (date-suffixed,
     "-4-6" aliases).
  2. Convert Kie's occasional "200 OK with error body" quirk into a
     real HTTP error for the client.
  3. Expose an OpenAI-compatible `/chat/completions` for clients that
     speak OpenAI instead of Anthropic (e.g. OpenClaw's custom provider).

Streaming is forwarded byte-for-byte — no reassembly or SSE rebuilding.

Usage:
    python server.py
    ANTHROPIC_BASE_URL=http://localhost:4100  # point your client here
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import uuid
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from typing import Any, AsyncIterator

import httpx
import uvicorn
from dotenv import load_dotenv
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse, StreamingResponse

# ──────────────────────────────────────────────────────────────────────
# Config
# ──────────────────────────────────────────────────────────────────────

load_dotenv()

KIE_BASE_URL = os.getenv("KIE_BASE_URL", "https://api.kie.ai/claude").rstrip("/")
KIE_MESSAGES_URL = f"{KIE_BASE_URL}/v1/messages"
PROXY_PORT = int(os.getenv("PROXY_PORT", "4100"))
UPSTREAM_TIMEOUT = float(os.getenv("UPSTREAM_TIMEOUT", "120"))
DEFAULT_MAX_TOKENS = int(os.getenv("DEFAULT_MAX_TOKENS", "4096"))

# Kie rejects Anthropic's date-suffixed names and some `-4-6` aliases.
MODEL_MAP: dict[str, str] = {
    "claude-sonnet-4-20250514": "claude-sonnet-4-5",
    "claude-opus-4-20250514":   "claude-opus-4-1",
    "claude-haiku-4-20250514":  "claude-haiku-4-5",
    "claude-sonnet-4-6":        "claude-sonnet-4-5",
    "claude-opus-4-6":          "claude-opus-4-1",
    "claude-haiku-4-6":         "claude-haiku-4-5",
}

# Kie error codes that indicate quota/rate issues → surface as HTTP 429
KIE_RATE_LIMIT_CODES = {429, 433}

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s — %(message)s",
)
log = logging.getLogger("proxy")


def map_model(name: str | None) -> str | None:
    return MODEL_MAP.get(name, name) if name else name


# ──────────────────────────────────────────────────────────────────────
# Shared HTTP client + stats
# ──────────────────────────────────────────────────────────────────────

@dataclass
class Stats:
    requests: int = 0
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    async def bump(self) -> int:
        async with self.lock:
            self.requests += 1
            return self.requests


stats = Stats()
_client: httpx.AsyncClient | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _client
    _client = httpx.AsyncClient(timeout=UPSTREAM_TIMEOUT)
    log.info("Proxy up — upstream=%s port=%d", KIE_BASE_URL, PROXY_PORT)
    try:
        yield
    finally:
        await _client.aclose()
        _client = None


def http() -> httpx.AsyncClient:
    assert _client is not None, "HTTP client not initialized"
    return _client


# ──────────────────────────────────────────────────────────────────────
# Upstream errors
# ──────────────────────────────────────────────────────────────────────

class UpstreamError(Exception):
    def __init__(self, status: int, err_type: str, message: str):
        self.status = status
        self.err_type = err_type
        self.message = message
        super().__init__(message)


def _is_kie_error_envelope(data: Any) -> bool:
    """Kie sometimes replies 200 OK with body {"code": 4xx, "msg": "...", "data": null}."""
    return (
        isinstance(data, dict)
        and "code" in data
        and "msg" in data
        and data.get("data") is None
    )


def _raise_from_kie_envelope(data: dict) -> None:
    code = data.get("code", 500)
    msg = data.get("msg", "Unknown kie.ai error")
    if code in KIE_RATE_LIMIT_CODES:
        raise UpstreamError(429, "rate_limit_error", msg)
    raise UpstreamError(500, "api_error", msg)


def error_payload(err: UpstreamError) -> bytes:
    return json.dumps({"type": "error", "error": {"type": err.err_type, "message": err.message}}).encode()


# ──────────────────────────────────────────────────────────────────────
# Header forwarding
# ──────────────────────────────────────────────────────────────────────

def build_upstream_headers(req_headers: dict[str, str]) -> dict[str, str]:
    out = {"Content-Type": "application/json"}
    api_key = req_headers.get("x-api-key") or ""
    auth = req_headers.get("authorization") or ""
    if api_key:
        out["Authorization"] = f"Bearer {api_key}"
    elif auth:
        out["Authorization"] = auth if auth.lower().startswith("bearer ") else f"Bearer {auth}"
    if "anthropic-version" in req_headers:
        out["anthropic-version"] = req_headers["anthropic-version"]
    return out


# ──────────────────────────────────────────────────────────────────────
# FastAPI app
# ──────────────────────────────────────────────────────────────────────

app = FastAPI(title="Anthropic ↔ Kie.ai thin proxy", lifespan=lifespan)


@app.get("/health")
async def health():
    return {"status": "ok", "upstream": KIE_BASE_URL, "requests": stats.requests}


# ── Anthropic-native endpoint ─────────────────────────────────────────

async def _stream_upstream(payload: dict, headers: dict[str, str]) -> AsyncIterator[bytes]:
    """Open a streaming POST to Kie and forward chunks byte-for-byte.

    If Kie replies with an envelope error (200 + {code,msg}), we don't know
    it until we've read the body — so we probe the first chunk and convert
    to an SSE `error` event if needed.
    """
    try:
        async with http().stream("POST", KIE_MESSAGES_URL, headers=headers, json=payload) as resp:
            if resp.status_code != 200:
                body = await resp.aread()
                err = UpstreamError(resp.status_code, "api_error", body.decode(errors="replace")[:500])
                yield f"event: error\ndata: {error_payload(err).decode()}\n\n".encode()
                return
            async for chunk in resp.aiter_bytes():
                yield chunk
    except httpx.TimeoutException:
        err = UpstreamError(504, "timeout", "Upstream timeout")
        yield f"event: error\ndata: {error_payload(err).decode()}\n\n".encode()
    except httpx.ConnectError as e:
        err = UpstreamError(502, "connection_error", str(e))
        yield f"event: error\ndata: {error_payload(err).decode()}\n\n".encode()


async def _call_upstream(payload: dict, headers: dict[str, str]) -> dict:
    """Non-streaming call. Raises UpstreamError on any failure."""
    try:
        resp = await http().post(KIE_MESSAGES_URL, headers=headers, json=payload)
    except httpx.TimeoutException:
        raise UpstreamError(504, "timeout", "Upstream timeout")
    except httpx.ConnectError as e:
        raise UpstreamError(502, "connection_error", str(e))

    if resp.status_code != 200:
        raise UpstreamError(resp.status_code, "api_error", resp.text[:500])

    data = resp.json()
    if _is_kie_error_envelope(data):
        _raise_from_kie_envelope(data)
    return data


@app.post("/v1/messages")
async def proxy_messages(request: Request):
    try:
        payload = await request.json()
    except Exception:
        return Response(status_code=400, content='{"error":"invalid JSON"}', media_type="application/json")

    payload["model"] = map_model(payload.get("model")) or payload.get("model")
    upstream_headers = build_upstream_headers({k.lower(): v for k, v in request.headers.items()})

    is_stream = bool(payload.get("stream"))
    n = await stats.bump()
    log.info("#%d → /v1/messages model=%s tools=%d stream=%s",
             n, payload.get("model"), len(payload.get("tools") or []), is_stream)

    if is_stream:
        return StreamingResponse(
            _stream_upstream(payload, upstream_headers),
            media_type="text/event-stream",
        )

    try:
        data = await _call_upstream(payload, upstream_headers)
    except UpstreamError as err:
        log.warning("#%d upstream: %d %s — %s", n, err.status, err.err_type, err.message)
        return Response(content=error_payload(err), status_code=err.status, media_type="application/json")
    return JSONResponse(data)


# ── OpenAI-compatible endpoint (OpenClaw uses this) ───────────────────

def _content_to_text(content: Any) -> str:
    """OpenAI messages may use list-of-parts; collapse to a plain string for Anthropic."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(p.get("text", "") for p in content if isinstance(p, dict) and p.get("type") == "text")
    return str(content or "")


def _openai_to_anthropic(body: dict) -> dict:
    system_text = ""
    messages: list[dict] = []
    for msg in body.get("messages", []):
        role = msg.get("role")
        text = _content_to_text(msg.get("content"))
        if role == "system":
            system_text = text
        elif role in ("user", "assistant"):
            messages.append({"role": role, "content": text})

    tools: list[dict] = []
    for tool in body.get("tools") or []:
        if tool.get("type") != "function":
            continue
        fn = tool["function"]
        tools.append({
            "name": fn["name"],
            "description": fn.get("description", ""),
            "input_schema": fn.get("parameters") or {"type": "object", "properties": {}},
        })

    payload: dict[str, Any] = {
        "model": map_model(body.get("model")) or body.get("model"),
        "messages": messages,
        "max_tokens": body.get("max_tokens", DEFAULT_MAX_TOKENS),
        "stream": False,
    }
    if system_text:
        payload["system"] = system_text
    if tools:
        payload["tools"] = tools
    if body.get("temperature") is not None:
        payload["temperature"] = body["temperature"]
    return payload


def _anthropic_to_openai(anthropic_resp: dict, requested_model: str | None) -> dict:
    text_parts: list[str] = []
    tool_calls: list[dict] = []
    for block in anthropic_resp.get("content") or []:
        btype = block.get("type")
        if btype == "text":
            text_parts.append(block.get("text", ""))
        elif btype == "tool_use":
            raw_id = str(block.get("id", ""))
            call_id = raw_id if raw_id.startswith("call_") else f"call_{uuid.uuid4().hex[:24]}"
            tool_calls.append({
                "id": call_id,
                "type": "function",
                "function": {
                    "name": block["name"],
                    "arguments": json.dumps(block.get("input", {})),
                },
            })

    content_str = "".join(text_parts)
    finish = "tool_calls" if anthropic_resp.get("stop_reason") == "tool_use" else "stop"
    message: dict[str, Any] = {"role": "assistant"}
    if tool_calls:
        message["tool_calls"] = tool_calls
        message["content"] = None
    else:
        message["content"] = content_str or None

    u = anthropic_resp.get("usage") or {}
    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:24]}",
        "object": "chat.completion",
        "model": requested_model or anthropic_resp.get("model"),
        "choices": [{"index": 0, "message": message, "finish_reason": finish}],
        "usage": {
            "prompt_tokens":     u.get("input_tokens", 0),
            "completion_tokens": u.get("output_tokens", 0),
            "total_tokens":      u.get("input_tokens", 0) + u.get("output_tokens", 0),
        },
    }


@app.post("/v1/chat/completions")
@app.post("/chat/completions")
async def proxy_openai(request: Request):
    try:
        body = await request.json()
    except Exception:
        return Response(status_code=400, content='{"error":"invalid JSON"}', media_type="application/json")

    upstream_headers = build_upstream_headers({k.lower(): v for k, v in request.headers.items()})
    payload = _openai_to_anthropic(body)

    n = await stats.bump()
    log.info("#%d → /chat/completions model=%s msgs=%d tools=%d",
             n, payload["model"], len(payload["messages"]), len(payload.get("tools") or []))

    try:
        anthropic_resp = await _call_upstream(payload, upstream_headers)
    except UpstreamError as err:
        log.warning("#%d upstream: %d %s — %s", n, err.status, err.err_type, err.message)
        return Response(
            content=json.dumps({"error": {"type": err.err_type, "message": err.message}}),
            status_code=err.status,
            media_type="application/json",
        )

    return JSONResponse(_anthropic_to_openai(anthropic_resp, body.get("model")))


# ──────────────────────────────────────────────────────────────────────
# Entry point
# ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=PROXY_PORT)
