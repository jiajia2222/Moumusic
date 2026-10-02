#if os(iOS)
import SwiftUI
import UIKit

/// 开发者工具：刷新率浮层、公告、下载权限、专属 ID。仅服务端标记为开发者的设备可见。
@MainActor
struct DeveloperToolsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var reporter = DeviceReporter.shared
    @AppStorage("beans.developer.fpsOverlay") private var fpsOverlay = false

    // 公告
    @State private var announcementEnabled = false
    @State private var announcementText = ""
    @State private var loadingAnnouncement = false
    @State private var savingAnnouncement = false

    // 下载权限
    @State private var globalDownload = false
    @State private var loadingGlobal = false
    @State private var downloadTarget = ""
    @State private var downloadRecords: [MoumusicBackendAPI.DeviceRecord] = []

    // 专属 ID
    @State private var exclusiveTarget = ""
    @State private var assignedID = ""
    @State private var exclusiveEnabled = true
    @State private var badgeStyle = DeviceReporter.BadgeStyle.blackPurpleGold
    @State private var exclusiveRecords: [MoumusicBackendAPI.DeviceRecord] = []
    @State private var busy = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.clear
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        identityCard
                        managementCard
                        displayCard
                        announcementCard
                        downloadCard
                        exclusiveCard
                    }
                    .padding(16)
                    .padding(.bottom, 40)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("开发者工具")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .task { await reloadAll() }
    }

    // MARK: 卡片

    private var identityCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                title("当前设备")
                row("用户 ID", reporter.displayID.isEmpty ? "未分配" : reporter.displayID) {
                    UIPasteboard.general.string = reporter.displayID
                    ToastCenter.shared.show("用户 ID 已复制")
                }
                row("设备码", StableDeviceID.value) {
                    UIPasteboard.general.string = StableDeviceID.value
                    ToastCenter.shared.show("原始用户 ID 已复制")
                }
            }
        }
    }

    private var managementCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                title("反馈与用户管理")
                NavigationLink {
                    DeveloperFeedbackView()
                } label: {
                    managementRow("用户反馈", "查看所有反馈、附件，回复或删除", icon: "text.bubble")
                }
                .buttonStyle(.plain)
                NavigationLink {
                    DeveloperDevicesView()
                } label: {
                    managementRow("用户管理", "搜索用户，封禁、下载权限、重置 ID、专属 ID", icon: "person.2.badge.gearshape")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func managementRow(_ name: String, _ detail: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 18)).frame(width: 28).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(Color.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.secondary)
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }

    private var displayCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                title("显示与刷新率")
                Toggle("全局显示实时刷新率", isOn: $fpsOverlay)
                    .font(.system(size: 14))
                    .onChange(of: fpsOverlay) { on in DeveloperFPSOverlay.shared.setVisible(on) }
                actionButton("记录状态快照", icon: "camera.metering.center.weighted") {
                    DiagnosticLogStore.shared.append(level: .info, category: "developer", message: "开发者快照：fps=\(DeveloperFPSOverlay.shared.currentFPS)")
                    ToastCenter.shared.show("诊断快照已写入日志")
                }
            }
        }
    }

    private var announcementCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                title("公告")
                Toggle("启用公告", isOn: $announcementEnabled).font(.system(size: 14))
                TextEditor(text: $announcementText)
                    .font(.system(size: 14))
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
                actionButton(savingAnnouncement ? "正在保存…" : "保存公告", icon: "megaphone") {
                    Task { await saveAnnouncement() }
                }
            }
        }
    }

    private var downloadCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                title("开放下载功能")
                Toggle("临时开放所有用户下载", isOn: Binding(get: { globalDownload }, set: { v in Task { await setGlobal(v) } }))
                    .font(.system(size: 14))
                    .disabled(loadingGlobal)
                Text("开启后未单独授权的用户也能下载；关闭后只保留此前已经永久授权的用户。")
                    .font(.system(size: 11)).foregroundStyle(Color.secondary)
                Divider()
                title("管理其他设备", size: 14)
                Text("使用其他设备的设备标识，为该设备开放或关闭下载功能。输入对方的设备码。对方需要先启动过软件，才能被找到并更新权限。")
                    .font(.system(size: 11)).foregroundStyle(Color.secondary)
                TextField("设备码", text: $downloadTarget)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none).disableAutocorrection(true)
                HStack(spacing: 10) {
                    actionButton("开放下载功能", icon: "arrow.down.circle") { Task { await grantDownload(true) } }
                    actionButton("关闭", icon: "xmark.circle") { Task { await grantDownload(false) } }
                }
                actionButton("刷新授权记录", icon: "arrow.clockwise") { Task { await loadDownloadRecords() } }
                if downloadRecords.isEmpty {
                    Text("暂无下载权限记录").font(.system(size: 12)).foregroundStyle(Color.secondary)
                }
                ForEach(downloadRecords) { record in recordRow(record) }
            }
        }
    }

    private var exclusiveCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                title("专属 ID")
                Text("输入对方的设备码，再设置公开显示 ID。公开 ID 可以与其他用户重复。")
                    .font(.system(size: 11)).foregroundStyle(Color.secondary)
                TextField("设备码", text: $exclusiveTarget)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none).disableAutocorrection(true)
                Text("用于定位设备，不会修改设备码。").font(.system(size: 11)).foregroundStyle(Color.secondary)
                TextField("支持中文，最多 24 个字符", text: $assignedID)
                    .textFieldStyle(.roundedBorder)
                Text("中文也会显示在 ID 铭牌中，不影响昵称；留空保留当前 ID。")
                    .font(.system(size: 11)).foregroundStyle(Color.secondary)
                Toggle("启用专属铭牌", isOn: $exclusiveEnabled).font(.system(size: 14))
                Picker("专属铭牌样式", selection: $badgeStyle) {
                    Text("黑紫金").tag(DeviceReporter.BadgeStyle.blackPurpleGold)
                    Text("经典金").tag(DeviceReporter.BadgeStyle.classicGold)
                }
                .pickerStyle(.segmented)
                actionButton("编辑当前设备", icon: "iphone") {
                    exclusiveTarget = StableDeviceID.value
                    assignedID = reporter.exclusiveID
                    exclusiveEnabled = !reporter.exclusiveID.isEmpty
                    badgeStyle = reporter.badgeStyle
                }
                actionButton(busy ? "正在提交…" : "授权专属 ID", icon: "checkmark.seal") { Task { await grantExclusive() } }
                title("专属 ID 记录", size: 14)
                if exclusiveRecords.isEmpty {
                    Text("暂无专属 ID 记录").font(.system(size: 12)).foregroundStyle(Color.secondary)
                }
                ForEach(exclusiveRecords) { record in recordRow(record, showExclusive: true) }
            }
        }
    }

    // MARK: 小组件

    private func title(_ text: String, size: CGFloat = 16) -> some View {
        Text(text).font(.system(size: size, weight: .bold)).foregroundStyle(Color.primary)
    }

    private func row(_ name: String, _ value: String, copy: @escaping () -> Void) -> some View {
        HStack {
            Text(name).font(.system(size: 13)).foregroundStyle(Color.secondary)
            Spacer()
            Text(value).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            Button(action: copy) { Image(systemName: "doc.on.doc") }.buttonStyle(.plain)
        }
    }

    private func actionButton(_ text: String, icon: String, action: @escaping () -> Void) -> some View {
        GlassButton(title: text, systemName: icon, action: action)
    }

    private func recordRow(_ r: MoumusicBackendAPI.DeviceRecord, showExclusive: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(showExclusive && !r.exclusiveID.isEmpty ? "\(r.exclusiveID)（原 ID \(r.publicID)）" : "ID \(r.publicID)")
                .font(.system(size: 13, weight: .semibold))
            Text("\(r.deviceModel) · \(r.system) · v\(r.appVersion)")
                .font(.system(size: 11)).foregroundStyle(Color.secondary)
            Text(r.userID).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.secondary).lineLimit(1).truncationMode(.middle)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: 动作

    @MainActor private func reloadAll() async {
        if let a = try? await MoumusicBackendAPI.developerAnnouncement() {
            announcementEnabled = a.enabled
            announcementText = a.text
        }
        if let g = try? await MoumusicBackendAPI.globalDownloadEnabled() { globalDownload = g }
        await loadDownloadRecords()
        await loadExclusiveRecords()
    }

    @MainActor private func saveAnnouncement() async {
        savingAnnouncement = true
        defer { savingAnnouncement = false }
        do {
            try await MoumusicBackendAPI.saveAnnouncement(enabled: announcementEnabled, text: announcementText)
            await RemoteControlStore.shared.refreshIfNeeded(force: true)
            ToastCenter.shared.show("公告已保存")
        } catch {
            ToastCenter.shared.show((error as? BackendError)?.errorDescription ?? "保存公告失败")
        }
    }

    @MainActor private func setGlobal(_ value: Bool) async {
        loadingGlobal = true
        defer { loadingGlobal = false }
        do {
            try await MoumusicBackendAPI.setGlobalDownload(value)
            globalDownload = value
            ToastCenter.shared.show(value ? "已临时开放所有用户下载" : "已恢复永久授权下载")
        } catch {
            ToastCenter.shared.show("保存全局下载状态失败")
        }
    }

    @MainActor private func loadDownloadRecords() async {
        do { downloadRecords = try await MoumusicBackendAPI.downloadRecords() }
        catch { ToastCenter.shared.show("下载权限记录刷新失败") }
    }

    @MainActor private func loadExclusiveRecords() async {
        do { exclusiveRecords = try await MoumusicBackendAPI.exclusiveRecords() }
        catch { ToastCenter.shared.show("专属 ID 记录刷新失败") }
    }

    @MainActor private func grantDownload(_ enabled: Bool) async {
        let target = downloadTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { ToastCenter.shared.show("设备码格式不正确"); return }
        do {
            try await MoumusicBackendAPI.grantDownload(to: target, enabled: enabled)
            ToastCenter.shared.show(enabled ? "已开放该设备的下载功能" : "已关闭该设备的下载功能")
            await loadDownloadRecords()
        } catch {
            ToastCenter.shared.show((error as? BackendError)?.errorDescription ?? "下载权限操作失败")
        }
    }

    @MainActor private func grantExclusive() async {
        let target = exclusiveTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        let assigned = assignedID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { ToastCenter.shared.show("设备码格式不正确"); return }
        if exclusiveEnabled, assigned.isEmpty, !target.isEmpty {
            // 留空 = 保留当前 ID（以当前公开 ID 作为专属 ID）。
        }
        busy = true
        defer { busy = false }
        do {
            let value = assigned.isEmpty ? target : assigned
            try await MoumusicBackendAPI.grantExclusiveID(to: target, assigned: exclusiveEnabled ? (assigned.isEmpty ? currentPublicID(of: target) : value) : "", enabled: exclusiveEnabled, badgeStyle: badgeStyle.rawValue)
            ToastCenter.shared.show(exclusiveEnabled ? "已授权专属 ID" : "已取消专属 ID")
            await loadExclusiveRecords()
            await DeviceReporter.shared.reportHeartbeat()
        } catch {
            ToastCenter.shared.show((error as? BackendError)?.errorDescription ?? "专属 ID 操作失败")
        }
    }

    private func currentPublicID(of target: String) -> String {
        if let r = exclusiveRecords.first(where: { $0.userID == target || $0.publicID == target }) { return r.publicID }
        return target == StableDeviceID.value ? DeviceReporter.shared.displayID : target
    }
}

