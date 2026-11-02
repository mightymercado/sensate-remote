import Foundation
import CoreBluetooth

// Sensate 2 BLE protocol (reverse-engineered from the official app + firmware 0.4.40).
// Service: 00001813-0000-1000-8000-00805f9b30fb
//   2A5A DEVCTRL:  a2 -> notify ed a2 <pct> <usb> <mv_lo> <mv_hi>
//   2A57 PLAYBACK: c9 <gain> volume | c1 <hi> <lo> 00 00 play@offset | c2 pause | c4 stop | c5 resume
// Acks arrive as notifications: ec <cmd> (echo), status ff = rejected.
// Device keeps playing standalone after disconnect.

enum BleState: Equatable {
    case idle
    case scanning
    case connecting
    case ready
    case busy(String)
    case playing
    case failed(String)
}

struct DeviceStatus {
    var batteryPercent: Int?
    var usbPowered: Bool?
    var millivolts: Int?
}

final class SensateBLE: NSObject, ObservableObject {
    static let service = CBUUID(string: "00001813-0000-1000-8000-00805f9b30fb")
    static let devctrl = CBUUID(string: "00002A5A-0000-1000-8000-00805F9B30FB")
    static let playback = CBUUID(string: "00002A57-0000-1000-8000-00805F9B30FB")

    @Published var state: BleState = .idle
    @Published var status = DeviceStatus()
    @Published var lastAck: String?

    var deviceName: String
    private var manager: CBCentralManager?
    private var device: CBPeripheral?
    private var chars: [CBUUID: CBCharacteristic] = [:]

    // Command sequencing
    private var pending: [(CBUUID, Data, String)] = []   // char, bytes, tag
    private var onAllDone: (() -> Void)?
    private var onFail: ((String) -> Void)?
    private var batteryOnly = false

    init(deviceName: String = "BioSelf 3542") {
        self.deviceName = deviceName
        super.init()
    }

    // MARK: Public operations

    func connectAndRun(_ steps: [(CBUUID, Data, String)],
                       done: @escaping () -> Void,
                       fail: @escaping (String) -> Void) {
        pending = steps
        onAllDone = done
        onFail = fail
        state = .scanning
        let m = manager ?? CBCentralManager(delegate: self, queue: nil)
        manager = m
        if m.state == .poweredOn { m.scanForPeripherals(withServices: nil) }
    }

    func queryStatus() {
        batteryOnly = true
        state = .busy("checking")
        connectAndRun([(Self.devctrl, Data([0xa2]), "battery")], done: { [weak self] in
            self?.state = .idle
        }, fail: { [weak self] msg in
            self?.state = .failed(msg)
        })
    }

    func startPlayback(volumePercent: Int, offsetSeconds: Int = 0) {
        state = .busy("starting")
        let gain = UInt8(min(95, Double(volumePercent) * 95.0 / 100.0))
        let off = UInt16(offsetSeconds)
        let play = Data([0xc1, UInt8(off >> 8), UInt8(off & 0xff), 0, 0])
        connectAndRun([
            (Self.playback, Data([0xc9, gain]), "volume"),
            (Self.playback, play, "play")
        ], done: { [weak self] in
            self?.state = .playing
        }, fail: { [weak self] msg in
            self?.state = .failed(msg)
        })
    }

    func stopPlayback() {
        state = .busy("stopping")
        connectAndRun([(Self.playback, Data([0xc4]), "stop")], done: { [weak self] in
            self?.state = .idle
        }, fail: { [weak self] msg in
            self?.state = .failed(msg)
        })
    }

    func pausePlayback() {
        state = .busy("pausing")
        connectAndRun([(Self.playback, Data([0xc2]), "pause")], done: { [weak self] in
            self?.state = .idle
        }, fail: { [weak self] msg in
            self?.state = .failed(msg)
        })
    }

    func resumePlayback() {
        state = .busy("resuming")
        connectAndRun([(Self.playback, Data([0xc5]), "resume")], done: { [weak self] in
            self?.state = .playing
        }, fail: { [weak self] msg in
            self?.state = .failed(msg)
        })
    }

    func teardown() {
        if let d = device { manager?.cancelPeripheralConnection(d) }
        device = nil
        state = .idle
    }
}

extension SensateBLE: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            if central.state == .poweredOff || central.state == .unauthorized {
                state = .failed("Bluetooth is \(central.state == .poweredOff ? "off" : "unauthorized")")
            }
            return
        }
        if state == .scanning { central.scanForPeripherals(withServices: nil) }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        guard name == deviceName || name.hasPrefix(deviceName) else { return }
        central.stopScan()
        device = peripheral
        peripheral.delegate = self
        state = .connecting
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .failed("Connect failed — is the Sensate app connected? Close it and retry.")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        device = nil
        if case .failed = state { return }
        if case .playing = state { return }   // device keeps playing standalone
        if case .idle = state { return }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            state = .failed("Sensate service missing")
            return
        }
        peripheral.discoverCharacteristics([Self.devctrl, Self.playback], for: s)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] { chars[c.uuid] = c }
        guard let d = chars[Self.devctrl], let p = chars[Self.playback] else {
            state = .failed("Characteristics missing")
            return
        }
        peripheral.setNotifyValue(true, for: d)
        peripheral.setNotifyValue(true, for: p)
        nextStep()
    }

    private func nextStep() {
        guard let device, !pending.isEmpty else {
            finishOps()
            return
        }
        let (uuid, data, _) = pending.removeFirst()
        guard let c = chars[uuid] else {
            state = .failed("Missing characteristic \(uuid)")
            return
        }
        device.writeValue(data, for: c, type: .withResponse)
    }

    private func finishOps() {
        let done = onAllDone
        let fail = onFail
        onAllDone = nil
        onFail = nil
        // brief settle so final notifications arrive, then disconnect
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            if let d = self.device { self.manager?.cancelPeripheralConnection(d) }
            done?()
            _ = fail
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            state = .failed("Write failed: \(error.localizedDescription)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.nextStep() }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, data.count >= 2 else { return }
        let hex = data.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
        lastAck = hex
        if characteristic.uuid == Self.devctrl, data.count >= 6, data[0] == 0xed, data[1] == 0xa2 {
            status.batteryPercent = Int(data[2])
            status.usbPowered = Int(data[3]) == 1
            status.millivolts = Int(data[4]) | (Int(data[5]) << 8)
        }
        if data[0] == 0xec && data.count > 2 && data[2] == 0xff {
            state = .failed("Device rejected command (status ff)")
        }
    }
}
