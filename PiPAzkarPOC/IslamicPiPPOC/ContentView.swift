import SwiftUI
import AVFoundation

struct ContentView: View {
    @EnvironmentObject var engine: PiPEngine
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Islamic PiP Technical Test")
                    .font(.title2.bold())

                // In-app Arabic text (SwiftUI, RTL).
                Text(engine.currentText)
                    .font(.system(size: 34, weight: .bold))
                    .multilineTextAlignment(.center)
                    .environment(\.layoutDirection, .rightToLeft)
                    .frame(maxWidth: .infinity)

                // Inline video surface. PiP mirrors THIS layer, so it must be
                // on screen and "playing" when the app goes to the background.
                SampleBufferView(layer: engine.displayLayer)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack {
                    Button("Prepare PiP") { engine.prepare() }
                        .buttonStyle(.borderedProminent)
                    Button("Start PiP") { engine.startPiP() }
                        .buttonStyle(.bordered)
                        .disabled(!engine.isPrepared)
                    Button("Stop") { engine.stopPiP() }
                        .buttonStyle(.bordered)
                        .disabled(!engine.isActive)
                }

                VStack(alignment: .leading, spacing: 6) {
                    StatusRow(label: "PiP Supported", value: engine.isSupported)
                    StatusRow(label: "PiP Possible", value: engine.isPossible)
                    StatusRow(label: "PiP Active", value: engine.isActive)
                    StatusRow(label: "Playing", value: engine.isPlaying)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Auto-start PiP on background", isOn: $engine.autoStartEnabled)
                    Toggle("Audio (generated chime)", isOn: $engine.audioEnabled)
                    Picker("PiP controls", selection: $engine.controlsMode) {
                        ForEach(PiPEngine.ControlsMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Text("Test: tap Prepare PiP, then swipe up to Home. PiP should start by itself.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Log").font(.headline)
                    Spacer()
                    Button(copied ? "Copied" : "Copy results") {
                        UIPasteboard.general.string = engine.fullReportText
                        copied = true
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(engine.logLines.suffix(40).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
    }
}

private struct StatusRow: View {
    let label: String
    let value: Bool
    var body: some View {
        HStack {
            Image(systemName: value ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(value ? .green : .red)
            Text(label)
            Spacer()
            Text(value ? "YES" : "NO").font(.body.monospaced())
        }
    }
}

/// Hosts the AVSampleBufferDisplayLayer inside SwiftUI.
struct SampleBufferView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> HostView {
        let v = HostView()
        v.displayLayer = layer
        v.layer.addSublayer(layer)
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: HostView, context: Context) {}

    final class HostView: UIView {
        var displayLayer: AVSampleBufferDisplayLayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            displayLayer?.frame = bounds
        }
    }
}
