import Foundation

enum SgxError: LocalizedError {
    case config(String)
    case connection(String)
    case http(Int, String)
    case api(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .config(let message): return message
        case .connection(let reason): return "无法连接时光序接口：\(reason)"
        case .http(let code, let detail): return "接口 HTTP \(code)：\(detail)"
        case .api(let code, let message): return "时光序接口错误 \(code)：\(message)"
        case .invalidResponse: return "时光序接口返回格式异常"
        }
    }
}

/// 时光序 API 客户端。
/// 登录/请求逻辑与 wahahaorg/shiguangxu-mcp 保持一致；
/// 专注记录接口（/base/focus/*）逆向自 web.shiguangxu.com 前端。
final class SgxClient {
    private let store: Store
    private var flushing = false

    struct NeedRelogin: Error {}

    init(store: Store) {
        self.store = store
    }

    private var apiBase: String {
        let base = store.config.apiBase.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? AppConfig.defaultAPIBase : base
    }

    // MARK: - 基础请求

    static func perform(_ path: String, _ payload: [String: Any], apiBase: String, token: String?) async throws -> [String: Any] {
        guard let url = URL(string: apiBase + path) else {
            throw SgxError.config("API 地址无效：\(apiBase)\(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SGX", forHTTPHeaderField: "channel-type")
        request.setValue("3.20.1", forHTTPHeaderField: "version")
        if let token = token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "token")
            request.setValue(token, forHTTPHeaderField: "sid")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SgxError.connection(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            var detail = String(data: data, encoding: .utf8) ?? ""
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = obj["msg"] as? String, !msg.isEmpty {
                detail = msg
            }
            if token != nil && (http.statusCode == 401 || http.statusCode == 403) {
                throw NeedRelogin()
            }
            throw SgxError.http(http.statusCode, detail)
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SgxError.invalidResponse
        }
        let code: Int
        if let n = obj["code"] as? Int {
            code = n
        } else if let s = obj["code"] as? String, let n = Int(s) {
            code = n
        } else {
            code = -999
        }
        if code != 200 {
            let msg = obj["msg"] as? String ?? ""
            if token != nil {
                let keywordHit = ["token", "Token", "登录", "过期", "失效"].contains { msg.contains($0) }
                if [401, 403, 10001, 10002, -1].contains(code) || keywordHit {
                    throw NeedRelogin()
                }
            }
            throw SgxError.api(code, msg.isEmpty ? "未知错误" : msg)
        }
        return obj
    }

    static func loginPayload(mobile: String, password: String) -> [String: Any] {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let y = calendar.component(.year, from: now)
        let mo = calendar.component(.month, from: now)
        let d = calendar.component(.day, from: now)
        let device: [String: Any] = [
            "channel": "WEB",
            "channelName": "时光序_web",
            "deviceTagApp": "WEB",
            "deviceType": "5",
            "appVersion": "1.0.0",
            "deviceModel": "web",
            "channelType": "SGX",
            "deviceTag": "WEB\(y)\(mo)\(d)" + UUID().uuidString,
        ]
        return ["mobile": mobile, "password": password, "type": "1", "appType": "5", "device": device]
    }

    /// 登录并缓存 token（供已登录状态使用）
    func login() async throws {
        let mobile = store.config.mobile.trimmingCharacters(in: .whitespaces)
        let password = store.config.password
        guard !mobile.isEmpty, !password.isEmpty else {
            throw SgxError.config("未登录：请先在设置中填写时光序手机号和密码")
        }
        let result = try await Self.perform(
            "/base/user/v2/login",
            Self.loginPayload(mobile: mobile, password: password),
            apiBase: apiBase,
            token: nil
        )
        let data = result["data"] as? [String: Any] ?? [:]
        let token = Self.asString(data["token"]) ?? Self.asString(data["userToken"]) ?? ""
        guard !token.isEmpty else {
            throw SgxError.api(-1, "登录成功，但响应中没有 token")
        }
        store.updateConfig { $0.token = token }
    }

    /// 设置页「测试连接」：用表单里的临时值登录 + 拉专注任务，不动已存配置
    static func probe(apiBase base: String, mobile: String, password: String) async throws -> [FocusTask] {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiBase = trimmed.isEmpty ? AppConfig.defaultAPIBase : trimmed
        guard !mobile.trimmingCharacters(in: .whitespaces).isEmpty, !password.isEmpty else {
            throw SgxError.config("请先填写手机号和密码")
        }
        let result = try await perform(
            "/base/user/v2/login",
            loginPayload(mobile: mobile.trimmingCharacters(in: .whitespaces), password: password),
            apiBase: apiBase,
            token: nil
        )
        let data = result["data"] as? [String: Any] ?? [:]
        let token = asString(data["token"]) ?? asString(data["userToken"]) ?? ""
        // 用返回 token 拉一次专注任务，验证 focus 模块可用
        let listResult = try await perform("/base/focus/v3/repeat/list", [:], apiBase: apiBase, token: token)
        return parseTasks(from: listResult)
    }

    /// 带自动重登的已认证请求
    func request(_ path: String, _ payload: [String: Any]) async throws -> [String: Any] {
        let base = apiBase
        if store.config.token.isEmpty {
            try await login()
        }
        do {
            return try await Self.perform(path, payload, apiBase: base, token: store.config.token)
        } catch {
            if error is NeedRelogin {
                try await login()
                return try await Self.perform(path, payload, apiBase: base, token: store.config.token)
            }
            throw error
        }
    }

