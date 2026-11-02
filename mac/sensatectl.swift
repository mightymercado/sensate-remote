import Foundation
import CoreBluetooth

// sensatectl — controls a Sensate 2 ("BioSelf 3542") over BLE using the official
// app protocol. Commands: status | start | stop | pause | resume | volume N
//
// Protocol (service 00001813-0000-1000-8000-00805f9b30fb):
//   2A5A DEVCTRL:  a2 = battery query      -> notify ed a2 <pct> <usb> <mv_lo> <mv_hi>
//   2A57 PLAYBACK: c9 <gain> = set volume  -> ack ec <code> (code != ff = ok)
//                  c1 <off_hi> <off_lo> 00 00 = play from offset (seconds)
//                  c2 = pause, c4 = clear/stop, c5 = resume
// Device keeps playing after BLE disconnect; sessions survive standalone.

let deviceName = ProcessInfo.processInfo.environment["SENSATE_NAME"] ?? "BioSelf 3542"
// App slider 0-100% maps to device gain 0-95 (100% -> 95).
func gainFor(percent: UInt8) -> UInt8 { UInt8(Double(percent) * 95.0 / 100.0) }

func usage() -> Never {
    FileHandle.standardError.write("usage: sensatectl status | start [offset-seconds] | stop | pause | resume | volume <0-100>\n".data(using: .utf8)!)
    exit(64)
}

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first?.lowercased() ?? ""
if cmd.isEmpty { usage() }
var playOffset: UInt16 = 0
var volumePercent: UInt8 = 100
if cmd == "start", args.count > 1, let v = UInt16(args[1]) { playOffset = min(v, 3600) }
if cmd == "volume" {
    guard args.count > 1, let v = UInt8(args[1]), v <= 100 else { usage() }
    volumePercent = v
}

var lines: [String] = []
var batteryInfo: [String: Any]? = nil
var lastNotify: Data? = nil
var finished = false
let started = Date()

func log(_ s: String) { lines.append(String(format: "%.3f ", Date().timeIntervalSince(started)) + s) }

func emit(_ ok: Bool, _ result: [String: Any]) -> Never {
    guard !finished else { exit(ok ? 0 : 1) }
    finished = true
    var out: [String: Any] = ["ok": ok, "command": cmd, "log": lines]
    for (k, v) in result { out[k] = v }
    if let b = batteryInfo { out["battery"] = b }
    let d = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    let text = String(data: d, encoding: .utf8)!
    print(text)
    let outPath = ProcessInfo.processInfo.environment["SENSATECTL_OUT"]
        ?? NSHomeDirectory() + "/.sensatectl-last.json"
    try? text.write(toFile: outPath, atomically: true, encoding: .utf8)
    exit(ok ? 0 : 1)
}

