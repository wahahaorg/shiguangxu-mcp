"""时光序日程 MCP 服务（JSON-RPC 2.0 over stdio）。

标准输出只写 MCP 消息；所有诊断信息写标准错误。
"""

from __future__ import annotations

import html
import json
import os
import re
import sys
import urllib.error
import urllib.request
import uuid
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any

BASE_DIR = Path(__file__).resolve().parent
CONFIG_PATH = Path(os.getenv("SHIGUANGXU_CONFIG", BASE_DIR / "config.json"))
DEFAULT_API_BASE = "https://api.weilaizhushou.com"
PROTOCOL_VERSION = "2025-06-18"
SERVER_INFO = {"name": "shiguangxu", "version": "1.0.0"}
API_VERSION = "3.20.1"
MAX_QUERY_DAYS = 31

TOOLS = [
    {
        "name": "memo_add",
        "description": "在时光序备忘录中创建一条文字笔记（不是日程）。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "content": {"type": "string", "description": "备忘录正文，按纯文本写入"},
                "title": {"type": "string", "description": "可选标题，默认使用“无标题备忘”"},
            },
            "required": ["content"],
            "additionalProperties": False,
        },
    },
    {
        "name": "diary_add",
        "description": "在时光序中创建一条日程（不是日记正文）。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "title": {"type": "string", "description": "日程标题"},
                "datetime": {
                    "type": "string",
                    "description": "日期时间，如 2026-08-17 09:30 或 ISO 8601",
                },
                "remark": {"type": "string", "description": "可选备注"},
            },
            "required": ["title", "datetime"],
            "additionalProperties": False,
        },
    },
    {
        "name": "diary_delete",
        "description": "按 ID 删除一条时光序日程。",
        "inputSchema": {
            "type": "object",
            "properties": {"id": {"type": ["string", "integer"], "description": "日程 ID"}},
            "required": ["id"],
            "additionalProperties": False,
        },
    },
    {
        "name": "diary_complete",
        "description": "按 ID 将一条时光序日程标记为完成。",
        "inputSchema": {
            "type": "object",
            "properties": {"id": {"type": ["string", "integer"], "description": "日程 ID"}},
            "required": ["id"],
            "additionalProperties": False,
        },
    },
    {
        "name": "diary_list",
        "description": (
            "查询时光序日程列表。三种模式：\n"
            "1. 不传任何参数 → 查询全部日程（自动分页拉取所有）\n"
            "2. 传 date → 查询指定单日\n"
            "3. 传 start_date + end_date → 查询日期范围（上限 31 天）"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "date": {"type": "string", "description": "可选日期，格式 YYYY-MM-DD；查询单日"},
                "start_date": {"type": "string", "description": "可选开始日期，格式 YYYY-MM-DD"},
                "end_date": {"type": "string", "description": "可选结束日期，格式 YYYY-MM-DD"},
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "memo_list",
        "description": "查询时光序备忘录列表，返回所有备忘录或按分类筛选。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "folder_id": {"type": "string", "description": "可选，按备忘录分类 ID 筛选"},
                "keyword": {"type": "string", "description": "可选，按关键词搜索备忘录"},
                "page": {"type": "integer", "description": "可选，页码，默认 1"},
                "page_size": {"type": "integer", "description": "可选，每页条数，默认 50"},
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "todo_add",
        "description": "在时光序中创建一条清单事项（无日期的待办，todoType=3）。与日程不同，清单事项没有时间节点。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "title": {"type": "string", "description": "清单事项标题，如'洗床单被罩'"},
                "remark": {"type": "string", "description": "可选备注"},
                "classify_id": {"type": "string", "description": "可选，日程分类 ID；不传则使用默认分类"},
            },
            "required": ["title"],
            "additionalProperties": False,
        },
    },
    {
        "name": "todo_list",
        "description": "查询时光序清单事项列表（无日期的待办，todoType=3），返回所有清单事项。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "include_completed": {
                    "type": "boolean",
                    "description": "可选，是否包含已完成事项，默认 true",
                },
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "todo_complete",
        "description": "按 ID 将一条清单事项（todoType=3）标记为完成。",
        "inputSchema": {
            "type": "object",
            "properties": {"id": {"type": ["string", "integer"], "description": "清单事项 ID"}},
            "required": ["id"],
            "additionalProperties": False,
        },
    },
    {
        "name": "todo_delete",
        "description": "按 ID 删除一条或多条清单事项（todoType=3）。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "ids": {
                    "type": "array",
                    "items": {"type": ["string", "integer"]},
                    "description": "要删除的清单事项 ID 列表",
                },
            },
            "required": ["ids"],
            "additionalProperties": False,
        },
    },
    {
        "name": "focus_list",
        "description": "查询时光序「番茄专注」模块的专注任务列表（含专注时长/休息时长/番茄个数配置）。",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "focus_record_add",
        "description": (
            "向时光序「番茄专注」写入一条已完成的专注记录（原生专注记录，与 App/网页端一致）。"
            "默认写入第一个番茄钟类型的任务，默认结束时间为现在、开始时间 = 结束时间 - minutes。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "minutes": {"type": "number", "description": "专注时长（分钟），>=1"},
                "task_id": {"type": ["string", "integer"], "description": "可选，专注任务 ID；不传则自动选第一个番茄钟任务"},
                "start": {"type": "string", "description": "可选开始时间，如 2026-09-06 15:00；默认结束时间往前推 minutes"},
                "end": {"type": "string", "description": "可选结束时间，默认现在"},
                "remark": {"type": "string", "description": "可选备注"},
            },
            "required": ["minutes"],
            "additionalProperties": False,
        },
    },
    {
        "name": "focus_records",
        "description": "查询时光序专注记录（可查今天/单日/日期范围，上限 31 天），返回每条时长与合计分钟数。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "date": {"type": "string", "description": "可选日期，格式 YYYY-MM-DD；默认今天"},
                "start_date": {"type": "string", "description": "可选开始日期 YYYY-MM-DD"},
                "end_date": {"type": "string", "description": "可选结束日期 YYYY-MM-DD"},
                "page_size": {"type": "integer", "description": "可选，返回条数上限，默认 50"},
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "focus_delete",
        "description": "按 ID 删除一条专注记录。",
        "inputSchema": {
            "type": "object",
            "properties": {"id": {"type": ["string", "integer"], "description": "专注记录 ID"}},
            "required": ["id"],
            "additionalProperties": False,
        },
    },
]


