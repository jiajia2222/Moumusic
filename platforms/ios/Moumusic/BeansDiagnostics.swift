import MetricKit
import SwiftUI
import UIKit

/// 诊断：主线程卡死检测、内存警告 / 内存快速增长、系统崩溃与卡死报告（MetricKit）。
final class BeansDiagnostics: NSObject, ObservableObject, MXMetricManagerSubscriber {
    static let shared = BeansDiagnostics()

    struct Event: Codable, Identifiable {
        var id = UUID()
        let time: Date
        let kind: String
        let message: String
    }

    @Published private(set) var events: [Event] = []
    @Published private(set) var memoryMB: Double = 0

    private let storageKey = "beans.diagnostics.events.v1"
    private let maxEvents = 300
    private var watchdog: DispatchSourceTimer?
    private var lastPong = ProcessInfo.processInfo.systemUptime
    private var stalledSince: TimeInterval?
    private var lastMemoryMB: Double = 0
    private var started = false
    private let lock = NSLock()

    private override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let list = try? JSONDecoder().decode([Event].self, from: data) {
            events = list
        }
    }

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            self?.record("memory", "系统内存警告｜当前 \(Int(Self.residentMemoryMB())) MB")
        }
        MXMetricManager.shared.add(self)
        startWatchdog()
    }

    // MARK: 主线程看门狗

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "Beans.Diagnostics.watchdog", qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async { [weak self] in
                self?.lock.lock(); self?.lastPong = ProcessInfo.processInfo.systemUptime; self?.lock.unlock()
            }
            self.checkWatchdog()
        }
        timer.resume()
        watchdog = timer
    }

    private func checkWatchdog() {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let gap = now - lastPong
        let since = stalledSince
        lock.unlock()
        if gap > 2.5 {
            if since == nil {
                lock.lock(); stalledSince = now - gap; lock.unlock()
                record("hang", "主线程阻塞超过阈值（\(String(format: "%.1f", gap)) 秒）")
            }
        } else if let since = since {
            lock.lock(); stalledSince = nil; lock.unlock()
            record("hang", "主线程恢复响应（共阻塞 \(String(format: "%.1f", now - since)) 秒）")
        }
        // 内存快速增长：10 秒内增长超过 150 MB。
        let mem = Self.residentMemoryMB()
        DispatchQueue.main.async { [weak self] in self?.memoryMB = mem }
        if lastMemoryMB > 0, mem - lastMemoryMB > 150 {
            record("memory", "进程内存快速增长：\(Int(lastMemoryMB)) → \(Int(mem)) MB")
        }
        if Int(now) % 10 == 0 { lastMemoryMB = mem }
    }

    static func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    // MARK: 记录

    func record(_ kind: String, _ message: String) {
        BeansLogger.shared.log("[诊断/\(kind)] \(message)", level: .warn)
        let event = Event(time: Date(), kind: kind, message: message)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.events.insert(event, at: 0)
            if self.events.count > self.maxEvents { self.events.removeLast(self.events.count - self.maxEvents) }
            if let data = try? JSONEncoder().encode(self.events) {
                UserDefaults.standard.set(data, forKey: self.storageKey)
            }
        }
    }

    func snapshotLine() -> String {
        let info = Bundle.main.infoDictionary
        return "内存=\(Int(Self.residentMemoryMB()))MB｜版本=\(info?["CFBundleShortVersionString"] as? String ?? "?")(\(info?["CFBundleVersion"] as? String ?? "?"))｜系统=\(UIDevice.current.systemVersion)｜低电量=\(ProcessInfo.processInfo.isLowPowerModeEnabled ? "是" : "否")｜热状态=\(ProcessInfo.processInfo.thermalState.rawValue)"
    }

    func recordSnapshot() {
        record("snapshot", snapshotLine())
    }

    func clear() {
        events = []
        UserDefaults.standard.removeObject(forKey: storageKey)
        BeansLogger.shared.clear()
        try? FileManager.default.removeItem(at: Self.reportDirectory)
    }

    // MARK: MetricKit

    private static var reportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let name = "mx-\(Int(Date().timeIntervalSince1970)).json"
            let url = Self.reportDirectory.appendingPathComponent(name)
            try? payload.jsonRepresentation().write(to: url, options: .atomic)
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            record("system", "已保存系统诊断文件：\(name)｜崩溃 \(crashes)｜卡死 \(hangs)")
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {}

    // MARK: 导出

    func exportReport() -> URL {
        var lines: [String] = ["Moumusic 诊断报告 \(BeansLogger.dateString(Date()))", snapshotLine(), ""]
        lines.append("— 诊断事件（最近 \(min(events.count, 100)) 条）—")
        for e in events.prefix(100) {
            lines.append("[\(BeansLogger.dateString(e.time))] \(e.kind)｜\(e.message)")
        }
        lines.append("")
        lines.append("— 应用日志 —")
        if let log = try? String(contentsOf: BeansLogger.shared.exportLogURL(), encoding: .utf8) {
            lines.append(String(log.suffix(60_000)))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Moumusic-diagnostics-\(Int(Date().timeIntervalSince1970)).txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var diagnostics = BeansDiagnostics.shared
    @State private var shareURL: ShareFileItem?
    @State private var confirmClear = false

    var body: some View {
        BeansNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("运行状态").font(BeansFont.appFont(16, .bold)).foregroundStyle(Color.beansLabel)
                                Text(diagnostics.snapshotLine())
                                    .font(BeansFont.appFont(12)).foregroundStyle(Color.beansComment)
                                Text("模块、错误、代码位置会随诊断日志一起导出。")
                                    .font(BeansFont.appFont(11)).foregroundStyle(Color.beansComment)
                            }
                        }
                        HStack(spacing: 10) {
                            GlassButton(title: "记录状态快照", systemName: "camera.metering.center.weighted") {
                                diagnostics.recordSnapshot()
                                ToastCenter.shared.show("诊断快照已写入日志")
                            }
                            GlassButton(title: "导出完整报告", systemName: "square.and.arrow.up") {
                                shareURL = ShareFileItem(url: diagnostics.exportReport())
                            }
                        }
                        GlassButton(title: "清空诊断日志", systemName: "trash") { confirmClear = true }

                        Text("历史与系统报告").font(BeansFont.appFont(16, .bold)).foregroundStyle(Color.beansLabel)
                        if diagnostics.events.isEmpty {
                            Text("暂无诊断记录").font(BeansFont.appFont(13)).foregroundStyle(Color.beansComment)
                        }
                        ForEach(diagnostics.events.prefix(80)) { event in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(BeansLogger.dateString(event.time))  ·  \(event.kind)")
                                    .font(BeansFont.appFont(11)).foregroundStyle(Color.beansComment)
                                Text(event.message).font(BeansFont.appFont(13)).foregroundStyle(Color.beansLabel)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.beansLabel.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
                .beansScrollIndicatorsHidden()
            }
            .navigationTitle("诊断与日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .sheet(item: $shareURL) { item in ShareSheet(items: [item.url]) }
        .alert("清空诊断日志？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { diagnostics.clear() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("诊断记录和应用日志将被删除。")
        }
    }
}
