import Foundation
import CoreBluetooth

/// The Bluetooth leg of the transport probe. See NetProbe.swift for the
/// whole picture.
///
/// The phone plays the LE peripheral, the TV the central, which mirrors
/// what the real feature would have to do: iOS will not let an app be a
/// system level HID controller, so an app to app GATT link is the only
/// Bluetooth shape available. Data flows phone to TV as notifications on
/// one characteristic, echoes flow back as unacknowledged writes on a
/// second, both chosen because they are the fire and forget primitives on
/// each side and anything acknowledged would measure the acknowledgement.
enum NetProbeBLE {
    static let service = CBUUID(string: "0BE7C0DE-CAB1-4E70-9E10-000000000001")
    static let dataCharacteristic = CBUUID(string: "0BE7C0DE-CAB1-4E70-9E10-000000000002")
    static let echoCharacteristic = CBUUID(string: "0BE7C0DE-CAB1-4E70-9E10-000000000003")
}

#if os(iOS)
/// Phone side: advertise, accept a subscriber, push packets as
/// notifications. `send` reports whether the stack accepted the packet;
/// a full queue is recorded as a drop by the caller rather than retried,
/// because a retried packet would arrive with a stale timestamp and count
/// as radio latency it never experienced.
final class BLEPeripheralSender: NSObject, CBPeripheralManagerDelegate {
    private let onState: (String) -> Void
    private let onEcho: (Data) -> Void
    private var manager: CBPeripheralManager?
    private var dataChar: CBMutableCharacteristic?
    private var subscribed = false

    init(onState: @escaping (String) -> Void, onEcho: @escaping (Data) -> Void) {
        self.onState = onState
        self.onEcho = onEcho
        super.init()
    }

    func start() {
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    func stop() {
        manager?.stopAdvertising()
        manager = nil
    }

    /// True when the packet was handed to the stack. False when nobody is
    /// subscribed yet or the notification queue is full.
    func send(_ data: Data) -> Bool {
        guard subscribed, let manager, let dataChar else { return false }
        return manager.updateValue(data, for: dataChar, onSubscribedCentrals: nil)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            onState("bluetooth \(peripheral.state.rawValue)")
            return
        }
        let data = CBMutableCharacteristic(
            type: NetProbeBLE.dataCharacteristic, properties: [.notify],
            value: nil, permissions: [.readable])
        let echo = CBMutableCharacteristic(
            type: NetProbeBLE.echoCharacteristic, properties: [.writeWithoutResponse],
            value: nil, permissions: [.writeable])
        dataChar = data
        let service = CBMutableService(type: NetProbeBLE.service, primary: true)
        service.characteristics = [data, echo]
        peripheral.add(service)
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [NetProbeBLE.service],
            CBAdvertisementDataLocalNameKey: "CabinetProbe",
        ])
        onState("advertising")
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        subscribed = true
        onState("subscribed, interval capable of \(central.maximumUpdateValueLength) bytes")
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        subscribed = false
        onState("unsubscribed")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests where request.characteristic.uuid == NetProbeBLE.echoCharacteristic {
            if let value = request.value { onEcho(value) }
        }
    }
}
#endif

/// TV side: scan, connect, subscribe, hand every notification up, write
/// echo replies back without response. Reconnects on drop so a phone that
/// wandered out of the run can rejoin without touching the TV.
final class BLECentralReceiver: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let onState: (String) -> Void
    private let onPacket: (Data, @escaping (Data) -> Void) -> Void
    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var echoChar: CBCharacteristic?

    init(
        onState: @escaping (String) -> Void,
        onPacket: @escaping (Data, @escaping (Data) -> Void) -> Void
    ) {
        self.onState = onState
        self.onPacket = onPacket
        super.init()
    }

    func start() {
        manager = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            onState("bluetooth \(central.state.rawValue)")
            return
        }
        central.scanForPeripherals(withServices: [NetProbeBLE.service])
        onState("scanning")
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        guard self.peripheral == nil else { return }
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral)
        onState("connecting")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([NetProbeBLE.service])
    }

    func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        self.peripheral = nil
        echoChar = nil
        onState("disconnected, rescanning")
        central.scanForPeripherals(withServices: [NetProbeBLE.service])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == NetProbeBLE.service })
        else { return }
        peripheral.discoverCharacteristics(
            [NetProbeBLE.dataCharacteristic, NetProbeBLE.echoCharacteristic], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == NetProbeBLE.dataCharacteristic {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            if characteristic.uuid == NetProbeBLE.echoCharacteristic {
                echoChar = characteristic
            }
        }
        onState("subscribed")
    }

    func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == NetProbeBLE.dataCharacteristic,
              let value = characteristic.value else { return }
        onPacket(value) { [weak self] reply in
            guard let self, let echoChar = self.echoChar else { return }
            peripheral.writeValue(reply, for: echoChar, type: .withoutResponse)
        }
    }
}
