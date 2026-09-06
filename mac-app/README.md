# 时光番茄 (ShiguangTomato)

macOS 菜单栏番茄钟，完成的番茄以**原生「专注记录」**同步到时光序（未来助手）的「番茄专注」模块，与手机端 / 网页端完全一致（含专注统计）。

配套项目：[wahahaorg/shiguangxu-mcp](https://github.com/wahahaorg/shiguangxu-mcp)（时光序日程/备忘录 MCP）。

## 功能

- 🍅 菜单栏倒计时：开始专注 / 暂停继续 / 放弃 / 休息，倒计时直接显示在菜单栏
- ☁️ **原生专注同步**：每个完成的番茄通过 `/base/focus/v3/repeat/addFocusRecord` 写入时光序，出现在「番茄专注」的记录与统计里
- 🔁 可选择同步到哪个专注任务（自动拉取账号下的任务列表，优先番茄钟类型）
- 📴 离线队列：断网时记录先存本地（`history.json`），恢复后自动补传
- 📊 菜单同时显示 今日本地统计 + 时光序服务端统计
- ⚙️ 纯 Swift + AppKit/SwiftUI，无第三方依赖，通用二进制（arm64 + Intel）

## 构建与安装

```bash
./build.sh          # 需要 Xcode Command Line Tools (swiftc)
open dist/时光番茄.app
```

产物在 `dist/`：`时光番茄.app`、zip、dmg。未签名分发到其他机器时先执行：

```bash
xattr -cr 时光番茄.app   # 或右键 → 打开
```

## 配置

首次启动自动弹出设置窗口：

| 配置 | 说明 |
|---|---|
| 手机号 / 密码 | 时光序账号（明文登录，与 shiguangxu-mcp 相同方式） |
| API 地址 | 默认 `https://api.weilaizhushou.com` |
| 同步到 | 账号下的专注任务（「番茄专注 → 多次专注」里创建），不选则仅本地记录 |
| 计时 | 默认专注时长 / 休息时长 / 自动休息 / 提示音 |

配置文件：`~/Library/Application Support/ShiguangTomato/config.json`（权限 0600）。
token 自动缓存、过期自动重登。开启同步时，专注/休息时长跟随所选任务的配置。

## 时光序专注（番茄钟）接口备忘

以下接口均从 `web.shiguangxu.com` 前端逆向并实测通过（POST JSON，鉴权头 `token`/`sid`，`channel-type: SGX`）：

| 接口 | 说明 |
|---|---|
| `/base/focus/v3/repeat/list` | 专注任务列表，传 `{}`，返回 `data.unFinishList` + `data.finishList` |
| `/base/focus/v3/repeat/addFocusRecord` | 写入一条专注记录 |
| `/base/focus/v3/giveup/add` | 写入一条放弃记录（请求体同上） |
| `/base/focus/v3/statistic/recordList` | 专注记录列表，`{pageNum, pageSize, beginDate, endDate, type:"DAY"}`，**日期格式 `yyyyMMdd`** |
| `/base/focus/v3/statistic/dayBarChart` / `barChart` / `pieChart` | 统计图表 |
| `/base/focus/v2/detail` / `v2/update` / `update_remark` / `del` | 记录详情 / 更新 / 改备注 / 删除 `{id}` |
| `/base/focus/v3/repeat/add` / `update` / `delete` / `updateStatus` | 专注任务的增删改 |

`addFocusRecord` 请求体：

```json
{
  "repeatId": "任务id",
  "focusType": 3,
  "title": "任务标题",
  "fullTime": 25,
  "focusNum": 3,
  "useTime": 25,
  "startTime": "20260906150000",
  "endTime": "20260906152500",
  "remark": "",
  "eventList": [
    {"eventType": 5, "focusMinute": 0,  "content": "开始: 第1个番茄钟", "eventTime": "20260906150000", "startTime": "15:00", "surplusTime": 1500, "residueCount": 1500, "focusNum": 3, "allFocusTime": 0},
    {"eventType": 3, "focusMinute": 25, "content": "完成番茄钟",       "eventTime": "20260906152500", "startTime": "15:25", "surplusTime": 0,    "residueCount": 0,    "focusNum": 3, "allFocusTime": 1500}
  ]
}
```

`focusType`：`1`=倒计时专注，`2`=正计时专注，`3`=番茄钟专注。事件类型：`3`=完成番茄钟，`4`=开始休息，`5`=开始第 N 个番茄钟，`6`=延长专注（暂停事件 content 为「暂停」，带 `pasuseTime`）。

## 免责声明

本项目仅用于个人自动化学习与使用，与时光序官方无关。请遵守时光序服务条款，勿滥用接口。
