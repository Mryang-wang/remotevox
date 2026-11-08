import CryptoKit
import Darwin
import Foundation

actor T1MixedDictation {
    static let shared = T1MixedDictation(
        directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RemoteVox/Models/zipformer-zh-en-2023-02-20"),
        executable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/RemoteVoxMixed")
    )

    private struct Asset {
        let name: String
        let source: String
        let size: Int
        let sha256: String
    }

    private static let source = URL(string:
        "https://huggingface.co/csukuangfj/k2fsa-zipformer-chinese-english-mixed/resolve/c402e0f46f0f4169b8187df3263ba1c5849c8cb0/")!
    private static let assets = [
        Asset(name: "encoder.onnx", source: "exp/encoder-epoch-99-avg-1.int8.onnx", size: 80_530_659,
              sha256: "e92df89d84ae5cb1571a2489c85d5d385c31fb8022892a240bd8c4c301b3ecc8"),
        Asset(name: "decoder.onnx", source: "exp/decoder-epoch-99-avg-1.onnx", size: 13_876_468,
              sha256: "d91b63c84f27f1d822244ced4cc2b9f7fb8a60a328f13b860408b8889dd0a0ed"),
        Asset(name: "joiner.onnx", source: "exp/joiner-epoch-99-avg-1.int8.onnx", size: 3_259_918,
              sha256: "16e901969495d5704a27a929e396a2ff9cc6fbfdeafdc6418e8c88b370113af6"),
        Asset(name: "tokens.txt", source: "data/lang_char_bpe/tokens.txt", size: 56_317,
              sha256: "a8e0e4ec53810e433789b54a5c0134a7eaa2ffca595a6334d54c00da858841d3"),
        Asset(name: "bpe.vocab", source: "data/lang_char_bpe/bpe.vocab", size: 12_564,
              sha256: "d0b642f3a2eacd5fadefdeff9e0e1358cab729647cbb7fe58cf738e1f7407029")
    ]

    enum Failure: LocalizedError {
        case unavailable, missingModel, downloading, invalidDownload, recognition

        var errorDescription: String? {
            switch self {
            case .unavailable: "中英混合识别组件不可用，请重新安装 RemoteVox。"
            case .missingModel: "请先在「权限与启动」下载中英混合模型。"
            case .downloading: "中英混合模型正在下载。"
            case .invalidDownload: "中英混合模型下载或校验失败，请重试。"
            case .recognition: "中英混合识别失败，请重试。"
            }
        }
    }

    private let directory: URL
    private let executable: URL
    private var downloading = false

    init(directory: URL, executable: URL) {
        self.directory = directory
        self.executable = executable
    }

    func isInstalled() -> Bool {
        Self.assets.allSatisfy { asset in
            let file = directory.appendingPathComponent(asset.name)
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return values?.isRegularFile == true && values?.fileSize == asset.size
        }
    }

    func prepare() async throws {
        let files = FileManager.default
        guard files.isExecutableFile(atPath: executable.path) else { throw Failure.unavailable }
        if isInstalled() { return }
        guard !downloading else { throw Failure.downloading }
        downloading = true
        let staging = directory.deletingLastPathComponent().appendingPathComponent(".download-\(UUID())")
        defer {
            downloading = false
            try? files.removeItem(at: staging)
        }
        try files.createDirectory(at: staging, withIntermediateDirectories: true)

        for asset in Self.assets {
            let (temporary, response) = try await URLSession.shared.download(from: Self.source.appendingPathComponent(asset.source))
            defer { try? files.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize == asset.size else {
                throw Failure.invalidDownload
            }
            let digest = try SHA256.hash(data: Data(contentsOf: temporary, options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
            guard digest == asset.sha256 else { throw Failure.invalidDownload }
            try files.moveItem(at: temporary, to: staging.appendingPathComponent(asset.name))
        }

        try Task.checkCancellation()
        if isInstalled() { return }
        if files.fileExists(atPath: directory.path) { try files.removeItem(at: directory) }
        try files.moveItem(at: staging, to: directory)
    }

    func transcribe(_ samples: [Int16]) throws -> String {
        try Task.checkCancellation()
        guard isInstalled() else { throw Failure.missingModel }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw Failure.unavailable }
        let input = Pipe()
        let output = Pipe()
        let writer = input.fileHandleForWriting
        guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.recognition }

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            try writer.write(contentsOf: samples.withUnsafeBytes { Data($0) })
            try writer.close()
        } catch {
            try? writer.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw Failure.recognition
        }
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try Task.checkCancellation()
        guard process.terminationStatus == 0, let text = String(data: result, encoding: .utf8) else {
            throw Failure.recognition
        }
        return text
            .replacingOccurrences(of: #"(?<![A-Za-z0-9])CODEX(?![A-Za-z0-9])"#, with: "Codex", options: .regularExpression)
            .replacingOccurrences(of: #"(?<![A-Za-z0-9])GITHUB(?![A-Za-z0-9])"#, with: "GitHub", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