final class Sensate: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var manager: CBCentralManager!
    var device: CBPeripheral?
    var chars: [String: CBCharacteristic] = [:]
    var pendingNotify = 0
    var phase = "init"
    let cmdArg: String
    let volumeArg: UInt8
    let offsetArg: UInt16

    init(cmd: String, volume: UInt8, offset: UInt16) {
        self.cmdArg = cmd
        self.volumeArg = volume
        self.offsetArg = offset
        super.init()
        manager = CBCentralManager(delegate: self, queue: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { [weak self] in
            if let s = self, !finished { emit(false, ["error": "timeout in phase \(s.phase)"]) }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            if central.state == .unsupported || central.state == .poweredOff {
                emit(false, ["error": "bluetooth \(central.state == .unsupported ? "unsupported" : "off")"])
            }
            return
        }
        phase = "scan"
        central.scanForPeripherals(withServices: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            if self.device == nil { emit(false, ["error": "device '\(deviceName)' not found (asleep or out of range?)"]) }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        guard name == deviceName, device == nil else { return }
        log("found \(name) RSSI \(RSSI)")
        device = peripheral
        central.stopScan()
        peripheral.delegate = self
        phase = "connect"
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        phase = "services"
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        emit(false, ["error": "connect failed (is the Sensate app connected? \(error.map(String.init(describing:)) ?? ""))"])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services, !services.isEmpty else {
            emit(false, ["error": "service discovery failed"]); return
        }
        phase = "characteristics"
        for s in services { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] { chars[String(c.uuid.uuidString.suffix(4))] = c }
        guard peripheral.services?.allSatisfy({ $0.characteristics != nil }) == true else { return }
        let want = ["2A5A", "2A57"].compactMap { chars[$0] }
        guard want.count == 2 else {
            emit(false, ["error": "characteristics missing", "found": Array(chars.keys).sorted()]); return
        }
        pendingNotify = 2
        for c in want { peripheral.setNotifyValue(true, for: c) }
        phase = "notify"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if self.pendingNotify > 0 { self.pendingNotify = 0; self.runOps() }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        log("notify \(characteristic.uuid.uuidString.suffix(4)) \(error == nil ? "on" : "err")")
        if pendingNotify > 0 { pendingNotify -= 1 }
        if pendingNotify == 0 { runOps() }
    }

    func runOps() {
        guard phase != "ops" else { return }
        phase = "ops"
        switch cmdArg {
        case "status":
            write("a2", to: "2A5A", tag: "battery")
            after(2.0) { self.wrapUp([:]) }
        case "start":
            write(String(format: "c9 %02x", gainFor(percent: volumeArg)), to: "2A57", tag: "volume")
            after(0.6) {
                let hi = UInt8((self.offsetArg >> 8) & 0xff), lo = UInt8(self.offsetArg & 0xff)
                self.write(String(format: "c1 %02x %02x 00 00", hi, lo), to: "2A57", tag: "play")
                self.after(1.5) {
                    self.wrapUp(["started": true, "gain": Int(gainFor(percent: self.volumeArg)), "offset_seconds": Int(self.offsetArg)])
                }
            }
        case "stop":
            write("c4", to: "2A57", tag: "stop")
            after(1.5) { self.wrapUp(["stopped": true]) }
        case "pause":
            write("c2", to: "2A57", tag: "pause")
            after(1.5) { self.wrapUp(["paused": true]) }
        case "resume":
            write("c5", to: "2A57", tag: "resume")
            after(1.5) { self.wrapUp(["resumed": true]) }
        case "volume":
            write(String(format: "c9 %02x", gainFor(percent: volumeArg)), to: "2A57", tag: "volume")
            after(1.5) { self.wrapUp(["gain": Int(gainFor(percent: self.volumeArg))]) }
        default:
            usage()
        }
    }

    func wrapUp(_ extra: [String: Any]) {
        guard !finished else { return }
        var res = extra
        if let n = lastNotify { res["last_notify"] = n.map { String(format: "%02x", $0) }.joined(separator: " ") }
        if let d = device { manager.cancelPeripheralConnection(d) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            emit(!res.keys.contains("error"), res)
        }
    }

    func write(_ hexStr: String, to char: String, tag: String) {
        guard let c = chars[char], let d = device else { emit(false, ["error": "missing char \(char)"]); return }
        let bytes = hexStr.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        log("TX \(char) [\(tag)] \(hexStr)")
        d.writeValue(Data(bytes), for: c, type: .withResponse)
    }

    func after(_ t: TimeInterval, _ f: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error { log("write err \(e.localizedDescription)") }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let data = characteristic.value ?? Data()
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        log("RX \(characteristic.uuid.uuidString.suffix(4)): \(hex)")
        lastNotify = data
        if characteristic.uuid.uuidString.hasSuffix("2A5A"), data.count >= 6, data[0] == 0xed, data[1] == 0xa2 {
            batteryInfo = ["percent": Int(data[2]), "usb_powered": Int(data[3]) == 1,
                           "millivolts": Int(data[4]) | (Int(data[5]) << 8)]
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if finished { exit(0) }
    }
}

let sensate = Sensate(cmd: cmd, volume: volumePercent, offset: playOffset)
RunLoop.main.run()
