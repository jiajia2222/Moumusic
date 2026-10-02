#if os(iOS)
import SwiftUI
import UIKit

private func devDateText(_ iso: String) -> String {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    guard let date = parser.date(from: iso) ?? plain.date(from: iso) else { return iso }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "MM-dd HH:mm"
    return formatter.string(from: date)
}

private func devDurationText(_ seconds: Int) -> String {
    if seconds >= 3600 { return String(format: "%.1f 小时", Double(seconds) / 3600) }
    return "\(seconds / 60) 分钟"
}

/// 开发者：查看全部用户反馈、回复、删除。
struct DeveloperFeedbackView: View {
    var initialQuery = ""

    @State private var filter = "all"
    @State private var query = ""
    @State private var items: [MoumusicBackendAPI.DevFeedback] = []
    @State private var total = 0
    @State private var isLoading = false
    @State private var replyTarget: MoumusicBackendAPI.DevFeedback?
    @State private var replyText = ""
    @State private var deleteTarget: MoumusicBackendAPI.DevFeedback?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Picker("筛选", selection: $filter) {
                    Text("全部").tag("all")
                    Text("未回复").tag("unreplied")
                }
                .pickerStyle(.segmented)

                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索内容、联系方式或用户 ID", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await reload() } }
                }
                .padding(10)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text("共 \(total) 条反馈")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if items.isEmpty && !isLoading {
                    Text("没有符合条件的反馈")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                }

                ForEach(items) { item in card(item) }

                if items.count < total {
                    Button("加载更多") { Task { await loadMore() } }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                if isLoading { ProgressView().frame(maxWidth: .infinity) }
            }
            .padding(16)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("用户反馈")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .task {
            if !initialQuery.isEmpty { query = initialQuery }
            await reload()
        }
        .onChange(of: filter) { _ in Task { await reload() } }
        .sheet(item: $replyTarget) { target in
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    Text(target.content).font(.footnote).foregroundStyle(.secondary).lineLimit(6)
                    TextEditor(text: $replyText)
                        .frame(minHeight: 160)
                        .padding(6)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.15)))
                    Spacer()
                }
                .padding(16)
                .navigationTitle("回复反馈")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { replyTarget = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("发送") { Task { await sendReply(target) } }
                            .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog("删除这条反馈？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let target = deleteTarget { Task { await delete(target) } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("反馈、回复和附件都会被永久删除。")
        }
    }

    private func card(_ item: MoumusicBackendAPI.DevFeedback) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ID \(item.publicID.isEmpty ? "未知" : item.publicID)")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Text(devDateText(item.submittedAt)).font(.caption).foregroundStyle(.secondary)
            }
            if !item.device.isEmpty {
                Text(item.device).font(.caption).foregroundStyle(.secondary)
            }
            Text(item.content)
                .font(.system(size: 14))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !item.contact.isEmpty {
                Label(item.contact, systemImage: "person.crop.circle").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(item.attachments) { attachment in
                Link(destination: attachment.url) {
                    Label("\(attachment.name)（\(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))）",
                          systemImage: "paperclip")
                        .font(.caption)
                }
            }
            ForEach(item.replies) { reply in
                VStack(alignment: .leading, spacing: 2) {
                    Text("开发者回复 · \(devDateText(reply.createdAt))").font(.caption2).foregroundStyle(Theme.accent)
                    Text(reply.content).font(.system(size: 13))
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            HStack(spacing: 10) {
                Button { replyText = ""; replyTarget = item } label: { Label("回复", systemImage: "arrowshape.turn.up.left") }
                Button {
                    UIPasteboard.general.string = item.userID
                    ToastCenter.shared.show("设备码已复制")
                } label: { Label("设备码", systemImage: "doc.on.doc") }
                Spacer()
                Button(role: .destructive) { deleteTarget = item } label: { Label("删除", systemImage: "trash") }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @MainActor private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await MoumusicBackendAPI.devFeedbackList(filter: filter, query: query, offset: 0)
            items = result.items
            total = result.total
        } catch {
            ToastCenter.shared.show((error as? BackendError)?.errorDescription ?? "反馈加载失败")
        }
    }

    @MainActor private func loadMore() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if let result = try? await MoumusicBackendAPI.devFeedbackList(filter: filter, query: query, offset: items.count) {
            items += result.items
            total = result.total
        }
    }

    @MainActor private func sendReply(_ target: MoumusicBackendAPI.DevFeedback) async {
        do {
            try await MoumusicBackendAPI.devReplyFeedback(id: target.id, content: replyText.trimmingCharacters(in: .whitespacesAndNewlines))
            replyTarget = nil
            ToastCenter.shared.show("已回复")
            await reload()
        } catch {
            ToastCenter.shared.show((error as? BackendError)?.errorDescription ?? "回复失败")
        }
    }

    @MainActor private func delete(_ target: MoumusicBackendAPI.DevFeedback) async {
        do {
            try await MoumusicBackendAPI.devDeleteFeedback(id: target.id)
            items.removeAll { $0.id == target.id }
            total = max(0, total - 1)
            ToastCenter.shared.show("已删除")
        } catch {
            ToastCenter.shared.show((error as? BackendError)?.errorDescription ?? "删除失败")
        }
    }
}

