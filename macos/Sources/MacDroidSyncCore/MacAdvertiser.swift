import CoreBluetooth
import Foundation

/// Advertises this Mac over Bluetooth LE, so the phone, which stops its service
/// while the Mac is out of range, notices it is back and connects again.
public final class MacAdvertiser: NSObject {
    private var peripheral: CBPeripheralManager?
    private var serviceUUID: CBUUID?

    public var isRunning: Bool { peripheral != nil }

    public func start(pairingCode: String) {
        let uuid = CBUUID(nsuuid: PresenceBeacon.macServiceUUID(pairingCode: pairingCode))
        if peripheral != nil, uuid == serviceUUID { return }
        serviceUUID = uuid
        if let peripheral {
            advertise(peripheral)
        } else {
            peripheral = CBPeripheralManager(delegate: self, queue: .main)
        }
    }

    public func stop() {
        peripheral?.stopAdvertising()
        peripheral = nil
        serviceUUID = nil
        Log.info("Not advertising to the phone")
    }

    private func advertise(_ peripheral: CBPeripheralManager) {
        guard let serviceUUID, peripheral.state == .poweredOn else { return }
        peripheral.stopAdvertising()
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceUUID]])
    }
}

extension MacAdvertiser: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            advertise(peripheral)
        } else {
            Log.info("Cannot advertise to the phone, Bluetooth state \(peripheral.state.rawValue)")
        }
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            Log.info("Advertising to the phone failed: \(error.localizedDescription)")
        } else {
            Log.info("Advertising to the phone as \(serviceUUID?.uuidString ?? "?")")
        }
    }
}
