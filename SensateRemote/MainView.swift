import SwiftUI

struct MainView: View {
    @EnvironmentObject var ble: SensateBLE
    @EnvironmentObject var session: SessionEngine

    @State private var minutes = 60
    @State private var volume = 100
    @AppStorage("deviceName") private var deviceName = "BioSelf 3542"
    @State private var showSettings = false

    var body: some View {
        NavigationView {
            VStack(spacing: 28) {
                header

                ZStack {
                    Circle()
                        .stroke(lineWidth: 14)
                        .foregroundColor(.white.opacity(0.08))
                        .frame(width: 260, height: 260)
                    if session.active {
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(style: StrokeStyle(lineWidth: 14, lineCap: .round))
                            .foregroundColor(.teal)
                            .frame(width: 260, height: 260)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1), value: progress)
                    }
                    VStack(spacing: 8) {
                        if session.active {
                            Text(timeString(session.remaining))
                                .font(.system(size: 52, weight: .light, design: .monospaced))
                                .foregroundStyle(.white)
                                .monospacedDigit()
                        } else {
                            Image(systemName: "waveform.circle.fill")
                                .font(.system(size: 84))
                                .foregroundStyle(.teal)
                        }
                        Text(session.active ? "Be Sensate · \(volume)%" : "Be Sensate")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)

                if session.active {
                    Button {
                        session.stop(ble)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .padding(.horizontal, 40)
                } else {
                    Button {
                        ble.deviceName = deviceName
                        session.start(SessionEngine.Config(minutes: minutes, volumePercent: volume), ble: ble)
                    } label: {
                        Label("Start \(minutes) min", systemImage: "play.fill")
                            .font(.title2.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)
                    .padding(.horizontal, 40)
                    .disabled(busy)
                }

                if !session.active {
                    Picker("Duration", selection: $minutes) {
                        ForEach([10, 20, 30, 60, 90], id: \.self) { m in
                            Text("\(m) min").tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 40)

                    HStack {
                        Image(systemName: "speaker.wave.1.fill")
                        Slider(value: .init(get: { Double(volume) }, set: { volume = Int($0) }), in: 10...100, step: 5)
                        Text("\(volume)%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 44)
                }

                Spacer(minLength: 0)

                statusFooter
            }
            .navigationTitle("Sensate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(deviceName: $deviceName)
                    .presentationDetents([.medium])
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { ble.deviceName = deviceName }
    }

    private var busy: Bool {
        if case .busy = ble.state { return true }
        if case .scanning = ble.state { return true }
        if case .connecting = ble.state { return true }
        return false
    }

    private var progress: CGFloat {
        CGFloat(min(1, max(0, session.remaining / session.total)))
    }

    private var header: some View {
        HStack(spacing: 16) {
            if let pct = ble.status.batteryPercent {
                Label("\(pct)%", systemImage: ble.status.usbPowered == true ? "battery.100.bolt" : "battery.75percent")
            }
            switch ble.state {
            case .idle: Text("Ready").foregroundStyle(.secondary)
            case .scanning: Label("Searching…", systemImage: "antenna.radiowaves.left.and.right")
            case .connecting: Label("Connecting…", systemImage: "link")
            case .ready: Text("Connected")
            case .busy(let what): Label(what.capitalized + "…", systemImage: "gearshape.2")
            case .playing: Label("Playing", systemImage: "waveform")
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .lineLimit(2).font(.caption)
            }
            Spacer()
            Button {
                ble.queryStatus()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
        .font(.footnote)
        .padding(.horizontal, 40)
        .padding(.top, 12)
    }

    private var statusFooter: some View {
        VStack(spacing: 4) {
            if !session.sessionLog.isEmpty {
                ScrollView {
                    Text(session.sessionLog)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 64)
                .padding(.horizontal, 40)
            }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

struct SettingsView: View {
    @Binding var deviceName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Device name", text: $deviceName)
                } header: {
                    Text("Sensate Bluetooth name (default: BioSelf 3542)")
                } footer: {
                    Text("Free signing expires after 7 days — reopen the project in Xcode and rerun to the phone to renew.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
