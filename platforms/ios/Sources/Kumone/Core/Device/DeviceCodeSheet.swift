#if os(iOS)
import SwiftUI

/// Shows this device's code (the key behind the user ID) and lets a code from a
/// previous install be restored, so the same ID comes back after a reinstall.
struct DeviceCodeSheet: View {
    @ObservedObject private var reporter = DeviceReporter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var restoreText = ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("用户 ID", value: reporter.displayID)
                    Text(reporter.deviceUserID)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = reporter.deviceUserID
                        message = "设备码已复制"
                    } label: {
                        Label("复制设备码", systemImage: "doc.on.doc")
                    }
                } header: {
                    Text("本机设备码")
                } footer: {
                    Text("设备码决定你的用户 ID。App 会把它保存在钥匙串和本机文件里，覆盖安装或重新安装通常不会变；如果换了签名后 ID 变了，把原来的设备码填到下面即可恢复。")
                }
                Section("恢复设备码") {
                    TextField("粘贴原来的设备码", text: $restoreText, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                    Button("恢复") {
                        if StableDeviceID.restore(restoreText) {
                            reporter.adoptRestoredDeviceCode()
                            message = "已恢复，ID 将在几秒内更新"
                            restoreText = ""
                        } else {
                            message = "设备码格式不正确"
                        }
                    }
                    .disabled(restoreText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("用户 ID 与设备码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}
#endif