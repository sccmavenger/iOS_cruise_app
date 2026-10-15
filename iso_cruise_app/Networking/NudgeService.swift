import CoreBluetooth
import Foundation
import os

/// CoreBluetooth side of `Nudge`.
///
/// - Peripheral role (always on, including in the background via the `bluetooth-peripheral`
///   background mode): advertises this phone's doorbell service and hands each valid write
///   to `onNudge`. iOS wakes a suspended app to handle the write.
/// - Central role (foreground only): to ring someone, scans for their service UUID,
///   connects, writes one small payload, and disconnects. One nudge at a time.
///
/// Bluetooth isn't available in Simulator; every path degrades to doing nothing.
final class NudgeService: NSObject {
    private static let logger = Logger(subsystem: "com.dannyguillory.cruiselan", category: "nudge")
    /// Give up on a nudge that hasn't been delivered after this long (the person is out of range).
    private static let deliveryTimeout: Duration = .seconds(20)
    private static let staleAfter: TimeInterval = 60

    /// Called for every well-formed nudge. The app decides whether it deserves a notification.
    var onNudge: ((Nudge.Payload) -> Void)?

    private let characteristicUUID = CBUUID(string: Nudge.characteristicUUIDString)
    private var localId: String?
    private var peripheralManager: CBPeripheralManager?
    private var centralManager: CBCentralManager?
    private var sendLimiter = Nudge.RateLimiter(interval: Nudge.sendInterval)

    private struct Outgoing {
        let serviceUUID: CBUUID
        let data: Data
        let created: Date
    }

    private var queue: [Outgoing] = []
    private var current: Outgoing?
    private var currentPeripheral: CBPeripheral?
    private var timeout: Task<Void, Never>?

    /// Starts advertising this phone's doorbell. Call again if the CruiseLAN id changes.
    func start(localId: String) {
        guard self.localId != localId else { return }
        self.localId = localId
        if let peripheralManager {
            publish(on: peripheralManager)
        } else {
            // Creating the manager triggers the Bluetooth permission prompt the first time.
            peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        }
    }

    /// Rings `targetId`'s phone if they're in Bluetooth range. Repeats are rate-limited.
    func nudge(_ targetId: String, kind: Nudge.Kind) {
        guard let localId,
              sendLimiter.allow(targetId, kind, at: .now),
              let data = Nudge.encode(Nudge.Payload(v: Nudge.version, from: localId, kind: kind))
        else { return }
        queue.append(Outgoing(serviceUUID: CBUUID(string: Nudge.serviceUUIDString(for: targetId)), data: data, created: .now))
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
        }
        advance()
    }

    // MARK: - Peripheral

    private func publish(on manager: CBPeripheralManager) {
        guard manager.state == .poweredOn, let localId else { return }
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
        queue.removeAll { Date.now.timeIntervalSince($0.created) > Self.staleAfter }
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
        guard current != nil else { return }
        if !delivered { Self.logger.info("Nudge not delivered") }
        timeout?.cancel()
        timeout = nil
        centralManager?.stopScan()
        if let currentPeripheral {
            centralManager?.cancelPeripheralConnection(currentPeripheral)
        }
        currentPeripheral = nil
        current = nil
        advance()
    }
}

// MARK: - CBPeripheralManagerDelegate

extension NudgeService: @MainActor CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn { publish(on: peripheral) }
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

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        for request in requests where request.characteristic.uuid == characteristicUUID {
            if let value = request.value, let payload = Nudge.decode(value) {
                onNudge?(payload)
            }
        }
        peripheral.respond(to: first, withResult: .success)
    }
}

// MARK: - CBCentralManagerDelegate

extension NudgeService: @MainActor CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            advance()
        case .unsupported, .unauthorized, .poweredOff:
            queue.removeAll()
            finishCurrent(delivered: false)
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
              let characteristic = service.characteristics?.first(where: { $0.uuid == characteristicUUID })
        else { return finishCurrent(delivered: false) }
        peripheral.writeValue(current.data, for: characteristic, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard peripheral === currentPeripheral else { return }
        finishCurrent(delivered: error == nil)
    }
}
