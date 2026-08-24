import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Collects device/app metadata — mirrors `atelerix_native.dart`/`atelerix_package.dart`,
/// using `UIDevice`/`Bundle`/`Locale`/`ProcessInfo` instead of platform channels
/// and `package_info_plus` (this runs natively, no bridge needed).
enum LerixDeviceInfo {
    static func collectDevice() -> LerixDevice {
        #if canImport(UIKit)
        let device = UIDevice.current
        return LerixDevice(
            deviceName: device.name,
            arc: architecture(),
            osName: device.systemName,
            osVersion: device.systemVersion,
            timeZone: TimeZone.current.identifier,
            countryCode: Locale.current.regionCode ?? "unknown"
        )
        #else
        return LerixDevice(
            deviceName: "unknown",
            arc: architecture(),
            osName: "iOS",
            osVersion: "unknown",
            timeZone: TimeZone.current.identifier,
            countryCode: Locale.current.regionCode ?? "unknown"
        )
        #endif
    }

    static func collectApp() -> LerixApp {
        let bundle = Bundle.main
        let info = bundle.infoDictionary
        let appName = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? "unknown"
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        let build = (info?["CFBundleVersion"] as? String) ?? "0"
        return LerixApp(
            name: appName.isEmpty ? "unknown" : appName,
            package: bundle.bundleIdentifier ?? "unknown",
            version: version.isEmpty ? "0.0.0" : version,
            buildNo: build.isEmpty ? "0" : build
        )
    }

    static func vendorIdentifier() -> String {
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        #else
        return "unknown"
        #endif
    }

    static func memorySize() -> UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    static func freeMemory() -> UInt64 {
        var pagesize: vm_size_t = 0
        host_page_size(mach_host_self(), &pagesize)

        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vmStats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(vmStats.free_count) * UInt64(pagesize)
    }

    static func architecture() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { partial, element in
            guard let value = element.value as? Int8, value != 0 else { return partial }
            return partial + String(UnicodeScalar(UInt8(value)))
        }
        return identifier.isEmpty ? "unknown" : identifier
    }
}
