# 时光序工具集（shiguangxu）

对接时光序（未来助手）非官方接口的个人工具集合：

| 模块 | 说明 |
|---|---|
| **MCP 服务器**（本目录 `mcp_server.py`） | 日程 / 备忘录 / 清单 / 番茄专注的 MCP (Model Context Protocol) 服务器，JSON-RPC over stdio，可接入 Claude Desktop / Codex / Hermes 等 AI 客户端 |
| **时光番茄 Mac 应用**（[`mac-app/`](mac-app/)） | macOS 菜单栏番茄钟，完成的番茄以**原生专注记录**同步到时光序「番茄专注」，含统计；DMG 在 [Releases](../../releases) 下载 |

两部分使用同一套账号配置与接口封装：登录 `/base/user/v2/login`（明文密码 + 设备信息，token 自动缓存、过期自动重登），请求头 `channel-type: SGX`。

## MCP 服务器

### 功能

| 工具 | 说明 |
|---|---|
| `memo_add` | 创建备忘录 |
| `diary_add` | 创建日程（全天/时间点/时间段） |
| `diary_list` | 查询日程（今天/指定日期/日期范围） |
| `diary_complete` | 完成日程 |
| `diary_delete` | 删除日程 |
| `memo_list` | 查询备忘录列表 |
| `todo_add` / `todo_list` / `todo_complete` / `todo_delete` | 清单事项（无日期待办） |
| `focus_list` | 查询「番茄专注」任务列表 |
| `focus_record_add` | 写入一条已完成的专注/番茄钟记录（原生专注记录） |
| `focus_records` | 查询专注记录（今天/单日/日期范围，含合计分钟） |
| `focus_delete` | 删除专注记录 |

### 安装

```bash
pip install -r requirements.txt  # 如无依赖文件则无需安装，纯标准库
```

### 配置

复制 `config.example.json` 为 `config.json` 并填写：

```json
{
  "api_base": "https://api.weilaizhushou.com",
  "mobile": "你的手机号",
  "password": "你的密码",
  "token": "",           // 可选，留空则用 mobile/password 登录
  "classify_id": ""      // 可选，备忘录默认分类
}
```

也支持环境变量（优先于配置文件）：`SHIGUANGXU_TOKEN`、`SHIGUANGXU_MOBILE`、`SHIGUANGXU_PASSWORD`、`SHIGUANGXU_CLASSIFY_ID`、`SHIGUANGXU_API_BASE`。

> ⚠️ `config.json` 已被 `.gitignore` 排除，不会提交到仓库。请勿把真实凭据提交到 GitHub。

### 使用

```bash
python mcp_server.py
```

#### 接入 MCP 客户端

```bash
# Claude Desktop / Codex CLI
claude mcp add --transport stdio --name shiguangxu -- python /path/to/mcp_server.py

# Hermes
hermes mcp add shiguangxu --command python --args /path/to/mcp_server.py
```

### 测试

```bash
# 列出工具
printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n' | python mcp_server.py

# 调用工具
printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"diary_list","arguments":{}}}\n' | python mcp_server.py
```

### 技术说明

- 纯 Python 标准库实现，无第三方依赖
- 登录 token 自动缓存复用，过期自动刷新
- 日程列表单次查询上限 31 天（防海量请求）
- 番茄专注接口（`/base/focus/*`）逆向自 `web.shiguangxu.com` 前端，请求体结构见 [`mac-app/README.md`](mac-app/README.md) 的「接口备忘」一节

## 时光番茄 Mac 应用

macOS 菜单栏番茄钟：开始专注 / 暂停 / 休息，倒计时显示在菜单栏；每个完成的番茄通过
`/base/focus/v3/repeat/addFocusRecord` 写入时光序原生「番茄专注」记录（手机端/网页端可见，含统计）；
支持离线队列自动补传。纯 Swift 实现（arm64 + Intel），详见 [`mac-app/README.md`](mac-app/README.md)。

```bash
cd mac-app && ./build.sh   # 产物在 mac-app/dist/
```

## 免责声明

本项目仅用于个人自动化学习与使用，与时光序官方无关。请遵守时光序服务条款，勿滥用接口。
