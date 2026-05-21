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
| 讯飞星辰 | `https://maas-coding-api.cn-huabei-1.xf-yun.com/v2` | Coding Plan 3.9元/月起 |

## 前置条件

1. 已安装 [CC Switch](https://github.com/nicepkg/cc-switch)（76K Star 开源项目）
2. 已打开过一次 CC Switch
3. 已安装 Codex
4. 已有某个服务商的 API Key
5. macOS（Windows 理论上也支持，但未验证）

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/EvolutionWayen/codex-universal-adapter/main/install.sh)
```

执行后按提示输入 3 样东西：

1. **API 基础地址**（只需到 `/v1`，如 `https://token.sensenova.cn/v1`）
2. **模型名称**（如 `deepseek-v4-flash`）
3. **API 密钥**（输入时不显示明文）

输完自动配置，重启 Codex 即可使用。

## 换服务商

只需修改配置文件，重启服务即可：

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

## 卸载

```bash
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.codex-universal-adapter.plist
rm -rf ~/.codex-adapter
```

## 常用命令

```bash
# 查看适配器状态
curl http://127.0.0.1:18666/health

# 查看当前模型
curl http://127.0.0.1:18666/v1/models

# 查看日志
cat ~/.codex-adapter/logs/adapter.log
```

## 文件说明

| 文件 | 说明 |
|------|------|
| `adapter.py` | 适配器核心程序，Responses API ↔ Chat Completions 协议转换 |
| `install.sh` | macOS 一键安装脚本 |

## 致谢

- 原始灵感来自 [袋鼠帝AI客栈](https://space.bilibili.com/) 的讯飞适配器方案
- 本项目将方案通用化，支持任何 Chat Completions 兼容的服务商

## License

MIT