// MARK: - 实时刷新率浮层

@MainActor
final class DeveloperFPSOverlay {
    static let shared = DeveloperFPSOverlay()

    private var window: UIWindow?
    private let label = UILabel()
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var frames = 0
    private(set) var currentFPS = 0

    func setVisible(_ visible: Bool) {
        visible ? show() : hide()
    }

    private func show() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.backgroundColor = .clear
        w.isUserInteractionEnabled = false
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        label.layer.cornerRadius = 8
        label.layer.masksToBounds = true
        label.textAlignment = .center
        label.frame = CGRect(x: 12, y: 54, width: 74, height: 24)
        label.text = "-- fps"
        vc.view.addSubview(label)
        w.rootViewController = vc
        w.isHidden = false
        window = w

        let l = CADisplayLink(target: Ticker(owner: self), selector: #selector(Ticker.tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func hide() {
        link?.invalidate()
        link = nil
        window?.isHidden = true
        window = nil
    }

    fileprivate func tick(_ l: CADisplayLink) {
        if lastTimestamp == 0 { lastTimestamp = l.timestamp; return }
        frames += 1
        let elapsed = l.timestamp - lastTimestamp
        if elapsed >= 0.5 {
            currentFPS = Int((Double(frames) / elapsed).rounded())
            label.text = "\(currentFPS) fps"
            frames = 0
            lastTimestamp = l.timestamp
        }
    }

    /// CADisplayLink 强引用 target，用弱引用包装避免循环。
    private final class Ticker: NSObject {
        weak var owner: DeveloperFPSOverlay?
        init(owner: DeveloperFPSOverlay) { self.owner = owner }
        @objc func tick(_ l: CADisplayLink) {
            Task { @MainActor in self.owner?.tick(l) }
        }
    }
}
#endif
