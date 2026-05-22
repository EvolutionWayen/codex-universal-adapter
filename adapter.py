#!/usr/bin/env python3
"""
Codex Universal Adapter - Responses API → Chat Completions 协议转换器
支持任何兼容 OpenAI Chat Completions API 的服务商

配置文件：~/.codex-adapter/config.json
{
  "upstream": "https://你的服务商地址/v1",
  "model": "模型名称",
  "api_key": "你的API Key"
}

注意：upstream 只需填到 /v1，适配器会自动拼接 /chat/completions
"""

import json
import os
import socket
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = 18666
CONFIG_PATH = os.path.expanduser("~/.codex-adapter/config.json")


def load_config(config_path=None):
    """从配置文件读取上游地址、模型名、API Key
    upstream 只需填到 /v1，适配器会自动拼接 /chat/completions
    如果用户已经填了 /chat/completions 结尾，也能兼容
    支持通过命令行参数 --config 指定配置文件路径
    """
    path = config_path or CONFIG_PATH
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
        upstream = cfg.get("upstream", "").rstrip("/")
        # 自动补全 /chat/completions
        if not upstream.endswith("/chat/completions"):
            upstream = upstream + "/chat/completions"
        return upstream, cfg.get("model", ""), cfg.get("api_key", "")
    return "", "", ""


UPSTREAM, UPSTREAM_MODEL, DEFAULT_API_KEY = load_config()


def extract_text(value):
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        parts = [extract_text(item) for item in value]
        return "\n".join(part for part in parts if part)
    if isinstance(value, dict):
        for key in ("text", "content", "output", "result"):
            if key in value:
                text = extract_text(value[key])
                if text:
                    return text
        return json.dumps(value, ensure_ascii=False)
    return str(value)


def normalize_role(role):
    if role in ("developer", "system"):
        return "system"
    if role in ("assistant", "tool"):
        return role
    return "user"


def responses_to_messages(body):
    messages = []
    instructions = body.get("instructions")
    if instructions:
        messages.append({"role": "system", "content": extract_text(instructions)})
    inp = body.get("input", "")
    if isinstance(inp, str):
        if inp.strip():
            messages.append({"role": "user", "content": inp})
        return messages or [{"role": "user", "content": ""}]
    if isinstance(inp, list):
        for item in inp:
            if not isinstance(item, dict):
                text = extract_text(item)
                if text:
                    messages.append({"role": "user", "content": text})
                continue
            typ = item.get("type")
            if typ == "function_call_output":
                messages.append({"role": "tool", "tool_call_id": item.get("call_id") or item.get("id") or "call_unknown", "content": extract_text(item.get("output"))})
                continue
            if typ == "function_call":
                messages.append({"role": "assistant", "content": None, "tool_calls": [{"id": item.get("call_id") or item.get("id") or "call_unknown", "type": "function", "function": {"name": item.get("name") or "unknown", "arguments": item.get("arguments") or "{}"}}]})
                continue
            role = normalize_role(item.get("role") or ("assistant" if typ == "message" else "user"))
            text = extract_text(item.get("content"))
            if not text and typ:
                text = extract_text(item)
            if text:
                messages.append({"role": role, "content": text})
    return messages or [{"role": "user", "content": ""}]


def responses_tools_to_chat_tools(tools):
    chat_tools = []
    for tool in tools or []:
        if not isinstance(tool, dict):
            continue
        if tool.get("type") != "function":
            continue
        name = tool.get("name") or tool.get("function", {}).get("name")
        if not name:
            continue
        chat_tools.append({"type": "function", "function": {"name": name, "description": tool.get("description") or tool.get("function", {}).get("description") or "", "parameters": tool.get("parameters") or tool.get("function", {}).get("parameters") or {"type": "object", "properties": {}}}})
    return chat_tools


def sse(handler, event, data):
    payload = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    try:
        handler.wfile.write(f"event: {event}\n".encode("utf-8"))
        handler.wfile.write(f"data: {payload}\n\n".encode("utf-8"))
        handler.wfile.flush()
        return True
    except (BrokenPipeError, ConnectionResetError, socket.timeout):
        return False


