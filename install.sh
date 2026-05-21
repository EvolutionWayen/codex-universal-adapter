#!/bin/bash
# ============================================================
# Codex Universal Adapter - 一键安装脚本（macOS）
# 
# 原理：Codex 使用 OpenAI Responses API 协议，但国内大部分
# 模型服务商只支持 Chat Completions API。这个适配器跑在你
# 电脑上，充当"翻译官"：
#   Codex → [Responses API] → 本地适配器 → [Chat Completions] → 你的服务商
#   Codex ← [Responses API] ← 本地适配器 ← [Chat Completions] ← 你的服务商
# 
# 使用者只需要提供两样东西：
#   1. API 请求地址（你的服务商提供的 Chat Completions 端点）
#   2. API 密钥（你的服务商提供的 Key）
# 
# 就可以让 Codex 使用任何兼容 OpenAI Chat Completions 的模型。
# ============================================================

set -e

# ---------- 颜色 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---------- 路径 ----------
ADAPTER_DIR="$HOME/.codex-adapter"
ADAPTER="$ADAPTER_DIR/codex-adapter.py"
CONFIG="$ADAPTER_DIR/config.json"
PLIST="$HOME/Library/LaunchAgents/com.codex-universal-adapter.plist"
LABEL="com.codex-universal-adapter"
LOG_DIR="$ADAPTER_DIR/logs"

echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║     Codex Universal Adapter - 一键安装           ║${NC}"
echo -e "${CYAN}${BOLD}║     让 Codex 使用任何兼容 Chat Completions 的模型  ║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""

# ---------- 前置检查 ----------
echo -e "${YELLOW}[1/6] 检查环境...${NC}"

if ! command -v python3 &>/dev/null; then
    echo -e "${RED}错误：未找到 python3，请先安装 Python 3${NC}"
    exit 1
fi

echo -e "  python3: ${GREEN}$(python3 --version)${NC}"

# ---------- 创建目录 ----------
echo -e "${YELLOW}[2/6] 创建配置目录...${NC}"
mkdir -p "$ADAPTER_DIR" "$LOG_DIR"

# ---------- 写入适配器 ----------
echo -e "${YELLOW}[3/6] 写入适配器程序...${NC}"

cat > "$ADAPTER" <<'PYADAPTER'
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


