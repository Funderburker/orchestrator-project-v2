"""Anthropic API proxy for Kie.ai — makes Kie.ai compatible with standard Anthropic SDK.

Accepts standard Anthropic Messages API requests, forwards to Kie.ai,
fixes response format, returns standard-compliant responses.

Usage:
  python proxy/server.py
  → runs on http://localhost:4100

Then point any Anthropic SDK client to:
  ANTHROPIC_BASE_URL=http://localhost:4100
"""

import json
import logging
import os
import uuid

import httpx
import uvicorn
from dotenv import load_dotenv
from fastapi import FastAPI, Request, Response
from fastapi.responses import StreamingResponse

load_dotenv()

log = logging.getLogger("proxy")

KIE_BASE_URL = os.getenv("KIE_BASE_URL", "https://api.kie.ai/claude")
PROXY_PORT = int(os.getenv("PROXY_PORT", "4100"))

app = FastAPI(title="Anthropic Proxy for Kie.ai")

# Track requests for debugging
_request_count = 0
_total_input_tokens = 0
_total_output_tokens = 0


def fix_response(data: dict) -> dict:
    """Fix Kie.ai response to match standard Anthropic Messages API format."""

    # Ensure 'id' exists and has correct prefix
    if "id" not in data or not data["id"].startswith("msg_"):
        data["id"] = f"msg_{uuid.uuid4().hex[:24]}"

    # Ensure 'type' is 'message'
    data.setdefault("type", "message")

    # Ensure 'role' is 'assistant'
    data.setdefault("role", "assistant")

    # Ensure 'model' exists
    data.setdefault("model", "claude-sonnet-4-5")

    # Fix 'stop_reason' → standard values
    stop = data.get("stop_reason", "end_turn")
    if stop == "end_turn":
        data["stop_reason"] = "end_turn"
    elif stop == "tool_use":
        data["stop_reason"] = "tool_use"
    else:
        data["stop_reason"] = stop

    data.setdefault("stop_sequence", None)

    # Ensure 'content' is a list (not None)
    if data.get("content") is None:
        data["content"] = [{"type": "text", "text": ""}]

    # Ensure each content block has correct structure
    for block in data.get("content", []):
        if block.get("type") == "text":
            block.setdefault("text", "")
        elif block.get("type") == "tool_use":
            if not str(block.get("id","")).startswith("toolu_"): block["id"] = f"toolu_{uuid.uuid4().hex[:24]}"
            block.setdefault("name", "unknown")
            block.setdefault("input", {})

    # Fix usage format
    usage = data.get("usage", {})
    data["usage"] = {
        "input_tokens": usage.get("input_tokens", 0),
        "output_tokens": usage.get("output_tokens", 0),
        "cache_creation_input_tokens": usage.get("cache_creation_input_tokens", 0),
        "cache_read_input_tokens": usage.get("cache_read_input_tokens", 0),
    }

    # Remove non-standard fields
    data.pop("credits_consumed", None)

    return data


