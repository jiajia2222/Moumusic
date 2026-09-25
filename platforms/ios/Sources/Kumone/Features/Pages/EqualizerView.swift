import SwiftUI
import Foundation

/// Beans-Music-style equalizer page.  It is intentionally a separate page so
/// the source manager remains focused on source selection and import.
struct EqualizerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var equalizer = MoumusicEqualizer.shared
    @State private var presetName = ""
    @State private var isShowingPresetName = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    previewCard
                    enableCard
                    presetsCard
                    bandsCard
                }
                .padding(16)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(Color.primary.opacity(0.03).ignoresSafeArea())
            .navigationTitle("均衡器")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .alert("保存自定义预设", isPresented: $isShowingPresetName) {
            TextField("预设名称", text: $presetName)
            Button("保存") {
                guard equalizer.saveCustomPreset(name: presetName) else {
                    ToastCenter.shared.show("请输入预设名称")
                    return
                }
                presetName = ""
            }
            Button("取消", role: .cancel) { presetName = "" }
        } message: {
            Text("保存当前十段频响和前级增益")
        }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("频响预览")
                        .font(.headline.weight(.semibold))
                    Text("调整下方频段，实时塑造声音")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "waveform.path.ecg")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }

            EqualizerCurveView(gains: equalizer.bandGains)
                .frame(height: 150)
                .padding(10)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            HStack {
                Text("31 Hz")
                Spacer()
                Text("1 kHz")
                Spacer()
                Text("16 kHz")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .glassContainer()
    }

    private var enableCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.path.ecg.rectangle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("启用均衡器")
                        .font(.body.weight(.semibold))
                    Text(equalizer.isEnabled ? "正在对播放音频实时处理" : "关闭后保持原始音频")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { equalizer.isEnabled },
                    set: { equalizer.setEnabled($0) }
                ))
                .labelsHidden()
                .tint(Theme.accent)
            }
            .frame(minHeight: 44)

            Divider().padding(.vertical, 10)

            HStack {
                Text("前级增益")
                Spacer()
                Text(String(format: "%+.1f dB", equalizer.preampGain))
                    .foregroundStyle(equalizer.preampGain == 0 ? .secondary : Theme.accent)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { equalizer.preampGain },
                    set: { equalizer.setPreampGain($0) }
                ),
                in: -12...12,
                step: 0.5
            )
            .tint(Theme.accent)
            HStack {
                Text("-12")
                Spacer()
                Text("不增益")
                Spacer()
                Text("+12")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .glassContainer()
    }

    private var presetsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("预设")
                    .font(.headline.weight(.semibold))
                Spacer()
                Button {
                    isShowingPresetName = true
                } label: {
                    Label("保存当前", systemImage: "square.and.arrow.down")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(MoumusicEqualizerPreset.allCases.filter { $0 != .custom }) { preset in
                    presetButton(title: preset.displayName, selected: equalizer.selectedPreset == preset) {
                        equalizer.applyPreset(preset)
                    }
                }
            }

            ForEach(equalizer.customPresets) { preset in
                HStack(spacing: 8) {
                    Button {
                        equalizer.applyCustomPreset(preset)
                    } label: {
                        HStack {
                            Text(preset.name)
                            Spacer()
                            if equalizer.selectedCustomPresetName == preset.name {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    Button(role: .destructive) {
                        equalizer.deleteCustomPreset(preset)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .frame(width: 44, height: 44)
                }
                .padding(.horizontal, 12)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .glassContainer()
    }

    private func presetButton(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(selected ? Theme.accent.opacity(0.18) : Color.primary.opacity(0.045), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(selected ? Theme.accent.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Theme.accent : .primary)
    }

    private var bandsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("自定义调节")
                .font(.headline.weight(.semibold))
            Text("范围 −12 dB 至 +12 dB")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            ForEach(Array(MoumusicEqualizer.bandFrequencies.enumerated()), id: \.offset) { index, frequency in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(formatFrequency(frequency))
                        Spacer()
                        Text(String(format: "%+.1f dB", equalizer.bandGains[index]))
                            .foregroundStyle(equalizer.bandGains[index] == 0 ? .secondary : Theme.accent)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { equalizer.bandGains[index] },
                            set: { equalizer.setBandGain(at: index, to: $0) }
                        ),
                        in: -12...12,
                        step: 0.5
                    )
                    .tint(Theme.accent)
                }
                .padding(.vertical, 10)
                if index < MoumusicEqualizer.bandFrequencies.count - 1 {
                    Divider()
                }
            }
        }
        .glassContainer()
    }

    private func formatFrequency(_ value: Double) -> String {
        value >= 1_000 ? "\(Int(value / 1_000)) kHz" : "\(Int(value)) Hz"
    }
}

private struct EqualizerCurveView: View {
    let gains: [Double]

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let centerY = size.height / 2
                var grid = Path()
                for step in 1..<5 {
                    let y = size.height * CGFloat(step) / 5
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(.secondary.opacity(0.18)), lineWidth: 1)

                guard !gains.isEmpty else { return }
                var line = Path()
                for (index, gain) in gains.enumerated() {
                    let x = size.width * CGFloat(index) / CGFloat(max(gains.count - 1, 1))
                    let y = centerY - CGFloat(gain / 12) * (size.height * 0.42)
                    if index == 0 { line.move(to: CGPoint(x: x, y: y)) }
                    else { line.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(line, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

private extension View {
    func glassContainer() -> some View {
        padding(16)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}
