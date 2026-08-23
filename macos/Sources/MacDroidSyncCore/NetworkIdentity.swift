import CoreWLAN
import Foundation
import SystemConfiguration

/// Which Wi-Fi network this Mac is on.
///
/// Not the name of it: since macOS 14 the SSID of the joined network is private
/// data, and an app only gets it after being granted Location Services. Every
/// route is closed without that grant - `CWInterface.ssid()` returns nil,
/// `networksetup` denies the association, and `ipconfig`, `scutil` and
/// `system_profiler` all answer `<redacted>`.
///
/// What is still readable is `ProfileID`: the system's own identifier of the
/// network profile currently joined. It is stable, it needs no permission, and it
/// is all this feature needs - the readable name comes from the user, who types
/// it once when adding the network. So the auto lock can stand down on a trusted
/// network without the app ever asking where you are.
public enum CurrentNetwork {

    /// Identity of the joined Wi-Fi network, or nil when there is none.
    ///
    /// Nil covers Wi-Fi switched off, no Wi-Fi hardware, and a Mac on Ethernet
    /// only. All three mean "not a network I was told to trust", which is the
    /// side of the decision that keeps locking rather than the side that stops.
    public static func profileID() -> String? {
        guard let name = interfaceName(),
              let store = SCDynamicStoreCreate(nil, Log.subsystem as CFString, nil, nil),
              let entry = SCDynamicStoreCopyValue(
                  store, "State:/Network/Interface/\(name)/AirPort" as CFString
              ) as? [String: Any],
              let profile = entry["ProfileID"] as? String,
              !profile.isEmpty
        else { return nil }
        return profile
    }

    /// The Wi-Fi interface name, which CoreWLAN does hand over unprivileged.
    private static func interfaceName() -> String? {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else { return nil }
        return interface.interfaceName
    }
}

public extension CurrentNetwork {

    /// The identity in a form a person can compare at a glance. Both ends of it
    /// are kept: two networks differing only in the middle would otherwise look
    /// identical on the list.
    static func shortForm(_ profileID: String) -> String {
        guard profileID.count > 20 else { return profileID }
        return "\(profileID.prefix(10))…\(profileID.suffix(8))"
    }
}
