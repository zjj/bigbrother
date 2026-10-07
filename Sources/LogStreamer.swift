import Foundation

/// 统一日志采集器。**双通道**。
///
/// ── 为什么需要两条通道 ──────────────────────────────────────────────
/// 主通道 `log stream` 是实时的、开销低,正常时用它。
///
/// 但它有一个实测会踩到的系统级故障:某些时候 **`logd` 的实时流式过滤会失效** ——
/// 裸跑 `log stream`(不带过滤)每秒能收到上千行、里面也有 TCC 事件,
/// 可一旦加上 `--predicate` 就**一行都不出**,而且进程还活着。
/// 离线跑的 `log show` 过滤却是好的。
///
///     实测:log stream                   8 秒 → 12529 行(含 78 条 TCC)
///           log stream --predicate TCC  12 秒 → 0 行
///           log show   --predicate TCC        → 正常
///
/// 这种情况下应用表面上「还活着」,实际再也收不到任何事件 —— 用户只会看到
/// 数字停住不动,而且没有任何报错。
///
/// 所以这里加了看门狗:主通道静默超过 20 秒就自动切到 `log show` 轮询兜底,
/// 并每隔 5 分钟试探一次能不能回到实时流。
final class LogStreamer {

    /// 两条通道共用同一条过滤条件
    ///
    /// 定位那三种标记必须写成 `process == "locationd" AND (…)`:
    /// locationd 每秒都在刷日志,裸 `process == "locationd"` 会把整条
    /// 采集管线淹没。
    static let predicate =
        #"(subsystem == "com.apple.TCC" OR subsystem CONTAINS "ScreenCaptureKit")"#
        + #" OR (process == "locationd" AND ("#
        + LocationParser.predicateFragment + #"))"#
        + #" OR (process == "ControlCenter" AND "#
        + CameraParser.predicateFragment + #")"#

    enum Mode: String {
        case stream = "实时流"
        case poll   = "轮询兜底"
    }

    private(set) var mode: Mode = .stream
    private(set) var isRunning = false
    private(set) var linesReceived = 0
    private(set) var lastDataAt = Date.distantPast

    var onLine: ((String) -> Void)?
    /// 一批日志读完了。定位解析器靠它把同一次访问里最强的证据定稿上报。
    var onBatchEnd: (() -> Void)?
    var onStatus: ((String) -> Void)?

    private var streamProcess: Process?
    private var lineBuffer = Data()
    private let lock = NSLock()
    private let pollQueue = DispatchQueue(label: "local.bigbrother.log-poll",
                                         qos: .utility)
    private let pollGenerationLock = NSLock()
    private var pollGeneration = 0

    private var watchdog: Timer?
    private var pollTimer: Timer?
    private var lastStreamAttempt = Date.distantPast

    private static let staleAfter: TimeInterval = 20        // 主通道多久没数据算失效
    private static let pollInterval: TimeInterval = 8        // 轮询周期
    private static let pollWindow = "25s"                    // 每次回看多长
    private static let retryStreamAfter: TimeInterval = 300  // 多久试一次回到实时流

    // MARK: 生命周期

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startStreaming()

        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    func stop() {
        isRunning = false
        watchdog?.invalidate(); watchdog = nil
        pollTimer?.invalidate(); pollTimer = nil
        streamProcess?.terminate(); streamProcess = nil
        invalidatePollGeneration()
    }

    // MARK: 主通道:实时流

