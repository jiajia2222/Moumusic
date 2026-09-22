#if os(iOS)
import SwiftUI
import UIKit
import WebKit

struct AfdianSupportView: View {
    @StateObject private var store = AfdianSupportStore.shared
    @State private var selectedAmount = 30
    @State private var showPayment = false

    private let amounts = [5, 10, 30, 68]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                supportPicker
                stats
                sponsorList
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("赞助与支持")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load() }
        .refreshable { await store.load(force: true) }
        .sheet(isPresented: $showPayment) {
            AfdianPaymentSheet(selectedAmount: selectedAmount)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.orange.opacity(0.16))
                    Image(systemName: "heart.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 4) {
                    Text("支持 Moumusic")
                        .font(.title2.weight(.bold))
                    Text("每一份支持都会回到维护、修复和新的播放体验里。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text("选择一个支持金额后，在应用内打开爱发电官方方案页完成支付。金额和订单由爱发电处理。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var supportPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择支持金额")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(amounts, id: \.self) { amount in
                    Button {
                        selectedAmount = amount
                    } label: {
                        Text("¥\(amount)")
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.plain)
                    .background(
                        selectedAmount == amount ? Color.orange.opacity(0.18) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(selectedAmount == amount ? Color.orange : .clear, lineWidth: 1.5)
                    }
                    .accessibilityAddTraits(selectedAmount == amount ? .isSelected : [])
                }
            }

            Button {
                showPayment = true
            } label: {
                Label("支持 ¥\(selectedAmount)", systemImage: "heart.fill")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
    }

    private var stats: some View {
        HStack(spacing: 10) {
            statCard(title: "支持者", value: store.stats.map { String($0.supporterCount) } ?? "—")
            statCard(title: "最近支持", value: relativeDate(store.stats?.recentSupportAt))
            statCard(
                title: "累计支持",
                value: store.stats?.showAmount == true
                    ? money(store.stats?.totalAmount)
                    : "持续支持中"
            )
        }
    }

    private func statCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var sponsorList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("赞助者名单").font(.headline)
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small) }
            }

            if let errorMessage = store.errorMessage, store.sponsors.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark").foregroundStyle(.secondary)
                    Text(errorMessage).font(.subheadline).foregroundStyle(.secondary)
                    Button("重新加载") { Task { await store.load(force: true) } }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else if store.sponsors.isEmpty && !store.isLoading {
                Text("还没有公开赞助记录\n感谢每一位未来的支持者 ❤️")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(store.sponsors) { sponsor in
                        sponsorCard(sponsor)
                    }
                }
            }
        }
    }

    private func sponsorCard(_ sponsor: AfdianSponsorService.Sponsor) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: sponsor.avatar.flatMap(URL.init)) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 42, height: 42)
            .background(Color.secondary.opacity(0.12), in: Circle())
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(sponsor.name).font(.subheadline.weight(.semibold))
                Text(sponsor.plan ?? "持续支持中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.stats?.showAmount == true, let amount = sponsor.amount {
                Text("¥\(amount, format: .number.precision(.fractionLength(0...2)))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
            } else {
                Text("感谢支持")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func money(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "¥\(value, format: .number.precision(.fractionLength(0...2)))"
    }

    private func relativeDate(_ timestamp: Int?) -> String {
        guard let timestamp else { return "—" }
        return RelativeDateTimeFormatter().localizedString(
            for: Date(timeIntervalSince1970: TimeInterval(timestamp)), relativeTo: Date()
        )
    }
}

private struct AfdianPaymentSheet: View {
    let selectedAmount: Int
    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView?
    @State private var hasFailed = false

    private let url = URL(string: "https://ifdian.net/a/moumou2026/plan")!

    var body: some View {
        NavigationStack {
            ZStack {
                if webView == nil && !hasFailed { ProgressView("正在打开爱发电…") }
                AfdianWebView(webView: $webView, url: url, hasFailed: $hasFailed)
                    .ignoresSafeArea(.container, edges: .bottom)
                if hasFailed {
                    VStack(spacing: 14) {
                        Image(systemName: "safari").font(.largeTitle).foregroundStyle(.secondary)
                        Text("爱发电页面暂时无法在应用内加载")
                            .font(.headline)
                        Text("可以使用系统浏览器继续完成支持。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("用 Safari 打开") {
                            UIApplication.shared.open(url)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(24)
                }
            }
            .navigationTitle("支持 ¥\(selectedAmount)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}

private struct AfdianWebView: UIViewRepresentable {
    @Binding var webView: WKWebView?
    let url: URL
    @Binding var hasFailed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        DispatchQueue.main.async { webView = view }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        var owner: AfdianWebView
        init(owner: AfdianWebView) { self.owner = owner }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.owner.hasFailed = true }
        }
    }
}
#endif