/// 开发者：查看全部用户，封禁 / 解封、下载授权、重置公开 ID、查看其反馈。
struct DeveloperDevicesView: View {
    @State private var filter = "all"
    @State private var query = ""
    @State private var items: [MoumusicBackendAPI.DevDevice] = []
    @State private var total = 0
    @State private var isLoading = false
    @State private var selected: MoumusicBackendAPI.DevDevice?
    @State private var feedbackQuery: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Picker("筛选", selection: $filter) {
                    Text("全部").tag("all")
                    Text("已封禁").tag("blocked")
                    Text("可下载").tag("download")
                    Text("专属 ID").tag("exclusive")
                }
                .pickerStyle(.segmented)

                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索用户 ID、设备码或机型", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await reload() } }
                }
                .padding(10)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text("共 \(total) 个用户")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(items) { item in
                    Button { selected = item } label: { row(item) }
                        .buttonStyle(.plain)
                }
                if items.count < total {
                    Button("加载更多") { Task { await loadMore() } }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                if isLoading { ProgressView().frame(maxWidth: .infinity) }
            }
            .padding(16)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("用户管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .task { await reload() }
        .onChange(of: filter) { _ in Task { await reload() } }
        .sheet(item: $selected) { device in
            NavigationStack {
                detail(device)
            }
            .presentationDetents([.medium, .large])
        }
        .navigationDestination(isPresented: Binding(get: { feedbackQuery != nil }, set: { if !$0 { feedbackQuery = nil } })) {
            DeveloperFeedbackView(initialQuery: feedbackQuery ?? "")
        }
    }

    private func row(_ d: MoumusicBackendAPI.DevDevice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(d.exclusiveID.isEmpty ? "ID \(d.publicID)" : "\(d.exclusiveID)（原 \(d.publicID)）")
                    .font(.system(size: 14, weight: .bold))
                if d.isDeveloper { tag("开发者", .purple) }
                if d.blocked { tag("已封禁", .red) }
                if d.downloadUnlocked { tag("可下载", .green) }
                Spacer()
                Text(devDateText(d.lastSeenAt)).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(d.deviceModel) · \(d.system) · v\(d.appVersion)")
                .font(.caption).foregroundStyle(.secondary)
            Text("听歌 \(devDurationText(d.listeningSeconds)) · \(d.playCount) 首 · 反馈 \(d.feedbackCount) 条")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }

    private func detail(_ d: MoumusicBackendAPI.DevDevice) -> some View {
        List {
            Section("设备") {
                LabeledContent("用户 ID", value: d.publicID)
                if !d.exclusiveID.isEmpty { LabeledContent("专属 ID", value: d.exclusiveID) }
                LabeledContent("机型", value: d.deviceModel)
                LabeledContent("名称", value: d.deviceName)
                LabeledContent("系统", value: d.system)
                LabeledContent("版本", value: d.appVersion)
                LabeledContent("首次出现", value: devDateText(d.createdAt))
                LabeledContent("最近在线", value: devDateText(d.lastSeenAt))
                LabeledContent("听歌时长", value: devDurationText(d.listeningSeconds))
                LabeledContent("播放歌曲", value: "\(d.playCount) 首")
                Button("复制设备码") {
                    UIPasteboard.general.string = d.userID
                    ToastCenter.shared.show("设备码已复制")
                }
            }
            Section("管理") {
                Button(d.blocked ? "解除封禁" : "封禁该设备", role: d.blocked ? nil : .destructive) {
                    Task { await run("block", d) { try await MoumusicBackendAPI.devSetBlocked(userID: d.userID, blocked: !d.blocked) } }
                }
                Button(d.downloadUnlocked ? "关闭下载权限" : "开放下载权限") {
                    Task { await run("download", d) { try await MoumusicBackendAPI.grantDownload(to: d.userID, enabled: !d.downloadUnlocked) } }
                }
                Button("重置公开 ID（重新随机分配）") {
                    Task { await run("reset", d) { _ = try await MoumusicBackendAPI.devResetPublicID(userID: d.userID) } }
                }
                if !d.exclusiveID.isEmpty {
                    Button("取消专属 ID", role: .destructive) {
                        Task {
                            await run("exclusive", d) {
                                try await MoumusicBackendAPI.grantExclusiveID(to: d.userID, assigned: "", enabled: false, badgeStyle: "black_purple_gold")
                            }
                        }
                    }
                }
                Button("清除其个人资料卡", role: .destructive) {
                    Task { await run("profile", d) { try await MoumusicBackendAPI.devDeleteProfile(userID: d.userID) } }
                }
            }
            Section {
                Button("查看该用户的反馈（\(d.feedbackCount)）") {
                    selected = nil
                    feedbackQuery = d.userID
                }
            }
        }
        .navigationTitle("用户 \(d.publicID)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { selected = nil } } }
    }

    @MainActor private func run(_ name: String, _ d: MoumusicBackendAPI.DevDevice, _ action: () async throws -> Void) async {
        do {
            try await action()
            ToastCenter.shared.show("操作成功")
            selected = nil
            await reload()
        } catch {
            ToastCenter.shared.show((error as? BackendError)?.errorDescription ?? "操作失败")
        }
    }

    @MainActor private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await MoumusicBackendAPI.devDevices(filter: filter, query: query, offset: 0)
            items = result.items
            total = result.total
        } catch {
            ToastCenter.shared.show((error as? BackendError)?.errorDescription ?? "用户列表加载失败")
        }
    }

    @MainActor private func loadMore() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if let result = try? await MoumusicBackendAPI.devDevices(filter: filter, query: query, offset: items.count) {
            items += result.items
            total = result.total
        }
    }
}
#endif
