#if os(iOS)
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Qishui account synchronisation. This is intentionally separate from LX
/// playback: the QR flow only stores the validated account session in the
/// Keychain for recommendations and playlist metadata.
struct QishuiLoginSheet: View {
    private enum Phase: Equatable {
        case loading
        case waiting
        case scanned
        case expired
        case success
        case failed(String)
    }

    @EnvironmentObject private var qishui: QishuiSessionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var phase: Phase = .loading
    @State private var qrImage: UIImage?
    @State private var token: String?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Label("汽水音乐账号同步", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.title3.weight(.semibold))
                        .padding(.top, 12)

                    Text("使用抖音 App 扫描二维码完成登录。这里只同步账号资料、推荐和歌单，不会把汽水账号当作音源；歌曲仍由 LX 音源播放。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)

                    qrCard
                    statusView

                    if case .expired = phase {
                        Button("刷新二维码") { startLogin() }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                    } else if case .failed = phase {
                        Button("重新获取") { startLogin() }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                    }

                    Text("二维码由汽水 / 抖音账号服务生成，登录凭据只保存在本机钥匙串。扫码后请等待自动确认，不需要复制 Cookie。")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .navigationTitle("账号同步")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear { startLogin() }
            .onDisappear { pollTask?.cancel() }
            .onChange(of: scenePhase) { newPhase in
                guard newPhase == .active, token != nil,
                      pollTask == nil || pollTask?.isCancelled == true else { return }
                startLogin(reusingToken: true)
            }
        }
    }

    private var qrCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white)
                .frame(width: 272, height: 272)
                .shadow(color: .black.opacity(0.12), radius: 18, y: 8)

            if let qrImage {
                Image(uiImage: qrImage)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 232, height: 232)
                    .opacity(phase == .expired ? 0.25 : 1)
            } else {
                ProgressView()
            }

            if phase == .expired || phase == .scanned {
                VStack(spacing: 8) {
                    Image(systemName: phase == .expired ? "arrow.clockwise.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(phase == .expired ? Theme.accent : .green)
                    Text(phase == .expired ? "二维码已失效" : "已扫码，请在手机确认")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("汽水音乐账号同步二维码")
    }

    @ViewBuilder
    private var statusView: some View {
        switch phase {
        case .loading:
            Label("正在获取二维码…", systemImage: "arrow.triangle.2.circlepath")
        case .waiting:
            Label("打开抖音 App 扫一扫", systemImage: "qrcode.viewfinder")
        case .scanned:
            Label("已扫码，等待手机确认…", systemImage: "iphone")
        case .success:
            Label("账号同步成功", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .expired:
            Label("二维码已过期", systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(Theme.accent)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.accent)
                .multilineTextAlignment(.center)
        }
    }

    private func startLogin(reusingToken: Bool = false) {
        pollTask?.cancel()
        if !reusingToken {
            token = nil
            qrImage = nil
            phase = .loading
        } else {
            phase = .waiting
        }

        pollTask = Task { @MainActor in
            do {
                let activeToken: String
                if reusingToken, let token {
                    activeToken = token
                } else {
                    let payload = try await QishuiAPI.shared.qrCode()
                    activeToken = payload.token
                    token = payload.token
                    qrImage = Self.makeQRImage(from: payload.value)
                    phase = .waiting
                }

                var consecutiveErrors = 0
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(1.8))
                    do {
                        let result = try await QishuiAPI.shared.qrLoginStatus(token: activeToken)
                        consecutiveErrors = 0
                        switch result {
                        case .waiting:
                            phase = .waiting
                        case .scanned:
                            phase = .scanned
                        case .expired:
                            phase = .expired
                            pollTask = nil
                            return
                        case .failed(let message):
                            phase = .failed(message)
                            pollTask = nil
                            return
                        case .success(let cookie, let sessionID):
                            guard let credential = cookie ?? sessionID.map({ "sessionid=\($0)" }) else {
                                throw QishuiSessionStore.SessionError.validationFailed
                            }
                            try await qishui.signIn(cookie: credential)
                            phase = .success
                            pollTask = nil
                            ToastCenter.shared.show("汽水音乐账号同步成功")
                            dismiss()
                            return
                        }
                    } catch {
                        consecutiveErrors += 1
                        if consecutiveErrors >= 12 { throw error }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    pollTask = nil
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    private static func makeQRImage(from value: String) -> UIImage? {
        if value.hasPrefix("data:image/"),
           let comma = value.firstIndex(of: ","),
           let data = Data(base64Encoded: String(value[value.index(after: comma)...])) {
            return UIImage(data: data)
        }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
#endif
