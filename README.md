# 时光序 MCP 服务器

时光序（未来助手）日程/备忘录的 MCP (Model Context Protocol) 服务器，提供 JSON-RPC stdio 接口，可接入 Claude Desktop / Codex / Hermes 等支持 MCP 的 AI 客户端。

## 功能

| 工具 | 说明 |
|---|---|
| `memo_add` | 创建备忘录 |
| `diary_add` | 创建日程（全天/时间点/时间段） |
| `diary_list` | 查询日程（今天/指定日期/日期范围） |
| `diary_complete` | 完成日程 |
| `diary_delete` | 删除日程 |

## 安装

```bash
pip install -r requirements.txt  # 如无依赖文件则无需安装，纯标准库
```

## 配置

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

## 使用

```bash
python mcp_server.py
```

### 接入 MCP 客户端

```bash
# Claude Desktop / Codex CLI
claude mcp add --transport stdio --name shiguangxu -- python /path/to/mcp_server.py

# Hermes
hermes mcp add shiguangxu --command python --args /path/to/mcp_server.py
```

## 测试

```bash
# 列出工具
printf '{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n' | python mcp_server.py

# 调用工具
printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"diary_list","arguments":{}}}\n' | python mcp_server.py
```

## 技术说明

- 纯 Python 标准库实现，无第三方依赖
- 登录 token 自动缓存复用，过期自动刷新
- 日程列表单次查询上限 31 天（防海量请求）

## 免责声明

本项目仅用于个人自动化学习与使用，与时光序官方无关。请遵守时光序服务条款，勿滥用接口。
