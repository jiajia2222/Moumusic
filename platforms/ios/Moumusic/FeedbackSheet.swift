import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 问题反馈：设备信息 + 问题描述 + 最多 4 个附件；提交成功后服务端会解锁下载功能。
@MainActor
struct FeedbackSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss

    @State private var deviceModel = ""
    @State private var systemVersion = "iOS \(UIDevice.current.systemVersion)"
    @State private var message = ""
    @State private var contact = ""
    @State private var attachments: [PendingAttachment] = []
    @State private var submitting = false
    @State private var errorText: String?
    @State private var showMediaPicker = false
    @State private var showFileImporter = false
    @State private var showHistory = false

    struct PendingAttachment: Identifiable {
        let id = UUID()
        let filename: String
        let mimeType: String
        let url: URL
        let size: Int
    }

    private let maxAttachments = 4
    private let maxBytes = 50 * 1024 * 1024

    private var canSubmit: Bool {
        !submitting
            && !deviceModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        BeansNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                field(title: "设备型号", placeholder: "例如：iPhone 16 Pro", text: $deviceModel)
                                field(title: "系统版本", placeholder: "例如：iOS 26.0", text: $systemVersion)
                                field(title: "联系方式（可选）", placeholder: "QQ / Telegram / 邮箱", text: $contact)
                            }
                        }
                        GlassCard {
                            VStack(alignment: .leading, spacing: 8) {
                                label("问题描述")
                                ZStack(alignment: .topLeading) {
                                    if message.isEmpty {
                                        Text("请描述出现问题时的操作和现象")
                                            .font(BeansFont.appFont(14))
                                            .foregroundStyle(Color.beansComment)
                                            .padding(.top, 8).padding(.leading, 5)
                                    }
                                    TextEditor(text: $message)
                                        .font(BeansFont.appFont(14))
                                        .frame(minHeight: 140)
                                        .beansScrollContentBackgroundHidden()
                                }
                            }
                        }
                        attachmentCard
                        if let errorText {
                            Text(errorText)
                                .font(BeansFont.appFont(13))
                                .foregroundStyle(Color.red)
                        }
                        Text("请填写设备信息和遇到的问题；图片与视频可选。")
                            .font(BeansFont.appFont(12))
                            .foregroundStyle(Color.beansComment)
                        GlassButton(title: submitting ? "正在提交…" : "提交反馈", systemName: "paperplane.fill", prominent: true) {
                            Task { await submit() }
                        }
                        .disabled(!canSubmit)
                        .opacity(canSubmit ? 1 : 0.5)
                    }
                    .padding(16)
                    .padding(.bottom, 30)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
                .beansScrollIndicatorsHidden()
            }
            .navigationTitle("问题反馈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("我的反馈") { showHistory = true }
                }
            }
        }
        .sheet(isPresented: $showMediaPicker) {
            FeedbackMediaPicker(limit: max(1, maxAttachments - attachments.count)) { urls in
                add(urls: urls)
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                add(urls: urls, securityScoped: true)
            }
        }
        .sheet(isPresented: $showHistory) {
            FeedbackHistoryView().environmentObject(theme)
        }
        .onAppear {
            if deviceModel.isEmpty { deviceModel = DeviceReporter.marketingModelHint() }
        }
    }

    private var attachmentCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                label("附件")
                Text("可选：图片、视频或文件").font(BeansFont.appFont(12)).foregroundStyle(Color.beansComment)
                ForEach(attachments) { item in
                    HStack {
                        Image(systemName: "paperclip")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.filename).font(BeansFont.appFont(13)).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                                .font(BeansFont.appFont(11)).foregroundStyle(Color.beansComment)
                        }
                        Spacer()
                        Button {
                            attachments.removeAll { $0.id == item.id }
                            try? FileManager.default.removeItem(at: item.url)
                        } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.beansComment) }
                            .buttonStyle(.plain)
                    }
                }
                if attachments.count < maxAttachments {
                    HStack(spacing: 10) {
                        GlassButton(title: "从照片或视频选择", systemName: "photo.on.rectangle") { showMediaPicker = true }
                        GlassButton(title: "选择文件", systemName: "doc") { showFileImporter = true }
                    }
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(BeansFont.appFont(13, .semibold)).foregroundStyle(Color.beansLabel)
    }

    private func field(title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label(title)
            TextField(placeholder, text: text)
                .font(BeansFont.appFont(14))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func add(urls: [URL], securityScoped: Bool = false) {
        for url in urls {
            guard attachments.count < maxAttachments else { errorText = "最多只能上传 4 个附件。"; break }
            let scoped = securityScoped && url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString)-\(url.lastPathComponent)")
            do {
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.copyItem(at: url, to: dest)
                let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > maxBytes {
                    try? FileManager.default.removeItem(at: dest)
                    errorText = "单个附件不能超过 50 MB。"
                    continue
                }
                let type = UTType(filenameExtension: dest.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                attachments.append(PendingAttachment(filename: url.lastPathComponent, mimeType: type, url: dest, size: size))
                errorText = nil
            } catch {
                errorText = "附件读取失败，请重新选择。"
            }
        }
    }

    @MainActor
    private func submit() async {
        submitting = true
        errorText = nil
        defer { submitting = false }
        let content = """
        设备：\(deviceModel.trimmingCharacters(in: .whitespacesAndNewlines))
        系统：\(systemVersion.trimmingCharacters(in: .whitespacesAndNewlines))
        版本：\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))

        \(message.trimmingCharacters(in: .whitespacesAndNewlines))
        """
        do {
            var files: [BackendAttachment] = []
            for a in attachments {
                files.append(BackendAttachment(filename: a.filename, mimeType: a.mimeType, data: try Data(contentsOf: a.url)))
            }
            _ = try await MoumusicBackendAPI.submitFeedback(content: content, contact: contact, attachments: files)
            DeviceReporter.shared.markDownloadUnlocked()
            for a in attachments { try? FileManager.default.removeItem(at: a.url) }
            ToastCenter.shared.show("反馈已提交，下载功能已解锁")
            BeansHaptics.success()
            dismiss()
        } catch {
            errorText = (error as? BackendError)?.errorDescription ?? "提交失败，请稍后重试。"
        }
    }
}

