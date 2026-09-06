import Foundation

struct AppConfig: Codable {
    var apiBase: String
    var mobile: String
    var password: String
    var token: String
    var selectedRepeatId: String
    var focusMinutes: Int
    var breakMinutes: Int
    var autoStartBreak: Bool
    var syncEnabled: Bool
    var soundEnabled: Bool

    static let defaultAPIBase = "https://api.weilaizhushou.com"

    init(apiBase: String = AppConfig.defaultAPIBase,
         mobile: String = "",
         password: String = "",
         token: String = "",
         selectedRepeatId: String = "",
         focusMinutes: Int = 25,
         breakMinutes: Int = 5,
         autoStartBreak: Bool = true,
         syncEnabled: Bool = true,
         soundEnabled: Bool = true) {
        self.apiBase = apiBase
        self.mobile = mobile
        self.password = password
        self.token = token
        self.selectedRepeatId = selectedRepeatId
        self.focusMinutes = focusMinutes
        self.breakMinutes = breakMinutes
        self.autoStartBreak = autoStartBreak
        self.syncEnabled = syncEnabled
        self.soundEnabled = soundEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiBase = try c.decodeIfPresent(String.self, forKey: .apiBase) ?? AppConfig.defaultAPIBase
        mobile = try c.decodeIfPresent(String.self, forKey: .mobile) ?? ""
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        selectedRepeatId = try c.decodeIfPresent(String.self, forKey: .selectedRepeatId) ?? ""
        focusMinutes = try c.decodeIfPresent(Int.self, forKey: .focusMinutes) ?? 25
        breakMinutes = try c.decodeIfPresent(Int.self, forKey: .breakMinutes) ?? 5
        autoStartBreak = try c.decodeIfPresent(Bool.self, forKey: .autoStartBreak) ?? true
        syncEnabled = try c.decodeIfPresent(Bool.self, forKey: .syncEnabled) ?? true
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
    }
}

/// 一条本地番茄钟记录。创建时快照当时的专注任务信息，
/// 即使之后任务被删/改名，上传时仍能还原原始参数。
struct SessionRecord: Codable {
    var id: UUID
    var start: Date
    var end: Date
    var seconds: Int
    var synced: Bool          // true = 已上传，或无需上传（本地记录/未关联任务）
    var remoteId: String?
    var error: String?
    var taskTitle: String
    var taskRepeatId: String
    var focusType: Int
    var fullTime: Int         // 计划专注分钟
    var focusNum: Int         // 番茄个数

    init(start: Date, end: Date, seconds: Int,
         taskTitle: String, taskRepeatId: String, focusType: Int, fullTime: Int, focusNum: Int,
         synced: Bool = false) {
        self.id = UUID()
        self.start = start
        self.end = end
        self.seconds = seconds
        self.synced = synced
        self.remoteId = nil
        self.error = nil
        self.taskTitle = taskTitle
        self.taskRepeatId = taskRepeatId
        self.focusType = focusType
        self.fullTime = fullTime
        self.focusNum = focusNum
    }
}

/// 时光序「番茄专注」任务（来自 /base/focus/v3/repeat/list）
struct FocusTask: Codable, Identifiable {
    let id: String
    let focusType: Int        // 1=倒计时 2=正计时 3=番茄钟
    let title: String
    let timeMinutes: Int      // repeatConfig.time
    let focusNum: Int         // repeatConfig.focusNum
    let restTime: Int         // repeatConfig.restTime
    let autoRested: Bool      // repeatConfig.autoRested
    let finished: Bool

    var typeLabel: String {
        switch focusType {
        case 1: return "倒计时"
        case 2: return "正计时"
        default: return "番茄钟"
        }
    }
}

final class Store {
    static let shared = Store()

    let appDir: URL
    private let configURL: URL
    private let historyURL: URL
    private let tasksURL: URL

    private(set) var config: AppConfig
    private(set) var tasks: [FocusTask] = []
    var history: [SessionRecord] = []

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        appDir = base.appendingPathComponent("ShiguangTomato", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        configURL = appDir.appendingPathComponent("config.json")
        historyURL = appDir.appendingPathComponent("history.json")
        tasksURL = appDir.appendingPathComponent("tasks.json")

        if let data = try? Data(contentsOf: configURL),
           let loaded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = loaded
        } else {
            config = AppConfig()
        }
        if let data = try? Data(contentsOf: historyURL),
           let loaded = try? JSONDecoder.shared.decode([SessionRecord].self, from: data) {
            history = loaded
        }
        if let data = try? Data(contentsOf: tasksURL),
           let loaded = try? JSONDecoder().decode([FocusTask].self, from: data) {
            tasks = loaded
        }
    }

    func updateConfig(_ mutate: (inout AppConfig) -> Void) {
        mutate(&config)
        saveConfig()
    }

    func saveConfig() {
        writeJSON(config, to: configURL)
    }

    func replaceTasks(_ newTasks: [FocusTask]) {
        tasks = newTasks
        writeJSON(tasks, to: tasksURL)
    }

    /// 选中的专注任务；未选或已失效时自动挑一个（优先番茄钟类型）
    func selectedTask() -> FocusTask? {
        let id = config.selectedRepeatId
        if !id.isEmpty, let task = tasks.first(where: { $0.id == id }) {
            return task
        }
        return tasks.first { $0.focusType == 3 && !$0.finished }
            ?? tasks.first { $0.focusType == 3 }
            ?? tasks.first { !$0.finished }
            ?? tasks.first
    }

    func addSession(_ record: SessionRecord) {
        history.append(record)
        // 只保留最近一年，防止文件无限增长
        let cutoff = Date().addingTimeInterval(-365 * 86400)
        history = history.filter { $0.start > cutoff }
        saveHistory()
    }

    func saveHistory() {
        writeJSON(history, to: historyURL)
    }

    func todaySessions() -> [SessionRecord] {
        let calendar = Calendar.current
        return history.filter { calendar.isDateInToday($0.start) }
    }

    func pendingCount() -> Int {
        history.filter { !$0.synced }.count
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
        // 凭据文件收紧权限
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension JSONDecoder {
    static let shared: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