@app.post("/v1/messages")
async def proxy_messages(request: Request):
    """Proxy Anthropic Messages API to Kie.ai."""
    global _request_count, _total_input_tokens, _total_output_tokens
    _request_count += 1
    req_num = _request_count

    body = await request.body()
    headers = dict(request.headers)

    # Forward relevant headers
    forward_headers = {
        "Content-Type": "application/json",
        "Authorization": headers.get("authorization", headers.get("x-api-key", "")),
    }
    if "x-api-key" in headers:
        forward_headers["Authorization"] = f"Bearer {headers['x-api-key']}"
    if "anthropic-version" in headers:
        forward_headers["anthropic-version"] = headers["anthropic-version"]

    # Parse body to check for streaming
    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        return Response(content=body, status_code=400)

    is_stream = payload.get("stream", False)
    num_tools = len(payload.get("tools", []))
    log.info(f"[REQ #{req_num}] model={payload.get('model')} tools={num_tools} stream={is_stream}")

    # Force stream=false for now (Kie.ai streaming format may differ)
    payload["stream"] = False

    # Normalize model names for Kie.ai (doesn't support date-suffixed names)
    model = payload.get("model", "")
    MODEL_MAP = {
        "claude-sonnet-4-20250514": "claude-sonnet-4-5",
        "claude-opus-4-20250514": "claude-opus-4-1",
        "claude-sonnet-4-6": "claude-sonnet-4-5",
        "claude-opus-4-6": "claude-opus-4-1",
        "claude-haiku-4-6": "claude-haiku-4-5",
        "claude-haiku-4-20250514": "claude-haiku-4-5",
    }
    if model in MODEL_MAP:
        payload["model"] = MODEL_MAP[model]

    try:
        async with httpx.AsyncClient(timeout=60) as client:
            resp = await client.post(
                f"{KIE_BASE_URL}/v1/messages",
                headers=forward_headers,
                json=payload,
            )
    except httpx.TimeoutException:
        log.error(f"[REQ #{req_num}] TIMEOUT after 60s")
        return Response(
            content=json.dumps({"type": "error", "error": {"type": "timeout", "message": "Upstream timeout"}}),
            status_code=504,
            headers={"Content-Type": "application/json"},
        )
    except httpx.ConnectError as e:
        log.error(f"[REQ #{req_num}] CONNECTION ERROR: {e}")
        return Response(
            content=json.dumps({"type": "error", "error": {"type": "connection_error", "message": str(e)}}),
            status_code=502,
            headers={"Content-Type": "application/json"},
        )

    if resp.status_code != 200:
        log.warning(f"[REQ #{req_num}] upstream returned {resp.status_code}: {resp.text[:200]}")
        return Response(
            content=resp.content,
            status_code=resp.status_code,
            headers={"Content-Type": "application/json"},
        )

    data = resp.json()

    # Kie.ai returns 200 with error body on rate limits / quota exceeded
    if "code" in data and "msg" in data and data.get("data") is None:
        err_code = data.get("code")
        err_msg = data.get("msg", "Unknown kie.ai error")
        log.error(f"[REQ #{req_num}] kie.ai error {err_code}: {err_msg}")
        err_type = "rate_limit_error" if err_code in (429, 433) else "api_error"
        err_body = json.dumps({"type": "error", "error": {"type": err_type, "message": err_msg}})
        if is_stream:
            async def generate_error_sse():
                yield f"event: error\ndata: {err_body}\n\n"
            return StreamingResponse(generate_error_sse(), media_type="text/event-stream", status_code=200)
        return Response(content=err_body, status_code=429 if err_code in (429, 433) else 500,
                        headers={"Content-Type": "application/json"})

    fixed = fix_response(data)

    # Log tokens
    usage = fixed.get("usage", {})
    inp = usage.get("input_tokens", 0)
    out = usage.get("output_tokens", 0)
    _total_input_tokens += inp
    _total_output_tokens += out
    log.info(f"[REQ #{req_num}] OK: {inp}in+{out}out tokens (session total: {_total_input_tokens}in+{_total_output_tokens}out)")

    # Log to Mission Control
    try:
        from crew.mc import log_tokens
        log_tokens(payload.get("model", "unknown"), inp, out)
    except Exception:
        pass

    if is_stream:
        # Convert non-streaming response to SSE format for clients expecting stream
        async def generate_sse():
            # message_start
            yield f"event: message_start\ndata: {json.dumps({'type': 'message_start', 'message': {**fixed, 'content': []}})}\n\n"

            # content blocks
            for i, block in enumerate(fixed.get("content", [])):
                block_type = block.get("type")
                if block_type == "tool_use":
                    start_block = {"type": "tool_use", "id": block.get("id"), "name": block.get("name"), "input": {}}
                    yield f"event: content_block_start\ndata: {json.dumps({'type': 'content_block_start', 'index': i, 'content_block': start_block})}\n\n"
                    input_json = json.dumps(block.get("input", {}))
                    yield f"event: content_block_delta\ndata: {json.dumps({'type': 'content_block_delta', 'index': i, 'delta': {'type': 'input_json_delta', 'partial_json': input_json}})}\n\n"
                elif block_type == "text":
                    start_block = {"type": "text", "text": ""}
                    yield f"event: content_block_start\ndata: {json.dumps({'type': 'content_block_start', 'index': i, 'content_block': start_block})}\n\n"
                    yield f"event: content_block_delta\ndata: {json.dumps({'type': 'content_block_delta', 'index': i, 'delta': {'type': 'text_delta', 'text': block.get('text', '')}})}\n\n"
                else:
                    yield f"event: content_block_start\ndata: {json.dumps({'type': 'content_block_start', 'index': i, 'content_block': block})}\n\n"
                yield f"event: content_block_stop\ndata: {json.dumps({'type': 'content_block_stop', 'index': i})}\n\n"

            # message_delta + message_stop
            yield f"event: message_delta\ndata: {json.dumps({'type': 'message_delta', 'delta': {'stop_reason': fixed.get('stop_reason', 'end_turn'), 'stop_sequence': None}, 'usage': {'output_tokens': fixed['usage']['output_tokens']}})}\n\n"
            yield f"event: message_stop\ndata: {json.dumps({'type': 'message_stop'})}\n\n"

        return StreamingResponse(generate_sse(), media_type="text/event-stream")

    return Response(
        content=json.dumps(fixed),
        status_code=200,
        headers={"Content-Type": "application/json"},
    )