def response_shell(response_id, model, status, output=None, usage=None):
    body = {"id": response_id, "object": "response", "created_at": int(time.time()), "status": status, "model": model, "output": output or [], "parallel_tool_calls": True, "tool_choice": "auto"}
    if usage:
        body["usage"] = usage
    return body


def output_from_chat_message(message):
    output = []
    text = message.get("content") or ""
    if text:
        output.append({"id": "msg_" + uuid.uuid4().hex, "type": "message", "status": "completed", "role": "assistant", "content": [{"type": "output_text", "text": text, "annotations": []}]})
    for call in message.get("tool_calls") or []:
        fn = call.get("function") or {}
        output.append({"id": "fc_" + uuid.uuid4().hex, "type": "function_call", "status": "completed", "call_id": call.get("id") or "call_" + uuid.uuid4().hex, "name": fn.get("name") or "unknown", "arguments": fn.get("arguments") or "{}"})
    return output


class Handler(BaseHTTPRequestHandler):
    server_version = "codex-universal-adapter/1.0"

    def log_message(self, fmt, *args):
        print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {self.address_string()} {fmt % args}", flush=True)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path in ("/health", "/v1/health"):
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"ok":true}')
            return
        if path in ("/models", "/v1/models"):
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"object": "list", "data": [{"id": UPSTREAM_MODEL, "object": "model", "created": int(time.time()), "owned_by": "custom"}]}).encode("utf-8"))
            return
        self.send_error(404)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if not (path.startswith("/v1/responses") or path.startswith("/responses")):
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("content-length", "0"))
            raw = self.rfile.read(length)
            body = json.loads(raw.decode("utf-8") or "{}")
            auth = self.headers.get("authorization") or self.headers.get("Authorization")
            if not auth:
                if DEFAULT_API_KEY:
                    auth = f"Bearer {DEFAULT_API_KEY}"
                else:
                    self.send_error(401, "Missing Authorization header")
                    return
            messages = responses_to_messages(body)
            max_tokens = body.get("max_output_tokens") or body.get("max_tokens") or 4096
            upstream_body = {"model": UPSTREAM_MODEL, "messages": messages, "stream": False, "max_tokens": max_tokens}
            chat_tools = responses_tools_to_chat_tools(body.get("tools"))
            if chat_tools:
                upstream_body["tools"] = chat_tools
                if body.get("tool_choice") and body.get("tool_choice") != "auto":
                    upstream_body["tool_choice"] = body.get("tool_choice")
            if "temperature" in body:
                upstream_body["temperature"] = body["temperature"]
            if body.get("stream", True) is not False:
                self.handle_stream(auth, upstream_body)
            else:
                self.handle_non_stream(auth, upstream_body)
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            return
        except Exception as exc:
            traceback.print_exc()
            self.send_response(500)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": str(exc)}, ensure_ascii=False).encode("utf-8"))

    def upstream_request(self, auth, upstream_body):
        req = urllib.request.Request(UPSTREAM, data=json.dumps(upstream_body, ensure_ascii=False).encode("utf-8"), method="POST", headers={"Authorization": auth, "Content-Type": "application/json", "Accept": "application/json"})
        return urllib.request.urlopen(req, timeout=600)

    def fetch_upstream(self, auth, upstream_body):
        with self.upstream_request(auth, upstream_body) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def handle_non_stream(self, auth, upstream_body):
        try:
            data = self.fetch_upstream(auth, upstream_body)
        except urllib.error.HTTPError as err:
            payload = err.read()
            self.send_response(err.code)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(payload)
            return
        message = (data.get("choices") or [{}])[0].get("message") or {}
        output = output_from_chat_message(message)
        result = response_shell("resp_" + uuid.uuid4().hex, UPSTREAM_MODEL, "completed", output=output)
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(result, ensure_ascii=False).encode("utf-8"))

    def handle_stream(self, auth, upstream_body):
        response_id = "resp_" + uuid.uuid4().hex
        self.send_response(200)
        self.send_header("content-type", "text/event-stream; charset=utf-8")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()
        if not sse(self, "response.created", {"type": "response.created", "response": response_shell(response_id, UPSTREAM_MODEL, "in_progress")}):
            return
        try:
            data = self.fetch_upstream(auth, upstream_body)
        except urllib.error.HTTPError as err:
            detail = err.read().decode("utf-8", "replace")
            print(f"upstream HTTP {err.code}: {detail}", flush=True)
            error_msg = f"上游接口返回错误 HTTP {err.code}: {detail[:1200]}"
            data = {"choices": [{"message": {"content": error_msg}}]}
        except urllib.error.URLError as err:
            detail = str(err)
            print(f"upstream URL error: {detail}", flush=True)
            error_msg = f"上游接口连接失败: {detail[:1200]}"
            data = {"choices": [{"message": {"content": error_msg}}]}
        message = (data.get("choices") or [{}])[0].get("message") or {}
        output = output_from_chat_message(message)
        usage = data.get("usage")
        mapped_usage = None
        if usage:
            mapped_usage = {"input_tokens": usage.get("prompt_tokens", 0), "output_tokens": usage.get("completion_tokens", 0), "total_tokens": usage.get("total_tokens", 0)}
        for index, item in enumerate(output):
            if not sse(self, "response.output_item.added", {"type": "response.output_item.added", "response_id": response_id, "output_index": index, "item": item}):
                return
            if item.get("type") == "message":
                part = item["content"][0]
                if not sse(self, "response.content_part.added", {"type": "response.content_part.added", "response_id": response_id, "item_id": item["id"], "output_index": index, "content_index": 0, "part": {"type": "output_text", "text": "", "annotations": []}}):
                    return
                if not sse(self, "response.output_text.delta", {"type": "response.output_text.delta", "response_id": response_id, "item_id": item["id"], "output_index": index, "content_index": 0, "delta": part.get("text", "")}):
                    return
                if not sse(self, "response.output_text.done", {"type": "response.output_text.done", "response_id": response_id, "item_id": item["id"], "output_index": index, "content_index": 0, "text": part.get("text", "")}):
                    return
                if not sse(self, "response.content_part.done", {"type": "response.content_part.done", "response_id": response_id, "item_id": item["id"], "output_index": index, "content_index": 0, "part": part}):
                    return
            if not sse(self, "response.output_item.done", {"type": "response.output_item.done", "response_id": response_id, "output_index": index, "item": item}):
                return
        sse(self, "response.completed", {"type": "response.completed", "response": response_shell(response_id, UPSTREAM_MODEL, "completed", output=output, usage=mapped_usage)})
        self.close_connection = True


def main():
    global UPSTREAM, UPSTREAM_MODEL, DEFAULT_API_KEY

    import argparse
    parser = argparse.ArgumentParser(description="Codex Universal Adapter — Responses API → Chat Completions")
    parser.add_argument("--config", default=CONFIG_PATH, help="配置文件路径 (默认: ~/.codex-adapter/config.json)")
    parser.add_argument("--port", type=int, default=PORT, help="监听端口 (默认: 18666)")
    args = parser.parse_args()

    UPSTREAM, UPSTREAM_MODEL, DEFAULT_API_KEY = load_config(args.config)

    if not UPSTREAM or not UPSTREAM_MODEL:
        print(f"错误：配置文件 {args.config} 中缺少 upstream 或 model", flush=True)
        print(f'请确保配置文件格式如下：\n{{"upstream": "https://xxx/v1", "model": "模型名", "api_key": "sk-xxx"}}', flush=True)
        return

    httpd = ThreadingHTTPServer((HOST, args.port), Handler)
    print(f"codex-universal-adapter listening on http://{HOST}:{args.port}", flush=True)
    print(f"config: {args.config}", flush=True)
    print(f"upstream: {UPSTREAM}", flush=True)
    print(f"model: {UPSTREAM_MODEL}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