def load_config():
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            cfg = json.load(f)
        upstream = cfg.get("upstream", "").rstrip("/")
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
            data = {"choices": [{"message": {"content": f"上游接口返回错误 HTTP {err.code}: {detail[:1200]}"}}]}
        except urllib.error.URLError as err:
            detail = str(err)
            print(f"upstream URL error: {detail}", flush=True)
            data = {"choices": [{"message": {"content": f"上游接口连接失败: {detail[:1200]"}}]}
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
    UPSTREAM, UPSTREAM_MODEL, DEFAULT_API_KEY = load_config()
    if not UPSTREAM or not UPSTREAM_MODEL:
        print(f"错误：配置文件 {CONFIG_PATH} 中缺少 upstream 或 model", flush=True)
        return
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"codex-universal-adapter listening on http://{HOST}:{PORT}", flush=True)
    print(f"upstream: {UPSTREAM}", flush=True)
    print(f"model: {UPSTREAM_MODEL}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
PYADAPTER

chmod +x "$ADAPTER"
echo -e "  ${GREEN}OK${NC} → $ADAPTER"

# ---------- 收集用户输入 ----------
echo ""
echo -e "${BOLD}请输入你的服务商信息：${NC}"
echo -e ""
echo -e "  ${CYAN}常见服务商地址参考（只需填到 /v1）：${NC}"
echo -e "  ┌──────────────────┬──────────────────────────────────────────────────────┐"
echo -e "  │ 服务商            │ API 基础地址                                          │"
echo -e "  ├──────────────────┼──────────────────────────────────────────────────────┤"
echo -e "  │ SenseNova(商汤)   │ https://token.sensenova.cn/v1                        │"
echo -e "  │ DeepSeek          │ https://api.deepseek.com/v1                          │"
echo -e "  │ 硅基流动           │ https://api.siliconflow.cn/v1                        │"
echo -e "  │ 阿里云百炼         │ https://dashscope.aliyuncs.com/compatible-mode/v1    │"
echo -e "  │ 火山引擎(豆包)     │ https://ark.cn-beijing.volces.com/api/v3             │"
echo -e "  │ 智谱 AI           │ https://open.bigmodel.cn/api/paas/v4                 │"
echo -e "  │ OpenRouter        │ https://openrouter.ai/api/v1                         │"
echo -e "  │ 生数云            │ https://router.shengsuanyun.com/v1                   │"
echo -e "  └──────────────────┴──────────────────────────────────────────────────────┘"
echo ""

# 输入 API 地址
read -p "1) API 基础地址（只需到 /v1，如 https://token.sensenova.cn/v1）: " API_URL
if [ -z "$API_URL" ]; then
    echo -e "${RED}错误：API 地址不能为空${NC}"
    exit 1
fi

# 输入模型名
read -p "2) 模型名称（如 deepseek-v4-flash）: " MODEL_NAME
if [ -z "$MODEL_NAME" ]; then
    echo -e "${RED}错误：模型名称不能为空${NC}"
    exit 1
fi

# 输入 API Key
read -s -p "3) API 密钥（输入时不显示明文）: " API_KEY
echo ""
if [ -z "$API_KEY" ]; then
    echo -e "${RED}错误：API 密钥不能为空${NC}"
    exit 1
fi

# ---------- 写入配置 ----------
echo -e "${YELLOW}[4/6] 写入配置文件...${NC}"
cat > "$CONFIG" <<EOF
{
  "upstream": "$API_URL",
  "model": "$MODEL_NAME",
  "api_key": "$API_KEY"
}
EOF
chmod 600 "$CONFIG"
echo -e "  ${GREEN}OK${NC} → $CONFIG"

# ---------- 注册后台服务 ----------
echo -e "${YELLOW}[5/6] 注册开机自启服务...${NC}"

# 先卸载旧版（如果存在）
if [ -f "$PLIST" ]; then
    launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
fi

# 也卸载旧版讯飞适配器
OLD_PLIST="$HOME/Library/LaunchAgents/com.kangarooking.xfyun-codex-adapter.plist"
if [ -f "$OLD_PLIST" ]; then
    launchctl bootout "gui/$(id -u)" "$OLD_PLIST" 2>/dev/null || true
fi

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>${ADAPTER}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/adapter.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/adapter.err.log</string>
</dict>
</plist>
PLISTEOF

launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl kickstart -k "gui/$(id -u)/${LABEL}"
echo -e "  ${GREEN}OK${NC} → 服务已启动"

# ---------- 配置 CC Switch / Codex ----------
echo -e "${YELLOW}[6/6] 配置 Codex...${NC}"

# 写入 Codex config.toml
CODEX_DIR="$HOME/.codex"
mkdir -p "$CODEX_DIR"

CODEX_CONFIG="$CODEX_DIR/config.toml"
if [ -f "$CODEX_CONFIG" ]; then
    # 备份原有配置
    cp "$CODEX_CONFIG" "${CODEX_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
fi

cat > "$CODEX_CONFIG" <<TOMLEOF
model = "${MODEL_NAME}"
model_provider = "universal_adapter"

[model_providers.universal_adapter]
name = "Universal Adapter"
base_url = "http://127.0.0.1:18666/v1"
wire_api = "responses"
requires_openai_auth = true
request_max_retries = 2
stream_max_retries = 2
stream_idle_timeout_ms = 300000

model_reasoning_effort = "high"
disable_response_storage = true

model_context_window = 1000000
model_auto_compact_token_limit = 900000
TOMLEOF

# 写入 Codex auth.json
cat > "$CODEX_DIR/auth.json" <<AUTHEOF
{
  "OPENAI_API_KEY": "${API_KEY}"
}
AUTHEOF
chmod 600 "$CODEX_DIR/auth.json"

echo -e "  ${GREEN}OK${NC} → $CODEX_CONFIG"

# ---------- 完成 ----------
sleep 1

echo ""
echo -e "${GREEN}${BOLD}✅ 安装完成！${NC}"
echo ""
echo -e "  适配器状态：$(curl -s http://127.0.0.1:18666/health 2>/dev/null || echo '{"ok":false}')"
echo -e "  上游地址：$API_URL"
echo -e "  模型名称：$MODEL_NAME"
echo ""
echo -e "${BOLD}  下一步：重启 Codex 即可使用${NC}"
echo ""
echo -e "  ${CYAN}常用命令：${NC}"
echo -e "    查看状态：curl http://127.0.0.1:18666/health"
echo -e "    查看模型：curl http://127.0.0.1:18666/v1/models"
echo -e "    查看日志：cat $LOG_DIR/adapter.log"
echo -e "    修改配置：编辑 $CONFIG（改完执行 launchctl kickstart -k \"gui/\$(id -u)/$LABEL\"）"
echo ""
echo -e "  ${CYAN}卸载命令：${NC}"
echo -e "    curl -fsSL https://gitee.com/kangarooking/xfyun-codex-adapter/raw/main/uninstall.sh | bash"
echo -e "    （或手动：launchctl bootout \"gui/\$(id -u)\" $PLIST && rm -rf $ADAPTER_DIR）"
echo ""
