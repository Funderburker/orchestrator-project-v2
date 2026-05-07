#!/usr/bin/env python3
"""Patch proxy.py SSE generator to properly emit tool_use deltas."""
import re
import sys

PROXY_PATH = '/opt/openclaw/proxy.py'

with open(PROXY_PATH, 'r') as f:
    src = f.read()

# Find the content blocks loop inside generate_sse
pattern = re.compile(
    r'(            # content blocks\n)'
    r'            for i, block in enumerate\(fixed\.get\("content", \[\]\)\):\n'
    r'                yield f"event: content_block_start[^"]*"\n'
    r'\n'
    r'                if block\.get\("type"\) == "text":\n'
    r'                    yield f"event: content_block_delta[^"]*"\n'
    r'\n'
    r'                yield f"event: content_block_stop[^"]*"\n',
    re.DOTALL,
)

replacement = '''            # content blocks
            for i, block in enumerate(fixed.get("content", [])):
                block_type = block.get("type")
                if block_type == "tool_use":
                    start_block = {"type": "tool_use", "id": block.get("id"), "name": block.get("name"), "input": {}}
                    yield f"event: content_block_start\\ndata: {json.dumps({'type': 'content_block_start', 'index': i, 'content_block': start_block})}\\n\\n"
                    input_json = json.dumps(block.get("input", {}))
                    yield f"event: content_block_delta\\ndata: {json.dumps({'type': 'content_block_delta', 'index': i, 'delta': {'type': 'input_json_delta', 'partial_json': input_json}})}\\n\\n"
                elif block_type == "text":
                    start_block = {"type": "text", "text": ""}
                    yield f"event: content_block_start\\ndata: {json.dumps({'type': 'content_block_start', 'index': i, 'content_block': start_block})}\\n\\n"
                    yield f"event: content_block_delta\\ndata: {json.dumps({'type': 'content_block_delta', 'index': i, 'delta': {'type': 'text_delta', 'text': block.get('text', '')}})}\\n\\n"
                else:
                    yield f"event: content_block_start\\ndata: {json.dumps({'type': 'content_block_start', 'index': i, 'content_block': block})}\\n\\n"
                yield f"event: content_block_stop\\ndata: {json.dumps({'type': 'content_block_stop', 'index': i})}\\n\\n"
'''

# Simpler: just find by a unique anchor and replace the whole block manually
marker_start = '            # content blocks\n            for i, block in enumerate(fixed.get("content", [])):'
marker_end = '            # message_delta + message_stop'

start_idx = src.find(marker_start)
end_idx = src.find(marker_end)

if start_idx == -1 or end_idx == -1:
    print('FAILED: markers not found', file=sys.stderr)
    sys.exit(1)

before = src[:start_idx]
after = src[end_idx:]
patched = before + replacement + '\n' + after

with open(PROXY_PATH, 'w') as f:
    f.write(patched)

print('Patched OK')
