import SwiftUI

/// Shown in the main window until the local runtime and models are in place.
struct RuntimeSetupView: View {
    @ObservedObject var setup: RuntimeSetup
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var running: Bool { setup.phase == .running }
    private var failure: String? {
        if case .failed(let message) = setup.phase { return message }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                EclipseMark(live: running)
                    .frame(width: 104, height: 104)
                    .padding(.bottom, 22)
                Text("欢迎使用 LiveSub")
                    .font(.system(size: 26, weight: .semibold))
                Text("第一次使用需要下载本地语音识别与翻译模型，约 \(RuntimeSetup.gigabytes(setup.totalBytes))。\n下载完成后，识别和翻译都在这台 Mac 上进行，不再需要联网。")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.top, 10)

                VStack(spacing: 0) {
                    ForEach(setup.steps) { step in
                        stepRow(step)
                        if step.id < setup.steps.count - 1 {
                            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 52)
                        }
                    }
                }
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
                .frame(width: 470)
                .padding(.top, 30)

                if running || setup.downloadedBytes > 0 && failure != nil {
                    progress.frame(width: 470).padding(.top, 20)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.caution)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(width: 470, alignment: .leading)
                        .padding(.top, 16)
                        .transition(.opacity)
                }

                actions.padding(.top, 24)

                Text(setup.usingMirror ? "下载可以随时取消，下次打开会从中断处继续 · 正在使用国内镜像"
                                       : "下载可以随时取消，下次打开会从中断处继续")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 16)
            }
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: setup.phase)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: setup.stepIndex)
        }
    }

    private func stepRow(_ step: RuntimeSetup.Step) -> some View {
        let done = setup.phase == .ready || step.id < setup.stepIndex && (running || failure != nil)
        let active = running && step.id == setup.stepIndex
        let failed = failure != nil && step.id == setup.stepIndex
        return HStack(spacing: 14) {
            ZStack {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                } else if active {
                    ProgressView().controlSize(.small).transition(.opacity)
                } else if failed {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.caution)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                } else {
                    Image(systemName: "circle").foregroundStyle(.tertiary).transition(.opacity)
                }
            }
            .font(.system(size: 18))
            .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(done || active ? .primary : .secondary)
                Text(step.detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(RuntimeSetup.gigabytes(step.expectedBytes))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "已完成" : active ? "进行中" : failed ? "失败" : "等待")
    }

    private var progress: some View {
        let fraction = min(1, Double(setup.downloadedBytes) / Double(max(1, setup.totalBytes)))
        var line = "\(RuntimeSetup.gigabytes(setup.downloadedBytes)) / \(RuntimeSetup.gigabytes(setup.totalBytes))"
        if running, setup.bytesPerSecond > 200_000 {
            let remaining = Double(setup.totalBytes - setup.downloadedBytes) / setup.bytesPerSecond
            line += String(format: " · %.1f MB/s", setup.bytesPerSecond / 1_000_000)
            line += remaining > 90 ? " · 约 \(Int((remaining / 60).rounded())) 分钟" : " · 不到 2 分钟"
        }
        return VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: fraction).tint(Theme.accent)
                .animation(reduceMotion ? nil : .linear(duration: 1.4), value: fraction)
            HStack {
                Text(line).monospacedDigit()
                Spacer()
                Text("\(Int(fraction * 100))%").monospacedDigit()
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        if running {
            Button("取消") { setup.cancel() }
                .buttonStyle(LiftButtonStyle(prominent: false))
                .transition(.opacity)
        } else {
            Button {
                setup.start()
            } label: {
                Label(failure == nil ? "开始下载" : "重试", systemImage: failure == nil ? "arrow.down.circle" : "arrow.clockwise")
            }
            .buttonStyle(LiftButtonStyle())
            .keyboardShortcut(.defaultAction)
            .transition(.opacity)
        }
    }
}