    // MARK: - 番茄专注

    static func parseTasks(from result: [String: Any]) -> [FocusTask] {
        let data = result["data"] as? [String: Any] ?? [:]
        var items: [[String: Any]] = []
        for key in ["unFinishList", "finishList"] {
            if let list = data[key] as? [[String: Any]] {
                items.append(contentsOf: list)
            }
        }
        let tasks = items.compactMap { entry -> FocusTask? in
            guard let id = asString(entry["id"]), !id.isEmpty else { return nil }
            let config = entry["repeatConfig"] as? [String: Any] ?? [:]
            return FocusTask(
                id: id,
                focusType: asInt(entry["focusType"]) ?? 1,
                title: asString(entry["title"]) ?? "未命名专注",
                timeMinutes: asInt(config["time"]) ?? 25,
                focusNum: asInt(config["focusNum"]) ?? 0,
                restTime: asInt(config["restTime"]) ?? 5,
                autoRested: asBool(config["autoRested"]) ?? false,
                finished: asBool(entry["finished"]) ?? false
            )
        }
        return tasks
    }

    func repeatList() async throws -> [FocusTask] {
        let result = try await request("/base/focus/v3/repeat/list", [:])
        let tasks = Self.parseTasks(from: result)
        store.replaceTasks(tasks)
        return tasks
    }

    /// 把一条本地记录上传为时光序原生专注记录，返回服务端记录 id
    @discardableResult
    func addFocusRecord(record: SessionRecord) async throws -> String {
        let formatter14 = DateFormatter()
        formatter14.dateFormat = "yyyyMMddHHmmss"
        formatter14.timeZone = .current
        let formatterHM = DateFormatter()
        formatterHM.dateFormat = "HH:mm"
        formatterHM.timeZone = .current

        let focusNum = max(record.focusNum, 0)
        let fullSeconds = record.fullTime * 60
        let startEvent: [String: Any] = [
            "eventType": 5,
            "focusMinute": 0,
            "content": "开始: 第1个番茄钟",
            "eventTime": formatter14.string(from: record.start),
            "startTime": formatterHM.string(from: record.start),
            "surplusTime": fullSeconds,
            "residueCount": fullSeconds,
            "focusNum": focusNum,
            "allFocusTime": 0,
        ]
        let finishEvent: [String: Any] = [
            "eventType": 3,
            "focusMinute": max(1, record.seconds / 60),
            "content": "完成番茄钟",
            "eventTime": formatter14.string(from: record.end),
            "startTime": formatterHM.string(from: record.end),
            "surplusTime": 0,
            "residueCount": 0,
            "focusNum": focusNum,
            "allFocusTime": record.seconds,
        ]
        let payload: [String: Any] = [
            "eventList": [startEvent, finishEvent],
            "focusType": record.focusType,
            "repeatId": record.taskRepeatId,
            "useTime": max(1, record.seconds / 60),
            "startTime": formatter14.string(from: record.start),
            "endTime": formatter14.string(from: record.end),
            "fullTime": record.fullTime,
            "title": record.taskTitle,
            "remark": "来自 Mac 时光番茄",
            "focusNum": focusNum,
        ]
        let result = try await request("/base/focus/v3/repeat/addFocusRecord", payload)
        let data = result["data"] as? [String: Any] ?? [:]
        return Self.asString(data["id"]) ?? ""
    }

    /// 查询时光序今日专注统计（v3 统计接口，日期格式 yyyyMMdd）
    func fetchTodayStats() async throws -> (minutes: Int, count: Int) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = .current
        let day = formatter.string(from: Date())
        let payload: [String: Any] = [
            "pageNum": 1,
            "pageSize": 100,
            "beginDate": day,
            "endDate": day,
            "type": "DAY",
        ]
        let result = try await request("/base/focus/v3/statistic/recordList", payload)
        let data = result["data"] as? [String: Any] ?? [:]
        let rows = data["rows"] as? [[String: Any]] ?? []
        var minutes = 0
        for row in rows {
            minutes += Self.asInt(row["useTime"]) ?? 0
        }
        return (minutes, rows.count)
    }

    // MARK: - 离线队列

    /// 逐条上传未同步记录；遇错即停，下次（启动/完成番茄/手动点击）再补传
    func flushPending(force: Bool = false) async {
        guard force || store.config.syncEnabled else { return }
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        var changed = false
        for index in store.history.indices where !store.history[index].synced {
            let record = store.history[index]
            if record.taskRepeatId.isEmpty {
                // 未关联专注任务：标记为无需上传
                store.history[index].synced = true
                changed = true
                continue
            }
            do {
                let remoteId = try await addFocusRecord(record: record)
                store.history[index].synced = true
                store.history[index].remoteId = remoteId
                store.history[index].error = nil
                changed = true
            } catch {
                store.history[index].error = error.localizedDescription
                changed = true
                break
            }
        }
        if changed {
            store.saveHistory()
        }
    }

    // MARK: - 容错解析

    static func asString(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    static func asInt(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    static func asBool(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String { return s == "true" || s == "1" }
        return nil
    }
}
