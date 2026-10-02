#if os(iOS)
import Foundation
import MetricKit

/// Writes crash / hang / CPU-exception diagnostics delivered by MetricKit
/// into the app's diagnostic log so they show up in 诊断日志 and its export.
final class MetricKitDiagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitDiagnostics()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            let cpu = payload.cpuExceptionDiagnostics?.count ?? 0
            let disk = payload.diskWriteExceptionDiagnostics?.count ?? 0
            guard crashes + hangs + cpu + disk > 0 else { continue }
            let summary = "崩溃 \(crashes) · 卡死 \(hangs) · CPU 异常 \(cpu) · 磁盘写入异常 \(disk)"
            let detail = String(data: payload.jsonRepresentation(), encoding: .utf8)
            Task { @MainActor in
                DiagnosticLogStore.shared.append(
                    level: crashes > 0 ? .error : .warning,
                    category: "MetricKit",
                    message: summary,
                    detail: detail.map { String($0.prefix(6000)) })
            }
        }
    }
}
#endif
