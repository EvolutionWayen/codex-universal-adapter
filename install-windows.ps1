# ============================================================
# Codex Universal Adapter - 一键安装脚本（Windows）
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

param()

$ErrorActionPreference = "Stop"

# ---------- 路径 ----------
$AdapterDir = Join-Path $env:USERPROFILE ".codex-adapter"
$Adapter = Join-Path $AdapterDir "codex-adapter.py"
$Config = Join-Path $AdapterDir "config.json"
$LogDir = Join-Path $AdapterDir "logs"
$TaskName = "CodexUniversalAdapter"

Write-Host ""
Write-Host "  ==============================================================" -ForegroundColor Cyan
Write-Host "    Codex Universal Adapter - 一键安装 (Windows)" -ForegroundColor Cyan
Write-Host "    让 Codex 使用任何兼容 Chat Completions 的模型" -ForegroundColor Cyan
Write-Host "  ==============================================================" -ForegroundColor Cyan
Write-Host ""

# ---------- 前置检查 ----------
Write-Host "[1/6] 检查环境..." -ForegroundColor Yellow

$pythonCmd = $null
foreach ($cmd in @("python", "python3", "py")) {
    try {
        $ver = & $cmd --version 2>&1
        if ($ver -match "Python 3") {
            $pythonCmd = $cmd
            break
        }
    } catch {}
}

if (-not $pythonCmd) {
    Write-Host "  错误：未找到 Python 3，请先安装 https://www.python.org/downloads/" -ForegroundColor Red
    Write-Host "  安装时务必勾选 'Add Python to PATH'" -ForegroundColor Red
    exit 1
}

$pythonVersion = & $pythonCmd --version 2>&1
Write-Host "  Python: $pythonVersion" -ForegroundColor Green

# 获取 Python 完整路径（用于 Task Scheduler）
$pythonExe = (Get-Command $pythonCmd).Source

# ---------- 创建目录 ----------
Write-Host "[2/6] 创建配置目录..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path $AdapterDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# ---------- 写入适配器 ----------
Write-Host "[3/6] 写入适配器程序..." -ForegroundColor Yellow

