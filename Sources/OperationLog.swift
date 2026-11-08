import Foundation

final class T1OperationLog {
    private static let dailyLimit = 64 * 1024
    private let directory: URL
    private let queue = DispatchQueue(label: "local.codex.t1.operation-log", qos: .utility)
    private let cleanupTimer: DispatchSourceTimer
    private let dayFormat = T1OperationLog.formatter("yyyy-MM-dd")
    private let timeFormat = T1OperationLog.formatter("HH:mm:ss.SSS")
    private var lastPrunedDay: String?

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/RemoteVox/Operations", isDirectory: true)) {
        self.directory = directory
        cleanupTimer = DispatchSource.makeTimerSource(queue: queue)
        cleanupTimer.schedule(deadline: .now(), repeating: .seconds(1800), leeway: .seconds(60))
        cleanupTimer.setEventHandler { [weak self] in
            guard let self else { return }
            let days = self.retainedDays(at: Date())
            try? self.prune(days)
        }
        cleanupTimer.resume()
    }

    deinit { cleanupTimer.cancel() }

    func flush() { queue.sync {} }

    func record(_ message: String, at date: Date = Date()) {
        queue.async {
            do {
                let days = self.retainedDays(at: Date())
                let day = self.dayFormat.string(from: date)
                guard days.contains(day) else { return }
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try self.prune(days)
                let url = self.file(for: day)
                let body = message.prefix(240).components(separatedBy: .newlines).joined(separator: " ")
                let entry = Data("\(day) \(self.timeFormat.string(from: date)) \(body)\n".utf8)
                try self.append(entry, to: url)
            } catch {
                // Diagnostics must never interfere with remote input.
            }
        }
    }

    func read(_ completion: @escaping (String) -> Void) {
        queue.async {
            let text: String
            do {
                let days = self.retainedDays(at: Date())
                try self.prune(days)
                let entries = try days.flatMap { day -> [Substring] in
                    let url = self.file(for: day)
                    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
                    let contents = try String(contentsOf: url, encoding: .utf8)
                    return Array(contents.split(separator: "\n").reversed())
                }
                text = entries.joined(separator: "\n")
            } catch {
                text = "无法读取诊断日志。"
            }
            DispatchQueue.main.async { completion(text) }
        }
    }

    private func append(_ entry: Data, to url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            try entry.write(to: url, options: .atomic)
            return
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if size + entry.count > Self.dailyLimit {
            let tail = try Data(contentsOf: url).suffix(Self.dailyLimit / 2)
            var recent = Data()
            if let newline = tail.firstIndex(of: 0x0A) {
                recent.append(contentsOf: tail[tail.index(after: newline)...])
            }
            recent.append(entry)
            try recent.write(to: url, options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: entry)
        }
    }

    private func retainedDays(at date: Date) -> [String] {
        let yesterday = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -1, to: date) ?? date
        return [dayFormat.string(from: date), dayFormat.string(from: yesterday)]
    }

    private func prune(_ days: [String]) throws {
        guard lastPrunedDay != days[0], FileManager.default.fileExists(atPath: directory.path) else { return }
        let retained = Set(days.map { file(for: $0).lastPathComponent })
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}\.log$"#, options: .regularExpression) != nil
                && !retained.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
        lastPrunedDay = days[0]
    }

    private func file(for day: String) -> URL { directory.appendingPathComponent(day + ".log") }

    private static func formatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = pattern
        return formatter
    }
}
