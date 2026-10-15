import CoreBluetooth
import Foundation
import os
import UIKit

/// CoreBluetooth side of `Nudge`: moves already-sealed bytes between phones.
///
/// - Peripheral role (always on, including in the background via the `bluetooth-peripheral`
///   background mode): advertises this phone's doorbell service and hands each write
///   to `onReceive`. iOS wakes a suspended app to handle the write.
/// - Central role (foreground only): to ring someone, scans for their service UUID,
///   connects, writes one small payload, and disconnects. One nudge at a time.
///
/// Bluetooth isn't available in Simulator; every path degrades to doing nothing.
final class NudgeService: NSObject {
    private static let logger = Logger(subsystem: "com.dannyguillory.cruiselan", category: "nudge")
    /// Give up on a delivery that hasn't completed after this long (the person is out of range).
    /// Phones advertising in the background are discovered more slowly, so this is generous.
    private static let deliveryTimeout: Duration = .seconds(25)
    private static let staleAfter: TimeInterval = 90
    /// Lets iOS relaunch CruiseLAN in the background for an incoming nudge if it quit the app
    /// to free memory. Must stay the same across launches.
    private static let restoreIdentifier = "com.dannyguillory.cruiselan.nudge.peripheral"

    /// Called with the complete bytes of every write; `NudgeRouter` opens and validates them
    /// and returns whether the nudge was accepted.
    var onReceive: ((Data) -> Bool)?
    /// Most nudges waiting to go out at once (a burst of messages to many away people).
    private static let maxQueued = 24
    /// Give up quickly if Bluetooth never becomes available (off, unauthorized, resetting).
    private static let powerOnTimeout: Duration = .seconds(10)

    private let characteristicUUID = CBUUID(string: Nudge.characteristicUUIDString)
    private var localId: String?
    private var peripheralManager: CBPeripheralManager?
    private var centralManager: CBCentralManager?

    private struct Outgoing {
        let serviceUUID: CBUUID
        let data: Data
        let created: Date
        let completion: (Bool) -> Void
    }

    private var queue: [Outgoing] = []
    private var current: Outgoing?
    private var currentPeripheral: CBPeripheral?
    private var timeout: Task<Void, Never>?
    private var powerOnWait: Task<Void, Never>?
    /// Services iOS put back after relaunching the app; reused instead of rebuilt.
    private var restoredServices: [CBMutableService] = []

    /// Starts advertising this phone's doorbell. Call again if the CruiseLAN id changes.
    func start(localId: String) {
        guard self.localId != localId else { return }
        self.localId = localId
        if let peripheralManager {
            publish(on: peripheralManager)
        } else {
            // Creating the manager triggers the Bluetooth permission prompt the first time.
            peripheralManager = CBPeripheralManager(delegate: self, queue: nil,
                                                    options: [CBPeripheralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier])
        }
    }

    /// Writes sealed bytes to `targetId`'s phone if it's in Bluetooth range. `completion`
    /// reports whether the phone acknowledged the write.
    func send(_ data: Data, to targetId: String, completion: @escaping (Bool) -> Void) {
        // Scanning and connecting need the app in the foreground (CruiseLAN doesn't use the
        // Bluetooth-central background mode); a send started in the background can't finish.
        guard UIApplication.shared.applicationState == .active, queue.count < Self.maxQueued else {
            return completion(false)
        }
        queue.append(Outgoing(serviceUUID: CBUUID(string: Nudge.serviceUUIDString(for: targetId)), data: data, created: .now, completion: completion))
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
        }
        if centralManager?.state != .poweredOn, powerOnWait == nil {
            powerOnWait = Task { [weak self] in
                try? await Task.sleep(for: Self.powerOnTimeout)
                guard let self, !Task.isCancelled else { return }
                self.powerOnWait = nil
                if self.centralManager?.state != .poweredOn { self.failQueued() }
            }
        }
        advance()
    }

    /// Fails everything waiting (Bluetooth unavailable, or the app left the foreground).
    func failQueued() {
        let dropped = queue
        queue.removeAll()
        dropped.forEach { $0.completion(false) }
        finishCurrent(delivered: false)
    }

    // MARK: - Peripheral

    private func publish(on manager: CBPeripheralManager) {
        guard manager.state == .poweredOn, let localId else { return }
        let uuid = CBUUID(string: Nudge.serviceUUIDString(for: localId))
        // After a background relaunch iOS has already put our service back. Keep it, so a
        // friend's write that's in progress right now isn't cut off.
        if restoredServices.contains(where: { $0.uuid == uuid }) {
            restoredServices = []
            if !manager.isAdvertising { manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [uuid]]) }
            return
        }
        restoredServices = []
        manager.stopAdvertising()
        manager.removeAllServices()
        let service = CBMutableService(type: CBUUID(string: Nudge.serviceUUIDString(for: localId)), primary: true)
        service.characteristics = [
            CBMutableCharacteristic(type: characteristicUUID, properties: [.write], value: nil, permissions: [.writeable]),
        ]
        manager.add(service)
    }

    // MARK: - Central

    private func advance() {
        guard current == nil, let centralManager, centralManager.state == .poweredOn else { return }
        let stale = queue.filter { Date.now.timeIntervalSince($0.created) > Self.staleAfter }
        queue.removeAll { Date.now.timeIntervalSince($0.created) > Self.staleAfter }
        stale.forEach { $0.completion(false) }
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        current = next
        centralManager.scanForPeripherals(withServices: [next.serviceUUID])
        timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.deliveryTimeout)
            guard !Task.isCancelled else { return }
            self?.finishCurrent(delivered: false)
        }
    }

    private func finishCurrent(delivered: Bool) {
        guard let finished = current else { return }
        if !delivered { Self.logger.info("Nudge not delivered") }
        timeout?.cancel()
        timeout = nil
        centralManager?.stopScan()
        if let currentPeripheral {
            centralManager?.cancelPeripheralConnection(currentPeripheral)
        }
        currentPeripheral = nil
        current = nil
        finished.completion(delivered)
        advance()
    }
}