// MARK: - 历史

@MainActor
struct FeedbackHistoryView: View {
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @State private var records: [MoumusicBackendAPI.FeedbackRecord] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var pendingDelete: MoumusicBackendAPI.FeedbackRecord?

    var body: some View {
        BeansNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if loading && records.isEmpty {
                            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                        } else if let errorText, records.isEmpty {
                            Text(errorText).font(BeansFont.appFont(13)).foregroundStyle(Color.beansComment)
                        } else if records.isEmpty {
                            Text("暂无反馈工单").font(BeansFont.appFont(14)).foregroundStyle(Color.beansComment)
                                .frame(maxWidth: .infinity).padding(.top, 40)
                        }
                        ForEach(records) { record in
                            GlassCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(record.submittedAt.prefix(16).replacingOccurrences(of: "T", with: " "))
                                            .font(BeansFont.appFont(11)).foregroundStyle(Color.beansComment)
                                        Spacer()
                                        if !record.replies.isEmpty {
                                            Text("\(record.replies.count) 条工单回复")
                                                .font(BeansFont.appFont(11, .semibold)).foregroundStyle(Color.beansAmber)
                                        }
                                        Button { pendingDelete = record } label: {
                                            Image(systemName: "trash").foregroundStyle(Color.beansComment)
                                        }.buttonStyle(.plain)
                                    }
                                    Text(record.content).font(BeansFont.appFont(13)).foregroundStyle(Color.beansLabel)
                                    ForEach(record.replies) { reply in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("开发者回复").font(BeansFont.appFont(11, .semibold)).foregroundStyle(Color.beansAmber)
                                            Text(reply.content).font(BeansFont.appFont(13)).foregroundStyle(Color.beansLabel)
                                        }
                                        .padding(10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.beansAmber.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
                .beansScrollIndicatorsHidden()
            }
            .navigationTitle("我的反馈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .task { await load() }
        .alert("删除这条反馈工单？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("删除", role: .destructive) {
                if let record = pendingDelete { Task { await delete(record) } }
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("删除后无法恢复。")
        }
    }

    @MainActor private func load() async {
        loading = true
        defer { loading = false }
        do {
            records = try await MoumusicBackendAPI.feedbackRecords()
            errorText = nil
        } catch {
            errorText = "获取反馈记录失败"
        }
    }

    @MainActor private func delete(_ record: MoumusicBackendAPI.FeedbackRecord) async {
        pendingDelete = nil
        do {
            try await MoumusicBackendAPI.deleteFeedback(id: record.id)
            records.removeAll { $0.id == record.id }
            ToastCenter.shared.show("反馈工单已删除")
        } catch {
            ToastCenter.shared.show("删除反馈失败")
        }
    }
}

// MARK: - 照片/视频选择

struct FeedbackMediaPicker: UIViewControllerRepresentable {
    let limit: Int
    let onPicked: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = limit
        config.filter = .any(of: [.images, .videos])
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: ([URL]) -> Void
        init(onPicked: @escaping ([URL]) -> Void) { self.onPicked = onPicked }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            let group = DispatchGroup()
            var urls: [URL] = []
            let lock = NSLock()
            for result in results {
                let provider = result.itemProvider
                let typeID = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) ? UTType.movie.identifier : UTType.image.identifier
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
                    defer { group.leave() }
                    guard let url = url else { return }
                    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("pick-\(UUID().uuidString)-\(url.lastPathComponent)")
                    if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                        lock.lock(); urls.append(dest); lock.unlock()
                    }
                }
            }
            group.notify(queue: .main) { [onPicked] in onPicked(urls) }
        }
    }
}

extension DeviceReporter {
    /// 反馈页的默认设备型号：优先设备名，其次硬件标识。
    nonisolated static func marketingModelHint() -> String {
        var sys = utsname()
        uname(&sys)
        let id = withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
        return id
    }
}