@app.post("/v1/chat/completions")
@app.post("/chat/completions")
async def proxy_openai(request: Request):
    """OpenAI-compatible endpoint. Converts OpenAI format → Anthropic → Kie.ai → OpenAI response."""
    body = await request.json()
    tools = body.get('tools', [])
    tool_names = [t.get('function',{}).get('name','?') for t in tools if t.get('type')=='function']
    log.info(f"[OPENAI-REQ] model={body.get('model')}, msgs={len(body.get('messages',[]))}, tools={tool_names[:10]}")
    headers = dict(request.headers)

    # Extract API key
    auth = headers.get("authorization", "")
    api_key = auth.replace("Bearer ", "") if auth.startswith("Bearer ") else auth

    # Convert OpenAI messages to Anthropic format
    system_text = ""
    anthropic_messages = []
    for msg in body.get("messages", []):
        if msg["role"] == "system":
            system_text = msg["content"]
        else:
            anthropic_messages.append({"role": msg["role"], "content": msg["content"]})

    # Convert OpenAI tools to Anthropic format
    anthropic_tools = []
    for tool in body.get("tools", []):
        if tool.get("type") == "function":
            f = tool["function"]
            anthropic_tools.append({
                "name": f["name"],
                "description": f.get("description", ""),
                "input_schema": f.get("parameters", {"type": "object", "properties": {}}),
            })

    # Normalize model name for Kie.ai
    MODEL_MAP = {
        "claude-sonnet-4-20250514": "claude-sonnet-4-5",
        "claude-opus-4-20250514": "claude-opus-4-1",
        "claude-sonnet-4-6": "claude-sonnet-4-5",
        "claude-opus-4-6": "claude-opus-4-1",
        "claude-haiku-4-6": "claude-haiku-4-5",
        "claude-haiku-4-20250514": "claude-haiku-4-5",
    }
    raw_model = body.get("model", "claude-sonnet-4-5")
    mapped_model = MODEL_MAP.get(raw_model, raw_model)

    # Build Anthropic request
    anthropic_payload = {
        "model": mapped_model,
        "messages": anthropic_messages,
        "max_tokens": body.get("max_tokens", 4096),
        "stream": False,
    }
    if system_text:
        anthropic_payload["system"] = system_text
    if anthropic_tools:
        anthropic_payload["tools"] = anthropic_tools
    if body.get("temperature") is not None:
        anthropic_payload["temperature"] = body["temperature"]

    # Call Kie.ai
    forward_headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }

    async with httpx.AsyncClient(timeout=120) as client:
        resp = await client.post(
            f"{KIE_BASE_URL}/v1/messages",
            headers=forward_headers,
            json=anthropic_payload,
        )

    if resp.status_code != 200:
        return Response(content=resp.content, status_code=resp.status_code)

    data = resp.json()
    fixed = fix_response(data)

    # Convert Anthropic response → OpenAI format
    content_text = ""
    tool_calls_openai = []
    for i, block in enumerate(fixed.get("content", [])):
        if block.get("type") == "text":
            content_text += block.get("text", "")
        elif block.get("type") == "tool_use":
            # OpenAI expects call_XXX format for tool call IDs
            raw_id = block.get("id", "")
            call_id = raw_id if raw_id.startswith("call_") else f"call_{uuid.uuid4().hex[:24]}"
            tool_calls_openai.append({
                "id": call_id,
                "type": "function",
                "function": {
                    "name": block["name"],
                    "arguments": json.dumps(block.get("input", {})),
                },
            })

    finish_reason = "stop"
    if fixed.get("stop_reason") == "tool_use":
        finish_reason = "tool_calls"

    openai_response = {
        "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
        "object": "chat.completion",
        "model": fixed.get("model", body.get("model")),
        "choices": [{
            "index": 0,
            "message": {
                "role": "assistant",
                "content": content_text or None,
            },
            "finish_reason": finish_reason,
        }],
        "usage": {
            "prompt_tokens": fixed["usage"].get("input_tokens", 0),
            "completion_tokens": fixed["usage"].get("output_tokens", 0),
            "total_tokens": fixed["usage"].get("input_tokens", 0) + fixed["usage"].get("output_tokens", 0),
        },
    }

    if tool_calls_openai:
        openai_response["choices"][0]["message"]["tool_calls"] = tool_calls_openai
        # When tools are called, set content to None (OpenAI convention)
        openai_response["choices"][0]["message"]["content"] = None

    log.info(f"[OPENAI-RESP] FULL: {json.dumps(openai_response)[:500]}")

    return Response(
        content=json.dumps(openai_response),
        status_code=200,
        headers={"Content-Type": "application/json"},
    )


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "upstream": KIE_BASE_URL,
        "requests": _request_count,
        "total_input_tokens": _total_input_tokens,
        "total_output_tokens": _total_output_tokens,
    }


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    log.info(f"Starting Anthropic proxy on port {PROXY_PORT}, upstream: {KIE_BASE_URL}")
    uvicorn.run(app, host="0.0.0.0", port=PROXY_PORT)