// MARK: - CBPeripheralManagerDelegate

extension NudgeService: @MainActor CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn { publish(on: peripheral) }
    }

    /// iOS relaunched the app to handle Bluetooth. The service is republished on power-on
    /// with the same UUID, because the session identity was restored from the Keychain.
    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        restoredServices = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] ?? []
        Self.logger.info("Restored nudge peripheral")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
        if let error {
            Self.logger.error("Couldn't publish nudge service: \(error.localizedDescription, privacy: .public)")
            return
        }
        // In the background, iOS moves the UUID to the "overflow" area, discoverable by
        // iPhones scanning for exactly this UUID, which is how friends find it.
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [service.uuid]])
    }

    /// A nudge larger than one Bluetooth packet arrives as several requests (a "long write"),
    /// each with its piece at an offset. They're one write: join them, check it, then answer
    /// once for all of them, with an error if it was rejected.
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard requests.allSatisfy({ $0.characteristic.uuid == characteristicUUID }) else {
            return peripheral.respond(to: first, withResult: .requestNotSupported)
        }
        var value = Data()
        for request in requests.sorted(by: { $0.offset < $1.offset }) {
            guard request.offset == value.count, let piece = request.value else {
                return peripheral.respond(to: first, withResult: .invalidOffset)
            }
            value.append(piece)
            guard value.count <= Nudge.maxPayloadBytes else {
                return peripheral.respond(to: first, withResult: .invalidAttributeValueLength)
            }
        }
        let accepted = onReceive?(value) ?? false
        peripheral.respond(to: first, withResult: accepted ? .success : .unlikelyError)
    }
}

// MARK: - CBCentralManagerDelegate

extension NudgeService: @MainActor CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            powerOnWait?.cancel()
            powerOnWait = nil
            advance()
        case .unsupported, .unauthorized, .poweredOff:
            failQueued()
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard current != nil, currentPeripheral == nil else { return }
        central.stopScan()
        currentPeripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === currentPeripheral, let current else { return }
        peripheral.discoverServices([current.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        guard peripheral === currentPeripheral else { return }
        finishCurrent(delivered: false)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        guard peripheral === currentPeripheral else { return }
        finishCurrent(delivered: false)
    }
}

// MARK: - CBPeripheralDelegate

extension NudgeService: @MainActor CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard peripheral === currentPeripheral, let current,
              let service = peripheral.services?.first(where: { $0.uuid == current.serviceUUID })
        else { return finishCurrent(delivered: false) }
        peripheral.discoverCharacteristics([characteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard peripheral === currentPeripheral, let current,
              let characteristic = service.characteristics?.first(where: { $0.uuid == characteristicUUID }),
              current.data.count <= peripheral.maximumWriteValueLength(for: .withResponse)
        else { return finishCurrent(delivered: false) }
        peripheral.writeValue(current.data, for: characteristic, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard peripheral === currentPeripheral else { return }
        finishCurrent(delivered: error == nil)
    }
}