    private func startStreaming() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--level", "debug", "--style", "compact",
                       "--predicate", Self.predicate]

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let self else { return }
            self.consume(d)
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            let msg = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !msg.isEmpty { self?.onStatus?("采集异常: \(msg)") }
        }

        do {
            try p.run()
            streamProcess = p
            mode = .stream
            lastStreamAttempt = Date()
            lastDataAt = Date()          // 给新进程一个宽限期
            Diagnostics.log("[Stream] 启动实时流")
        } catch {
            onStatus?("无法启动日志采集: \(error.localizedDescription)")
            switchToPolling(reason: "启动失败")
        }
    }

    // MARK: 看门狗

    private func tick() {
        guard isRunning else { return }
        let silent = Date().timeIntervalSince(lastDataAt)

        switch mode {
        case .stream:
            if silent > Self.staleAfter {
                Diagnostics.log("[Stream] 实时流静默 \(Int(silent))s → 切轮询兜底")
                switchToPolling(reason: "实时流静默 \(Int(silent)) 秒")
            }
        case .poll:
            if Date().timeIntervalSince(lastStreamAttempt) > Self.retryStreamAfter {
                Diagnostics.log("[Stream] 试探实时流是否恢复")
                stopPolling()
                streamProcess?.terminate(); streamProcess = nil
                startStreaming()
            }
        }
    }

    // MARK: 兜底通道:log show 轮询

    private func switchToPolling(reason: String) {
        streamProcess?.terminate(); streamProcess = nil
        mode = .poll
        lastStreamAttempt = Date()
        lastDataAt = Date()
        onStatus?("实时流不可用(\(reason)),已用轮询兜底")

        let generation = nextPollGeneration()
        pollOnce(generation: generation)
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.pollOnce(generation: generation)
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func stopPolling() {
        pollTimer?.invalidate(); pollTimer = nil
        invalidatePollGeneration()
    }

    private func nextPollGeneration() -> Int {
        pollGenerationLock.lock()
        defer { pollGenerationLock.unlock() }
        pollGeneration += 1
        return pollGeneration
    }

    private func invalidatePollGeneration() {
        _ = nextPollGeneration()
    }

    private func isCurrentPollGeneration(_ generation: Int) -> Bool {
        pollGenerationLock.lock()
        defer { pollGenerationLock.unlock() }
        return pollGeneration == generation
    }

    /// Run `log show` away from the main thread. Its output pipe is read to EOF,
    /// which can take long enough to make the menu-bar app appear frozen.
    /// The 25-second window exceeds the 8-second interval; msgID de-duplicates overlap.
    private func pollOnce(generation: Int) {
        pollQueue.async { [weak self] in
            guard let self, self.isCurrentPollGeneration(generation) else { return }

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            p.arguments = ["show", "--info", "--debug", "--last", Self.pollWindow, "--style", "compact",
                           "--predicate", Self.predicate]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out

            do {
                try p.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard self.isCurrentPollGeneration(generation) else { return }
                guard p.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
                    let detail = String(decoding: data.prefix(1024), as: UTF8.self)
                    let message = "日志轮询失败(\(p.terminationStatus)): \(detail)"
                    Diagnostics.log(message)
                    self.onStatus?(message)
                    return
                }
                let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
                    .map(String.init)

                guard self.isCurrentPollGeneration(generation) else { return }
                self.watch("轮询取回 \(lines.count) 行")
                defer { self.onBatchEnd?() }
                for line in lines {
                    guard self.isCurrentPollGeneration(generation) else { break }
                    // Keep heartbeat counters in sync with processed poll output.
                    self.lock.lock()
                    self.linesReceived += 1
                    self.lastDataAt = Date()
                    self.lock.unlock()
                    self.onLine?(line)
                }
            } catch {
                Diagnostics.log("[Stream] 轮询日志失败: \(error.localizedDescription)")
            }
        }
    }

    private var lastPollLog = Date.distantPast
    private func watch(_ msg: String) {
        guard Date().timeIntervalSince(lastPollLog) > 60 else { return }
        lastPollLog = Date()
        Diagnostics.log("[Stream] \(msg)")
    }

    // MARK: 行缓冲

    /// 按行切分。readabilityHandler 给到的分片不保证对齐换行,必须自己缓冲。
    private func consume(_ data: Data) {
        lock.lock()
        lineBuffer.append(data)
        let newline = UInt8(ascii: "\n")
        while let idx = lineBuffer.firstIndex(of: newline) {
            let lineData = lineBuffer[lineBuffer.startIndex..<idx]
            lineBuffer.removeSubrange(lineBuffer.startIndex...idx)
            if let s = String(data: lineData, encoding: .utf8) {
                linesReceived += 1
                lastDataAt = Date()
                let handler = onLine
                lock.unlock()
                handler?(s)
                lock.lock()
            }
        }
        if lineBuffer.count > 1 << 20 { lineBuffer.removeAll(keepingCapacity: true) }
        let batchEnd = onBatchEnd
        lock.unlock()
        batchEnd?()
    }
}