$adapterCode = @'
#!/usr/bin/env python3
"""
Codex Universal Adapter - Responses API -> Chat Completions
Supports any OpenAI Chat Completions API compatible provider

Config: ~/.codex-adapter/config.json
{
  "upstream": "https://your-provider/v1",
  "model": "model-name",
  "api_key": "your-api-key"
}

Note: upstream only needs to go up to /v1, the adapter auto-appends /chat/completions
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
    path = config_path or CONFIG_PATH
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
        upstream = cfg.get("upstream", "").rstrip("/")
        if not upstream.endswith("/chat/completions"):
            upstream = upstream + "/chat/completions"
        return upstream, cfg.get("model", ""), cfg.get("api_key", "")
    return "", "", ""


UPSTREAM, UPSTREAM_MODEL, DEFAULT_API_KEY = "", "", ""


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
            error_msg = f"Upstream HTTP error {err.code}: {detail[:1200]}"
            data = {"choices": [{"message": {"content": error_msg}}]}
        except urllib.error.URLError as err:
            detail = str(err)
            print(f"upstream URL error: {detail}", flush=True)
            error_msg = f"Upstream connection failed: {detail[:1200]}"
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
    parser = argparse.ArgumentParser(description="Codex Universal Adapter - Responses API to Chat Completions")
    parser.add_argument("--config", default=CONFIG_PATH, help="Config file path (default: ~/.codex-adapter/config.json)")
    parser.add_argument("--port", type=int, default=PORT, help="Listen port (default: 18666)")
    args = parser.parse_args()

    UPSTREAM, UPSTREAM_MODEL, DEFAULT_API_KEY = load_config(args.config)

    if not UPSTREAM or not UPSTREAM_MODEL:
        print(f"Error: config file {args.config} missing upstream or model", flush=True)
        print(f'Expected format: {{""upstream"": ""https://xxx/v1"", ""model"": ""model-name"", ""api_key"": ""sk-xxx""}}', flush=True)
        return

    httpd = ThreadingHTTPServer((HOST, args.port), Handler)
    print(f"codex-universal-adapter listening on http://{HOST}:{args.port}", flush=True)
    print(f"config: {args.config}", flush=True)
    print(f"upstream: {UPSTREAM}", flush=True)
    print(f"model: {UPSTREAM_MODEL}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
'@

Set-Content -Path $Adapter -Value $adapterCode -Encoding UTF8
Write-Host "  OK -> $Adapter" -ForegroundColor Green

# ---------- 收集用户输入 ----------
Write-Host ""
Write-Host "  请输入你的服务商信息：" -ForegroundColor White
Write-Host ""
Write-Host "  常见服务商地址参考（只需填到 /v1）：" -ForegroundColor Cyan
Write-Host "  ┌──────────────────┬──────────────────────────────────────────────────────┐"
Write-Host "  │ 服务商            │ API 基础地址                                          │"
Write-Host "  ├──────────────────┼──────────────────────────────────────────────────────┤"
Write-Host "  │ SenseNova(商汤)   │ https://token.sensenova.cn/v1                        │"
Write-Host "  │ DeepSeek          │ https://api.deepseek.com/v1                          │"
Write-Host "  │ 硅基流动           │ https://api.siliconflow.cn/v1                        │"
Write-Host "  │ 阿里云百炼         │ https://dashscope.aliyuncs.com/compatible-mode/v1    │"
Write-Host "  │ 火山引擎(豆包)     │ https://ark.cn-beijing.volces.com/api/v3             │"
Write-Host "  │ 智谱 AI           │ https://open.bigmodel.cn/api/paas/v4                 │"
Write-Host "  │ OpenRouter        │ https://openrouter.ai/api/v1                         │"
Write-Host "  │ 生数云            │ https://router.shengsuanyun.com/v1                   │"
Write-Host "  └──────────────────┴──────────────────────────────────────────────────────┘"
Write-Host ""

$ApiUrl = Read-Host "1) API 基础地址（只需到 /v1，如 https://token.sensenova.cn/v1）"
if ([string]::IsNullOrWhiteSpace($ApiUrl)) {
    Write-Host "  错误：API 地址不能为空" -ForegroundColor Red
    exit 1
}

$ModelName = Read-Host "2) 模型名称（如 deepseek-v4-flash）"
if ([string]::IsNullOrWhiteSpace($ModelName)) {
    Write-Host "  错误：模型名称不能为空" -ForegroundColor Red
    exit 1
}

$ApiKeySec = Read-Host "3) API 密钥" -AsSecureString
$ApiKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ApiKeySec)
)
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    Write-Host "  错误：API 密钥不能为空" -ForegroundColor Red
    exit 1
}

# ---------- 写入配置 ----------
Write-Host "[4/6] 写入配置文件..." -ForegroundColor Yellow
$configObj = @{
    upstream = $ApiUrl
    model    = $ModelName
    api_key  = $ApiKey
} | ConvertTo-Json
Set-Content -Path $Config -Value $configObj -Encoding UTF8
Write-Host "  OK -> $Config" -ForegroundColor Green

# ---------- 注册开机自启（Task Scheduler）----------
Write-Host "[5/6] 注册开机自启服务..." -ForegroundColor Yellow

# 先删除旧任务（如果存在）
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

# 创建 Action
$action = New-ScheduledTaskAction -Execute $pythonExe -Argument "`"$Adapter`"" -WorkingDirectory $AdapterDir

# 创建 Trigger（用户登录时启动）
$trigger = New-ScheduledTaskTrigger -AtLogOn

# 创建 Settings
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

# 注册任务
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description "Codex Universal Adapter - Responses API to Chat Completions" -Force | Out-Null

# 立即启动
Start-ScheduledTask -TaskName $TaskName

Start-Sleep -Seconds 2

# 验证任务状态
$taskState = (Get-ScheduledTask -TaskName $TaskName).State
Write-Host "  OK -> 任务状态: $taskState" -ForegroundColor Green

# ---------- 配置 Codex ----------
Write-Host "[6/6] 配置 Codex..." -ForegroundColor Yellow

# Windows 上 Codex 的配置路径
$CodexDir = Join-Path $env:APPDATA "codex"
if (-not (Test-Path $CodexDir)) {
    # 兜底：尝试用户目录
    $CodexDir = Join-Path $env:USERPROFILE ".codex"
}
New-Item -ItemType Directory -Force -Path $CodexDir | Out-Null

$CodexConfig = Join-Path $CodexDir "config.toml"
if (Test-Path $CodexConfig) {
    $backupName = "config.toml.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
    Copy-Item $CodexConfig (Join-Path $CodexDir $backupName)
}

$tomlContent = @"
model = "$ModelName"
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
"@
Set-Content -Path $CodexConfig -Value $tomlContent -Encoding UTF8

# 写入 auth.json
$CodexAuth = Join-Path $CodexDir "auth.json"
$authObj = @{
    OPENAI_API_KEY = $ApiKey
} | ConvertTo-Json
Set-Content -Path $CodexAuth -Value $authObj -Encoding UTF8

Write-Host "  OK -> $CodexConfig" -ForegroundColor Green

# ---------- 完成 ----------
Start-Sleep -Seconds 2

# 验证适配器是否启动
$healthOk = $false
try {
    $response = Invoke-WebRequest -Uri "http://127.0.0.1:18666/health" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
    $healthOk = ($response.Content -eq '{"ok":true}')
} catch {}

Write-Host ""
Write-Host "  安装完成！" -ForegroundColor Green
Write-Host ""
Write-Host "  适配器状态：$(if ($healthOk) { '{"ok":true}' } else { '{"ok":false} - 请稍等几秒后重试' })"
Write-Host "  上游地址：$ApiUrl"
Write-Host "  模型名称：$ModelName"
Write-Host ""
Write-Host "  下一步：重启 Codex 即可使用" -ForegroundColor White
Write-Host ""
Write-Host "  常用命令：" -ForegroundColor Cyan
Write-Host "    查看状态：Invoke-WebRequest http://127.0.0.1:18666/health"
Write-Host "    查看模型：Invoke-WebRequest http://127.0.0.1:18666/v1/models"
Write-Host "    修改配置：记事本 $Config"
Write-Host "    重启适配器：Restart-ScheduledTask -TaskName `"$TaskName`""
Write-Host ""
Write-Host "  卸载命令：" -ForegroundColor Cyan
Write-Host "    Unregister-ScheduledTask -TaskName `"$TaskName`" -Confirm:`$false; Remove-Item -Recurse -Force `"$AdapterDir`""
Write-Host ""
