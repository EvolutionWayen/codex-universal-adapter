# Codex Universal Adapter

> 让 Codex 使用任何兼容 OpenAI Chat Completions API 的模型，一键安装。

## 原理

Codex 使用 OpenAI **Responses API** 协议，但国内大部分模型服务商只支持 **Chat Completions API**。这个适配器跑在你电脑上，充当"翻译官"：

```
Codex → [Responses API] → 本地适配器(127.0.0.1:18666) → [Chat Completions API] → 你的服务商
Codex ← [Responses API] ← 本地适配器                    ← [Chat Completions API] ← 你的服务商
```

Codex 以为自己还在跟 OpenAI 聊天，其实背后已经是国内模型在回答了。

## 支持的服务商

任何兼容 OpenAI Chat Completions API 的服务商都可以，包括但不限于：

| 服务商 | API 基础地址 | 备注 |
|--------|-------------|------|
| SenseNova（商汤） | `https://token.sensenova.cn/v1` | 支持 deepseek-v4-flash 等 |
| DeepSeek | `https://api.deepseek.com/v1` | 编程能力强 |
| 硅基流动 | `https://api.siliconflow.cn/v1` | 有免费额度 |
| 阿里云百炼 | `https://dashscope.aliyuncs.com/compatible-mode/v1` | 通义系列 |
| 火山引擎（豆包） | `https://ark.cn-beijing.volces.com/api/v3` | 字节系 |
| 智谱 AI | `https://open.bigmodel.cn/api/paas/v4` | GLM 系列 |
| OpenRouter | `https://openrouter.ai/api/v1` | 聚合多家模型 |
| 生数云 | `https://router.shengsuanyun.com/v1` | |
| 讯飞星辰 | `https://maas-coding-api.cn-huabei-1.xf-yun.com/v2` | Coding Plan 3.9元/月起 |

## 前置条件

1. 已安装 [CC Switch](https://github.com/nicepkg/cc-switch)（76K Star 开源项目）
2. 已打开过一次 CC Switch
3. 已安装 Codex
4. 已有某个服务商的 API Key

## 一键安装

### macOS

**国内用户（推荐，速度快）**：
```bash
bash <(curl -fsSL https://gitee.com/Evolutionwayen/codex-universal-adapter/raw/main/install.sh)
```

**海外用户**：
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/EvolutionWayen/codex-universal-adapter/main/install.sh)
```

执行后按提示输入 3 样东西：

1. **API 基础地址**（只需到 `/v1`，如 `https://token.sensenova.cn/v1`）
2. **模型名称**（如 `deepseek-v4-flash`）
3. **API 密钥**（输入时不显示明文）

输完自动配置，重启 Codex 即可使用。

### Windows

**国内用户（推荐）**：
```powershell
irm https://gitee.com/Evolutionwayen/codex-universal-adapter/raw/main/install-windows.ps1 | iex
```

**海外用户**：
```powershell
irm https://raw.githubusercontent.com/EvolutionWayen/codex-universal-adapter/main/install-windows.ps1 | iex
```

> ⚠️ 如果执行策略阻止脚本运行，先执行 `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned`

执行后同样按提示输入 API 地址、模型名称和 API 密钥。

## 换服务商

### 方式一：修改配置文件（macOS）

```bash
# 编辑配置
nano ~/.codex-adapter/config.json
```

```json
{
  "upstream": "https://api.deepseek.com/v1",
  "model": "deepseek-chat",
  "api_key": "sk-你的新key"
}
```

```bash
# 重启适配器
launchctl kickstart -k "gui/$(id -u)/com.codex-universal-adapter"
```

### 方式二：修改配置文件（Windows）

编辑 `%USERPROFILE%\.codex-adapter\config.json`，修改后重启适配器：

```powershell
Restart-Service codex-universal-adapter
```

### 方式三：多端口模式（CC Switch 切换）

如果你同时使用多个服务商，可以启动多个适配器实例，每个绑定不同端口，通过 CC Switch 一键切换：

| 服务商 | 端口 | 配置文件 |
|--------|------|----------|
| 商汤 SenseNova | 18666 | `~/.codex-adapter/config-sensenova.json` |
| DeepSeek | 18667 | `~/.codex-adapter/config-deepseek.json` |
| 硅基流动 | 18668 | `~/.codex-adapter/config-siliconflow.json` |
| 生数云 | 18669 | `~/.codex-adapter/config-shengsuanyun.json` |

每个配置文件格式相同：
```json
{
  "upstream": "https://api.deepseek.com/v1",
  "model": "deepseek-chat",
  "api_key": "sk-你的key"
}
```

适配器支持 `--config` 和 `--port` 参数指定配置和端口：
```bash
python3 codex-adapter.py --config ~/.codex-adapter/config-deepseek.json --port 18667
```

在 CC Switch 中为每个服务商创建对应的 provider，`base_url` 指向对应端口（如 `http://127.0.0.1:18667/v1`），切换时一键生效。

## 卸载

### macOS
```bash
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.codex-universal-adapter.plist
rm -rf ~/.codex-adapter
```

### Windows
```powershell
Unregister-ScheduledTask -TaskName "codex-universal-adapter" -Confirm:$false
Remove-Item -Recurse -Force "$env:USERPROFILE\.codex-adapter"
```

## 常用命令

### macOS
```bash
# 查看适配器状态
curl http://127.0.0.1:18666/health

# 查看当前模型
curl http://127.0.0.1:18666/v1/models

# 查看日志
cat ~/.codex-adapter/logs/adapter.log
```

### Windows
```powershell
# 查看适配器状态
Invoke-RestMethod http://127.0.0.1:18666/health

# 查看当前模型
Invoke-RestMethod http://127.0.0.1:18666/v1/models

# 查看日志
Get-Content "$env:USERPROFILE\.codex-adapter\logs\adapter.log" -Tail 20
```

## 文件说明

| 文件 | 说明 |
|------|------|
| `adapter.py` | 适配器核心程序，Responses API ↔ Chat Completions 协议转换 |
| `install.sh` | macOS 一键安装脚本 |
| `install-windows.ps1` | Windows 一键安装脚本 |

## 常见问题

### Q: API 地址填到哪一级？
A: 只需填到 `/v1`（如 `https://token.sensenova.cn/v1`），适配器会自动拼接 `/chat/completions`。如果你填了完整路径也能兼容。

### Q: 报错「401 Authentication Fails」
A: API Key 不正确。检查 `~/.codex-adapter/config.json` 中的 `api_key` 是否填写正确。

### Q: Codex 启动后连接失败
A: 检查适配器是否在运行：`curl http://127.0.0.1:18666/health`。如果返回 `{"ok":true}` 说明适配器正常，问题可能在 Codex 配置。

### Q: CC Switch 切换后 Codex 崩溃
A: 确保 CC Switch 中 provider 的 id 与 `config.toml` 中的 `[model_providers.xxx]` 名称一致。如果不一致，Codex 找不到对应 provider 会直接崩溃。

## 致谢

- 原始灵感来自 [袋鼠帝AI客栈](https://space.bilibili.com/) 的讯飞适配器方案
- 本项目将方案通用化，支持任何 Chat Completions 兼容的服务商

## License

MIT