class ShiguangxuError(RuntimeError):
    """可展示给 MCP 调用方的接口错误。"""


def _load_config() -> dict[str, Any]:
    config: dict[str, Any] = {}
    if CONFIG_PATH.is_file():
        try:
            value = json.loads(CONFIG_PATH.read_text(encoding="utf-8-sig"))
            if not isinstance(value, dict):
                raise ValueError("配置根节点必须是对象")
            config.update(value)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            raise ShiguangxuError(f"配置文件读取失败：{exc}") from exc
    env_map = {
        "api_base": "SHIGUANGXU_API_BASE",
        "mobile": "SHIGUANGXU_MOBILE",
        "password": "SHIGUANGXU_PASSWORD",
        "token": "SHIGUANGXU_TOKEN",
        "classify_id": "SHIGUANGXU_CLASSIFY_ID",
    }
    for key, env_name in env_map.items():
        if os.getenv(env_name):
            config[key] = os.environ[env_name]
    return config


class ShiguangxuClient:
    def __init__(self, config: dict[str, Any]) -> None:
        self.config = config
        self.api_base = str(config.get("api_base") or DEFAULT_API_BASE).rstrip("/")
        self.token = str(config.get("token") or "").strip()

    def _request(self, path: str, data: dict[str, Any], *, authenticated: bool = True, _retried: bool = False) -> dict[str, Any]:
        if authenticated and not self.token:
            self.login()
        headers = {
            "Content-Type": "application/json; charset=utf-8",
            "Accept": "application/json",
            "channel-type": "SGX",
            "version": API_VERSION,
        }
        if authenticated:
            headers["token"] = self.token
            headers["sid"] = self.token
        request = urllib.request.Request(
            self.api_base + path,
            data=json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                body = response.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as exc:
            if authenticated and not _retried and exc.code in (401, 403):
                self.token = ""
                self.login()
                return self._request(path, data, authenticated=authenticated, _retried=True)
            body = exc.read().decode("utf-8", errors="replace")
            try:
                detail = json.loads(body).get("msg") or body
            except json.JSONDecodeError:
                detail = body
            raise ShiguangxuError(f"接口 HTTP {exc.code}：{detail}") from exc
        except urllib.error.URLError as exc:
            raise ShiguangxuError(f"无法连接时光序接口：{exc.reason}") from exc
        try:
            result = json.loads(body)
        except json.JSONDecodeError as exc:
            raise ShiguangxuError("时光序接口返回了非 JSON 数据") from exc
        if not isinstance(result, dict):
            raise ShiguangxuError("时光序接口返回格式异常")
        if result.get("code") != 200:
            msg = str(result.get("msg") or "")
            code = result.get("code")
            # Token 过期/失效时自动重新登录并重试一次
            if (
                authenticated
                and not _retried
                and (
                    code in (401, 403, 10001, 10002, -1)
                    or any(kw in msg for kw in ("token", "Token", "登录", "过期", "失效"))
                )
            ):
                self.token = ""
                self.login()
                return self._request(path, data, authenticated=authenticated, _retried=True)
            raise ShiguangxuError(f"时光序接口错误 {code}：{msg or '未知错误'}")
        return result

    def login(self) -> None:
        mobile = str(self.config.get("mobile") or "").strip()
        password = str(self.config.get("password") or "")
        if not mobile or not password:
            raise ShiguangxuError(
                "未登录：请在 config.json 配置 token，或配置 mobile/password（也可使用 SHIGUANGXU_* 环境变量）"
            )
        now = datetime.now()
        device = {
            "channel": "WEB",
            "channelName": "时光序_web",
            "deviceTagApp": "WEB",
            "deviceType": "5",
            "appVersion": "1.0.0",
            "deviceModel": "web",
            "channelType": "SGX",
            "deviceTag": f"WEB{now.year}{now.month}{now.day}{uuid.uuid4().hex}",
        }
        result = self._request(
            "/base/user/v2/login",
            {"mobile": mobile, "password": password, "type": "1", "appType": "5", "device": device},
            authenticated=False,
        )
        data = result.get("data") or {}
        self.token = str(data.get("token") or data.get("userToken") or "")
        if not self.token:
            raise ShiguangxuError("登录成功，但响应中没有 token")

    def _classify_id(self) -> str:
        configured = str(self.config.get("classify_id") or "").strip()
        if configured:
            return configured
        result = self._request(
            "/service/aggregation/todo/classify/v3/list",
            {"classifyVersion": "4", "matterClassifyVersion": "4"},
        )
        items = (result.get("data") or {}).get("list") or []
        if not items:
            raise ShiguangxuError("账号没有可用的日程分类，请先在时光序中创建分类")
        return str(items[0]["classifyId"])

    def _memo_folder_id(self) -> str:
        """取得网页端创建备忘录时默认使用的第一个普通分类。"""
        result = self._request("/base/summary/folder/v2/superFolderAndClassifyList", {})
        folders = (result.get("data") or {}).get("summaryFolderList") or []
        for folder in folders:
            if not isinstance(folder, dict):
                continue
            if folder.get("folderType") != "super_folder" and folder.get("id"):
                return str(folder["id"])
            for child in folder.get("subClassifyList") or []:
                if isinstance(child, dict) and child.get("id"):
                    return str(child["id"])
        raise ShiguangxuError("账号没有可用的备忘录分类，请先在时光序中创建分类")

    def memo_add(self, content: Any, title: Any = None) -> dict[str, Any]:
        if not isinstance(content, str) or not content.strip():
            raise ValueError("content 必须是非空字符串")
        if title is not None and not isinstance(title, str):
            raise ValueError("title 必须是字符串")

        # 此接口保存富文本；工具对外接收纯文本，转义后再保留换行，避免把输入当 HTML 执行。
        rich_text = html.escape(content.strip()).replace("\r\n", "\n").replace("\r", "\n").replace("\n", "<br>")
        memo_title = title.strip() if isinstance(title, str) and title.strip() else "无标题备忘"
        payload = {
            "annexList": [],
            "folderId": self._memo_folder_id(),
            "frontEditorVersion": "4",
            "gpsName": "",
            "gpsX": "",
            "gpsY": "",
            "richTextContent": f"<p>{rich_text}</p>",
            "tagIdList": [],
            "title": memo_title,
        }
        return self._request("/base/summary/v2/add", payload)

    @staticmethod
    def _format_datetime(value: Any) -> str:
        if not isinstance(value, str) or not value.strip():
            raise ValueError("datetime 必须是非空字符串")
        text = value.strip()
        if len(text) == 14 and text.isdigit():
            datetime.strptime(text, "%Y%m%d%H%M%S")
            return text
        try:
            parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
        except ValueError as exc:
            raise ValueError("datetime 格式无效，请使用 YYYY-MM-DD HH:MM 或 ISO 8601") from exc
        return parsed.strftime("%Y%m%d%H%M%S")

    def add(self, title: Any, datetime_value: Any, remark: Any = "") -> dict[str, Any]:
        if not isinstance(title, str) or not title.strip():
            raise ValueError("title 必须是非空字符串")
        if not isinstance(remark, str):
            raise ValueError("remark 必须是字符串")
        todo_time = self._format_datetime(datetime_value)
        record = {
            # SPA 的 uuid() 实际是从 1 开始递增的数字，不是 UUID 字符串。
            "localId": 1,
            "todoType": 1,
            "importance": 2,
            "shortTitle": title.strip(),
            "title": title.strip(),
            "attachments": [],
            "todoClassifyId": self._classify_id(),
            "address": "",
            "remark": remark,
            "longitude": "",
            "latitude": "",
            "sonDeleteList": [],
            "sonAddList": [],
            "sonUpdateList": [],
            "aheadType": [{"offset": 0}],
            "intervalType": 1,
            "todoTime": todo_time,
        }
        return self._request("/base/plan/record/add", record)

    def delete(self, item_id: Any) -> dict[str, Any]:
        if isinstance(item_id, bool) or not isinstance(item_id, (str, int)) or not str(item_id).strip():
            raise ValueError("id 必须是非空字符串或整数")
        return self._request("/base/plan/delete", {"deleteInfos": [{"id": str(item_id)}]})

    def complete(self, item_id: Any) -> dict[str, Any]:
        if isinstance(item_id, bool) or not isinstance(item_id, (str, int)) or not str(item_id).strip():
            raise ValueError("id 必须是非空字符串或整数")
        item_id = str(item_id)
        query_time = datetime.now().strftime("%Y%m%d%H%M%S")
        detail = self._request(
            "/base/plan/record/getinfo",
            {"id": item_id, "todoType": 1, "todoTime": query_time, "theDateTime": query_time},
        )
        data = detail.get("data") or {}
        todo_time = data.get("todoTime") or data.get("startDatetime") or data.get("startDateTime")
        if not todo_time:
            raise ShiguangxuError("已找到日程，但响应中缺少 todoTime，无法完成")
        return self._request(
            "/base/plan/checkin",
            {"finishState": 1, "todoId": item_id, "todoTime": todo_time},
        )

    @staticmethod
    def _parse_date(value: Any, name: str) -> date:
        if not isinstance(value, str) or not value.strip():
            raise ValueError(f"{name} 必须是 YYYY-MM-DD 格式的非空字符串")
        try:
            return datetime.strptime(value.strip(), "%Y-%m-%d").date()
        except ValueError as exc:
            raise ValueError(f"{name} 格式无效，请使用 YYYY-MM-DD") from exc

    def _is_empty(self, value: Any) -> bool:
        """判断参数是否为空（None 或空字符串）。"""
        return value is None or (isinstance(value, str) and not value.strip())

    def _list_all_diaries(self) -> dict[str, Any]:
        """全量查询：循环分页拉取所有日程，返回精简列表。"""
        MAX_PAGES = 100  # 安全上限，防止无限循环（最多 20000 条）
        # recordview 接口要求 theDateTime 必填（否则 601 validate.theDay.notnull），
        # 但该字段不影响返回范围——无论传什么日期，接口都返回全量日程。
        the_date_time = datetime.now().strftime("%Y%m%d120000")
        found: dict[str, dict[str, Any]] = {}
        page = 1
        while page <= MAX_PAGES:
            result = self._request(
                "/base/plan/record/recordview",
                {
                    "currentPage": page,
                    "pageSize": 200,
                    "isAllInfo": False,
                    "keyword": "",
                    "offset": 0,
                    "theDateTime": the_date_time,
                },
            )
            rows = (result.get("data") or {}).get("rows") or []
            if not isinstance(rows, list):
                raise ShiguangxuError("日程列表响应中缺少 data.rows")
            if not rows:
                break
            for item in rows:
                if not isinstance(item, dict) or item.get("todoType") != 1:
                    continue
                item_id = str(item.get("id") or "")
                if not item_id:
                    continue
                found[item_id] = item
            if len(rows) < 200:
                break
            page += 1

        items = []
        for item in sorted(found.values(), key=lambda row: (str(row.get("todoTime") or ""), str(row.get("id") or ""))):
            raw_time = str(item.get("todoTime") or "")
            if len(raw_time) >= 8:
                display_date = datetime.strptime(raw_time[:8], "%Y%m%d").strftime("%Y-%m-%d")
            else:
                display_date = raw_time
            items.append(
                {
                    "id": str(item.get("id") or ""),
                    "title": item.get("shortTitle") or item.get("title") or "",
                    "date": display_date,
                    "status": "已完成" if item.get("finishState") == 1 else "未完成",
                }
            )
        return {
            "mode": "all",
            "count": len(items),
            "items": items,
        }

    def list_diaries(
        self,
        date_value: Any = None,
        start_date: Any = None,
        end_date: Any = None,
    ) -> dict[str, Any]:
        # ── 全部参数为空 → 查询全部日程 ──
        if self._is_empty(date_value) and self._is_empty(start_date) and self._is_empty(end_date):
            return self._list_all_diaries()

        # ── 有日期参数 → 走原有日期/范围查询 ──
        if not self._is_empty(date_value) and (not self._is_empty(start_date) or not self._is_empty(end_date)):
            raise ValueError("date 不能与 start_date/end_date 同时使用")
        if not self._is_empty(date_value):
            first = last = self._parse_date(date_value, "date")
        elif not self._is_empty(start_date) or not self._is_empty(end_date):
            if self._is_empty(start_date) or self._is_empty(end_date):
                raise ValueError("start_date 和 end_date 必须同时提供")
            first = self._parse_date(start_date, "start_date")
            last = self._parse_date(end_date, "end_date")
        else:
            first = last = datetime.now().date()
        if first > last:
            raise ValueError("start_date 不能晚于 end_date")
        if (last - first).days >= MAX_QUERY_DAYS:
            last = first + timedelta(days=MAX_QUERY_DAYS - 1)

        found: dict[tuple[str, str], dict[str, Any]] = {}
        query_day = first
        while query_day <= last:
            page = 1
            while True:
                result = self._request(
                    "/base/plan/record/recordview",
                    {
                        "currentPage": page,
                        "pageSize": 200,
                        "isAllInfo": True,
                        "keyword": "",
                        "offset": 0,
                        "theDateTime": query_day.strftime("%Y%m%d120000"),
                    },
                )
                rows = (result.get("data") or {}).get("rows") or []
                if not isinstance(rows, list):
                    raise ShiguangxuError("日程列表响应中缺少 data.rows")
                for item in rows:
                    if not isinstance(item, dict) or item.get("todoType") != 1:
                        continue
                    todo_time = str(item.get("todoTime") or "")
                    if len(todo_time) < 8:
                        continue
                    item_day = datetime.strptime(todo_time[:8], "%Y%m%d").date()
                    if first <= item_day <= last:
                        item_id = str(item.get("id") or "")
                        found[(item_id, todo_time)] = item
                if len(rows) < 200:
                    break
                page += 1
            query_day += timedelta(days=1)

        items = []
        for item in sorted(found.values(), key=lambda row: (str(row.get("todoTime") or ""), str(row.get("id") or ""))):
            raw_time = str(item.get("todoTime") or "")
            interval_type = item.get("intervalType")
            if interval_type == 0:
                display_time = "全天"
            else:
                start = datetime.strptime(raw_time[:14], "%Y%m%d%H%M%S")
                display_time = start.strftime("%H:%M")
                duration = item.get("duration")
                if interval_type == 2 and isinstance(duration, (int, float)) and duration > 0:
                    display_time += "-" + (start + timedelta(seconds=duration)).strftime("%H:%M")
            items.append(
                {
                    "id": str(item.get("id") or ""),
                    "title": item.get("shortTitle") or item.get("title") or "",
                    "date": datetime.strptime(raw_time[:8], "%Y%m%d").strftime("%Y-%m-%d"),
                    "time": display_time,
                    "status": "已完成" if item.get("finishState") == 1 else "未完成",
                }
            )
        return {
            "start_date": first.isoformat(),
            "end_date": last.isoformat(),
            "count": len(items),
            "items": items,
        }

    def list_memos(
        self,
        folder_id: Any = None,
        keyword: Any = None,
        page: Any = None,
        page_size: Any = None,
    ) -> dict[str, Any]:
        if folder_id is not None and not isinstance(folder_id, str):
            raise ValueError("folder_id 必须是字符串")
        if keyword is not None and not isinstance(keyword, str):
            raise ValueError("keyword 必须是字符串")
        current_page = int(page) if page is not None else 1
        size = int(page_size) if page_size is not None else 50
        if current_page < 1:
            raise ValueError("page 必须 >= 1")
        if size < 1 or size > 200:
            raise ValueError("page_size 必须在 1-200 之间")

        payload: dict[str, Any] = {"currentPage": current_page, "pageSize": size}
        if folder_id:
            payload["folderId"] = folder_id.strip()
        if keyword and keyword.strip():
            payload["keyword"] = keyword.strip()

        result = self._request("/base/summary/v2/list", payload)
        rows = (result.get("data") or {}).get("rows") or []
        if not isinstance(rows, list):
            raise ShiguangxuError("备忘录列表响应中缺少 data.rows")

        tag_re = re.compile(r"<[^>]+>")

        items = []
        for row in rows:
            if not isinstance(row, dict):
                continue
            raw_time = str(row.get("lastEditDate") or row.get("created") or "")
            if len(raw_time) >= 14:
                update_time = datetime.strptime(raw_time[:14], "%Y%m%d%H%M%S").strftime("%Y-%m-%d %H:%M")
            elif len(raw_time) >= 8:
                update_time = datetime.strptime(raw_time[:8], "%Y%m%d").strftime("%Y-%m-%d")
            else:
                update_time = raw_time
            title = tag_re.sub("", str(row.get("title") or ""))
            content = tag_re.sub("", str(row.get("content") or ""))
            items.append({
                "id": str(row.get("id") or ""),
                "title": title,
                "content": content[:200],
                "update_time": update_time,
            })
        return {
            "page": current_page,
            "page_size": size,
            "count": len(items),
            "items": items,
        }

    # ── 清单事项（todoType=3，无日期待办）──

    def todo_add(self, title: Any, remark: Any = "", classify_id: Any = None) -> dict[str, Any]:
        """创建一条清单事项（todoType=3，无日期）。"""
        if not isinstance(title, str) or not title.strip():
            raise ValueError("title 必须是非空字符串")
        if not isinstance(remark, str):
            raise ValueError("remark 必须是字符串")
        cid = str(classify_id).strip() if classify_id else self._classify_id()
        record = {
            "localId": 1,
            "todoType": 3,
            "importance": 2,
            "shortTitle": title.strip(),
            "title": title.strip(),
            "attachments": [],
            "todoClassifyId": cid,
            "address": "",
            "remark": remark,
            "longitude": "",
            "latitude": "",
            "sonDeleteList": [],
            "sonAddList": [],
            "sonUpdateList": [],
            "aheadType": [{"offset": 0}],
            "intervalType": 1,
        }
        return self._request("/base/plan/record/add", record)

    def list_todos(self, include_completed: Any = True) -> dict[str, Any]:
        """全量分页查询清单事项（todoType=3），返回精简列表。"""
        MAX_PAGES = 100
        the_date_time = datetime.now().strftime("%Y%m%d120000")
        found: dict[str, dict[str, Any]] = {}
        page = 1
        while page <= MAX_PAGES:
            result = self._request(
                "/base/plan/record/recordview",
                {
                    "currentPage": page,
                    "pageSize": 200,
                    "isAllInfo": False,
                    "keyword": "",
                    "offset": 0,
                    "theDateTime": the_date_time,
                },
            )
            rows = (result.get("data") or {}).get("rows") or []
            if not isinstance(rows, list):
                raise ShiguangxuError("清单列表响应中缺少 data.rows")
            if not rows:
                break
            for item in rows:
                if not isinstance(item, dict) or item.get("todoType") != 3:
                    continue
                item_id = str(item.get("id") or "")
                if not item_id:
                    continue
                found[item_id] = item
            if len(rows) < 200:
                break
            page += 1

        items = []
        for item in sorted(found.values(), key=lambda row: str(row.get("id") or "")):
            finished = item.get("finishState") == 1
            if not include_completed and finished:
                continue
            items.append(
                {
                    "id": str(item.get("id") or ""),
                    "title": item.get("shortTitle") or item.get("title") or "",
                    "status": "已完成" if finished else "未完成",
                    "classify_id": str(item.get("todoClassifyId") or ""),
                }
            )
        return {
            "count": len(items),
            "items": items,
        }

    def todo_complete(self, item_id: Any) -> dict[str, Any]:
        """将一条清单事项（todoType=3）标记为完成。

        清单事项使用独立的 checklist 接口，参数为 checklistId（非 todoId），
        且不需要 todoTime。这与日程 checkin（/base/plan/checkin）不同。
        """
        if isinstance(item_id, bool) or not isinstance(item_id, (str, int)) or not str(item_id).strip():
            raise ValueError("id 必须是非空字符串或整数")
        item_id = str(item_id)
        return self._request(
            "/base/plan/checklist/checkin/all",
            {"finishState": 1, "checklistId": item_id},
        )

    def todo_delete(self, ids: Any) -> dict[str, Any]:
        """删除一条或多条清单事项（todoType=3）。

        清单事项使用独立的 checklist 删除接口 /base/plan/checklist/delete，
        参数为 {ids: [id1, id2, ...]}。这与日程删除（/base/plan/delete）不同。
        """
        if not isinstance(ids, list) or not ids:
            raise ValueError("ids 必须是非空数组")
        str_ids = []
        for item_id in ids:
            if isinstance(item_id, bool) or not isinstance(item_id, (str, int)) or not str(item_id).strip():
                raise ValueError(f"ids 中的每个元素必须是非空字符串或整数，收到：{item_id!r}")
            str_ids.append(str(item_id))
        return self._request("/base/plan/checklist/delete", {"ids": str_ids})

    # ── 番茄专注（/base/focus/*，与 Web 端「番茄专注」模块一致）──

    def focus_list(self) -> dict[str, Any]:
        """查询专注任务列表，合并进行中与已归档。"""
        result = self._request("/base/focus/v3/repeat/list", {})
        data = result.get("data") or {}
        type_names = {1: "倒计时", 2: "正计时", 3: "番茄钟"}
        tasks = []
        for key, state in (("unFinishList", "进行中"), ("finishList", "已归档")):
            for item in data.get(key) or []:
                if not isinstance(item, dict) or not item.get("id"):
                    continue
                config = item.get("repeatConfig") or {}
                focus_type = item.get("focusType")
                tasks.append(
                    {
                        "id": str(item["id"]),
                        "title": item.get("title") or "",
                        "type": type_names.get(focus_type, "未知"),
                        "focus_minutes": config.get("time"),
                        "rest_minutes": config.get("restTime"),
                        "tomato_num": config.get("focusNum"),
                        "state": state,
                    }
                )
        return {"count": len(tasks), "tasks": tasks}

    def _focus_task(self, task_id: Any) -> dict[str, Any]:
        """取专注任务：指定 ID 精确匹配；未指定则选第一个番茄钟类型任务。"""
        result = self._request("/base/focus/v3/repeat/list", {})
        data = result.get("data") or {}
        candidates = list(data.get("unFinishList") or []) + list(data.get("finishList") or [])
        wanted = str(task_id).strip() if task_id else ""
        for item in candidates:
            if not isinstance(item, dict) or not item.get("id"):
                continue
            if wanted:
                if str(item["id"]) == wanted:
                    return item
            elif item.get("focusType") == 3:
                return item
        if wanted:
            raise ShiguangxuError(f"专注任务不存在：{wanted}")
        if candidates:
            return candidates[0]
        raise ShiguangxuError("账号没有专注任务，请先在时光序「番茄专注」中创建一个")

    def focus_record_add(
        self,
        minutes: Any,
        task_id: Any = None,
        start: Any = None,
        end: Any = None,
        remark: Any = "",
    ) -> dict[str, Any]:
        """写入一条已完成的专注记录。

        请求体逆向自 web.shiguangxu.com 前端 completeFocus()：
        eventList 记录事件流（5=开始番茄钟, 3=完成番茄钟），时间格式 yyyyMMddHHmmss。
        """
        if isinstance(minutes, bool) or not isinstance(minutes, (int, float)) or minutes < 1:
            raise ValueError("minutes 必须是 >=1 的数字（分钟）")
        minutes = int(minutes)
        if not isinstance(remark, str):
            raise ValueError("remark 必须是字符串")
        if not self._is_empty(end):
            end_dt = datetime.strptime(self._format_datetime(end), "%Y%m%d%H%M%S")
        else:
            end_dt = datetime.now()
        if self._is_empty(start):
            start_dt = end_dt - timedelta(minutes=minutes)
        else:
            start_dt = datetime.strptime(self._format_datetime(start), "%Y%m%d%H%M%S")
        if start_dt > end_dt:
            raise ValueError("start 不能晚于 end")

        task = self._focus_task(task_id)
        config = task.get("repeatConfig") or {}
        focus_type = int(task.get("focusType") or 1)
        full_time = int(config.get("time") or minutes)
        focus_num = int(config.get("focusNum") or 0)
        title = str(task.get("title") or "专注")

        start_event = {
            "eventType": 5,
            "focusMinute": 0,
            "content": "开始: 第1个番茄钟",
            "eventTime": start_dt.strftime("%Y%m%d%H%M%S"),
            "startTime": start_dt.strftime("%H:%M"),
            "surplusTime": full_time * 60,
            "residueCount": full_time * 60,
            "focusNum": focus_num,
            "allFocusTime": 0,
        }
        finish_event = {
            "eventType": 3,
            "focusMinute": minutes,
            "content": "完成番茄钟",
            "eventTime": end_dt.strftime("%Y%m%d%H%M%S"),
            "startTime": end_dt.strftime("%H:%M"),
            "surplusTime": 0,
            "residueCount": 0,
            "focusNum": focus_num,
            "allFocusTime": minutes * 60,
        }
        record = {
            "eventList": [start_event, finish_event],
            "focusType": focus_type,
            "repeatId": str(task["id"]),
            "useTime": minutes,
            "startTime": start_dt.strftime("%Y%m%d%H%M%S"),
            "endTime": end_dt.strftime("%Y%m%d%H%M%S"),
            "fullTime": full_time,
            "title": title,
            "remark": remark,
            "focusNum": focus_num,
        }
        return self._request("/base/focus/v3/repeat/addFocusRecord", record)

    def focus_records(
        self,
        date_value: Any = None,
        start_date: Any = None,
        end_date: Any = None,
        page_size: Any = 50,
    ) -> dict[str, Any]:
        """查询专注记录。统计接口要求日期格式 yyyyMMdd 且 type=DAY。"""
        if not self._is_empty(date_value) and (not self._is_empty(start_date) or not self._is_empty(end_date)):
            raise ValueError("date 不能与 start_date/end_date 同时使用")
        if not self._is_empty(date_value):
            first = last = self._parse_date(date_value, "date")
        elif not self._is_empty(start_date) or not self._is_empty(end_date):
            if self._is_empty(start_date) or self._is_empty(end_date):
                raise ValueError("start_date 和 end_date 必须同时提供")
            first = self._parse_date(start_date, "start_date")
            last = self._parse_date(end_date, "end_date")
        else:
            first = last = datetime.now().date()
        if first > last:
            raise ValueError("start_date 不能晚于 end_date")
        if (last - first).days >= MAX_QUERY_DAYS:
            last = first + timedelta(days=MAX_QUERY_DAYS - 1)
        try:
            size = int(page_size) if page_size is not None else 50
        except (TypeError, ValueError) as exc:
            raise ValueError("page_size 必须是整数") from exc
        size = min(max(size, 1), 200)

        result = self._request(
            "/base/focus/v3/statistic/recordList",
            {
                "pageNum": 1,
                "pageSize": size,
                "beginDate": first.strftime("%Y%m%d"),
                "endDate": last.strftime("%Y%m%d"),
                "type": "DAY",
            },
        )
        rows = (result.get("data") or {}).get("rows") or []
        items = []
        total_minutes = 0
        for row in rows:
            if not isinstance(row, dict):
                continue
            minutes = row.get("useTime") or 0
            if isinstance(minutes, (int, float)):
                total_minutes += int(minutes)
            start_raw = str(row.get("startTime") or "")
            end_raw = str(row.get("endTime") or "")

            def _fmt(raw: str) -> str:
                return datetime.strptime(raw[:14], "%Y%m%d%H%M%S").strftime("%Y-%m-%d %H:%M") if len(raw) >= 14 else raw

            items.append(
                {
                    "id": str(row.get("id") or ""),
                    "title": row.get("title") or "",
                    "minutes": minutes,
                    "start": _fmt(start_raw),
                    "end": _fmt(end_raw),
                    "remark": row.get("remark") or "",
                }
            )
        return {
            "start_date": first.isoformat(),
            "end_date": last.isoformat(),
            "count": len(items),
            "total_minutes": total_minutes,
            "items": items,
        }

    def focus_delete(self, item_id: Any) -> dict[str, Any]:
        """按 ID 删除一条专注记录。"""
        if isinstance(item_id, bool) or not isinstance(item_id, (str, int)) or not str(item_id).strip():
            raise ValueError("id 必须是非空字符串或整数")
        return self._request("/base/focus/del", {"id": str(item_id)})


# ── 模块级 Client 单例，避免每次 tools/call 重建 ──
_client: ShiguangxuClient | None = None


def _get_client() -> ShiguangxuClient:
    global _client
    if _client is None:
        _client = ShiguangxuClient(_load_config())
    return _client


def _tool_result(value: Any, *, is_error: bool = False) -> dict[str, Any]:
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    result: dict[str, Any] = {"content": [{"type": "text", "text": text}]}
    if is_error:
        result["isError"] = True
    return result


def dispatch(message: dict[str, Any]) -> dict[str, Any] | None:
    request_id = message.get("id")
    if request_id is None:
        return None
    method = message.get("method")
    try:
        if method == "initialize":
            requested = (message.get("params") or {}).get("protocolVersion")
            result: Any = {
                "protocolVersion": requested or PROTOCOL_VERSION,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": SERVER_INFO,
            }
        elif method == "ping":
            result = {}
        elif method == "tools/list":
            result = {"tools": TOOLS}
        elif method == "tools/call":
            params = message.get("params") or {}
            arguments = params.get("arguments") or {}
            if not isinstance(arguments, dict):
                raise ValueError("arguments 必须是对象")
            client = _get_client()
            name = params.get("name")
            if name == "memo_add":
                value = client.memo_add(arguments.get("content"), arguments.get("title"))
            elif name == "diary_add":
                value = client.add(arguments.get("title"), arguments.get("datetime"), arguments.get("remark", ""))
            elif name == "diary_delete":
                value = client.delete(arguments.get("id"))
            elif name == "diary_complete":
                value = client.complete(arguments.get("id"))
            elif name == "diary_list":
                value = client.list_diaries(
                    arguments.get("date"), arguments.get("start_date"), arguments.get("end_date")
                )
            elif name == "memo_list":
                value = client.list_memos(
                    arguments.get("folder_id"),
                    arguments.get("keyword"),
                    arguments.get("page"),
                    arguments.get("page_size"),
                )
            elif name == "todo_add":
                value = client.todo_add(
                    arguments.get("title"),
                    arguments.get("remark", ""),
                    arguments.get("classify_id"),
                )
            elif name == "todo_list":
                include = arguments.get("include_completed", True)
                value = client.list_todos(include)
            elif name == "todo_complete":
                value = client.todo_complete(arguments.get("id"))
            elif name == "todo_delete":
                value = client.todo_delete(arguments.get("ids"))
            elif name == "focus_list":
                value = client.focus_list()
            elif name == "focus_record_add":
                value = client.focus_record_add(
                    arguments.get("minutes"),
                    arguments.get("task_id"),
                    arguments.get("start"),
                    arguments.get("end"),
                    arguments.get("remark", ""),
                )
            elif name == "focus_records":
                value = client.focus_records(
                    arguments.get("date"),
                    arguments.get("start_date"),
                    arguments.get("end_date"),
                    arguments.get("page_size", 50),
                )
            elif name == "focus_delete":
                value = client.focus_delete(arguments.get("id"))
            else:
                raise KeyError(f"未知工具：{name}")
            result = _tool_result(value)
        else:
            return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": f"未知方法：{method}"}}
        return {"jsonrpc": "2.0", "id": request_id, "result": result}
    except (ValueError, TypeError, KeyError, ShiguangxuError) as exc:
        return {"jsonrpc": "2.0", "id": request_id, "result": _tool_result(str(exc), is_error=True)}
    except Exception as exc:
        print(f"工具执行异常：{exc}", file=sys.stderr)
        return {"jsonrpc": "2.0", "id": request_id, "result": _tool_result(f"执行失败：{exc}", is_error=True)}


def main() -> None:
    for raw_line in sys.stdin:
        if not raw_line.strip():
            continue
        try:
            message = json.loads(raw_line)
            response = dispatch(message)
        except json.JSONDecodeError as exc:
            response = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": f"JSON 解析失败：{exc.msg}"}}
        except Exception as exc:
            response = {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": f"无效请求：{exc}"}}
        if response is not None:
            print(json.dumps(response, ensure_ascii=False, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    main()
