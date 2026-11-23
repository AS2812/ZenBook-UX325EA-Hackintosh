// Apply the two Wi-Fi driver flags independently to each installed OpenCore profile.
import Foundation
import Darwin

typealias Plist = [String: Any]
struct Failure: LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
}
let fm = FileManager.default
func plist(_ bytes: Data) throws -> Plist {
    guard let value = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? Plist else {
        throw Failure("Expected a property-list dictionary.")
    }
    return value
}
func xml(_ object: Plist) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
}
func patchProfile(_ data: Data) throws -> Data {
    var config = try plist(data)
    guard var kernel = config["Kernel"] as? Plist, var add = kernel["Add"] as? [Plist] else {
        throw Failure("Kernel/Add is missing.")
    }
    let airport = add.indices.filter { add[$0]["BundlePath"] as? String == "AirportItlwm.kext" }
    let stable = add.indices.filter { add[$0]["BundlePath"] as? String == "itlwm.kext" }
    guard airport.count <= 1, stable.count <= 1 else { throw Failure("Duplicate Intel Wi-Fi driver entries.") }
    if let from = airport.first { add[from]["Enabled"] = false }
    if stable.isEmpty {
        let entry: Plist = ["BundlePath": "itlwm.kext", "Enabled": true, "Comment": "Intel Wi-Fi with HeliPort",
                            "Arch": "Any", "MinKernel": "", "MaxKernel": "",
                            "ExecutablePath": "Contents/MacOS/itlwm", "PlistPath": "Contents/Info.plist"]
        add.insert(entry, at: airport.first.map { $0 + 1 } ?? add.endIndex)
    }
    let to = add.firstIndex { $0["BundlePath"] as? String == "itlwm.kext" }!
    add[to]["Enabled"] = true
    add[to]["ExecutablePath"] = "Contents/MacOS/itlwm"
    add[to]["PlistPath"] = "Contents/Info.plist"
    add[to]["Arch"] = "Any"
    add[to]["MinKernel"] = ""
    add[to]["MaxKernel"] = ""
    kernel["Add"] = add
    config["Kernel"] = kernel
    // Ensure critical boot-args for Tiger Lake Wi-Fi and sleep stability:
    // darkwake=0 (no background wake desync), -noht40 (clean 20 MHz 2.4 GHz channel), itlwm_cc=EG
    let apple = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
    if var nvram = config["NVRAM"] as? Plist, var entries = nvram["Add"] as? Plist,
       var vars = entries[apple] as? Plist, let args = vars["boot-args"] as? String {
        var words = args.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if !words.contains("darkwake=0") { words.append("darkwake=0") }
        if !words.contains("-noht40") { words.append("-noht40") }
        words = words.map { $0 == "itlwm_cc=US" ? "itlwm_cc=EG" : $0 }
        if !words.contains(where: { $0.hasPrefix("itlwm_cc=") }) { words.append("itlwm_cc=EG") }
        vars["boot-args"] = words.joined(separator: " ")
        entries[apple] = vars
        nvram["Add"] = entries
        config["NVRAM"] = nvram
    }
    // Disable PCIe ASPM on Intel AX201 CNVi to prevent power-state freezes
    let pciRoute = "PciRoot(0x0)/Pci(0x14,0x3)"
    var devProps = (config["DeviceProperties"] as? Plist) ?? Plist()
    var devAdd = (devProps["Add"] as? Plist) ?? Plist()
    var wifiProps = (devAdd[pciRoute] as? Plist) ?? Plist()
    wifiProps["pci-aspm-default"] = Data([0x00])
    devAdd[pciRoute] = wifiProps
    devProps["Add"] = devAdd
    config["DeviceProperties"] = devProps
    if NSDictionary(dictionary: config).isEqual(to: try plist(data)) { return data }
    return try xml(config)
}
func driverInfo(_ release: Data, _ existing: Data?) throws -> Data {
    var info = try plist(release)
    guard var personalities = info["IOKitPersonalities"] as? Plist,
          var driver = personalities["itlwm"] as? Plist, let examples = driver["WiFiConfig"] as? [String:Plist] else {
        throw Failure("Invalid release driver personality.")
    }
    var networks: [String:Plist] = [:]
    if let old = existing {
        let oldInfo = try plist(old)
        guard oldInfo["CFBundleIdentifier"] as? String == info["CFBundleIdentifier"] as? String,
              let personalities = oldInfo["IOKitPersonalities"] as? Plist, let driver = personalities["itlwm"] as? Plist else {
            throw Failure("The installed itlwm bundle has an unexpected identity.")
        }
        if let raw = driver["WiFiConfig"] {
            guard let saved = raw as? [String:Plist] else { throw Failure("Unrecognized saved network data.") }
            networks = saved.filter { key, value in
                guard let sample = examples[key] else { return true }
                return !NSDictionary(dictionary: value).isEqual(to: sample)
            }
        }
    }
    driver["WiFiConfig"] = networks
    personalities["itlwm"] = driver
    info["IOKitPersonalities"] = personalities
    if let old = existing, NSDictionary(dictionary: info).isEqual(to: try plist(old)) { return old }
    return try xml(info)
}

struct Change {
    let path: String
    let before: Data?
    let after: Data
}
func configure(_ args: [String]) throws {
    guard args.count == 6, ["check","apply"].contains(args[1]) else {
        throw Failure("Expected check/apply, OpenCore directory, release kext, validator and backup directory.")
    }
    let oc = URL(fileURLWithPath: args[2]), release = URL(fileURLWithPath: args[3])
    let backupRoot = URL(fileURLWithPath: args[5])
    let files = try fm.contentsOfDirectory(atPath: oc.path).filter { $0.hasPrefix("config") && $0.hasSuffix(".plist") }
    guard files.contains("config.plist"), fm.fileExists(atPath: oc.appendingPathComponent("OpenCore.efi").path),
          fm.fileExists(atPath: oc.appendingPathComponent("ACPI/SSDT-KBL.aml").path) else { throw Failure("ZenBook OpenCore was not found.") }
    let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: temp) }
    var changes = [Change]()
    for path in ["Contents/MacOS/itlwm", "Contents/Info.plist"] {
        let target = "Kexts/itlwm.kext/" + path
        let url = oc.appendingPathComponent(target)
        let previous = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        var new = try Data(contentsOf: release.appendingPathComponent(path))
        if path.hasSuffix(".plist") { new = try driverInfo(new, previous) }
        if previous != new { changes.append(Change(path: target, before: previous, after: new)) }
    }
    // Enable the active config last, after the complete driver is in place.
    for name in files.sorted().filter({ $0 != "config.plist" }) + ["config.plist"] {
        let old = try Data(contentsOf: oc.appendingPathComponent(name))
        let new = try patchProfile(old)
        let stage = temp.appendingPathComponent(name)
        try new.write(to: stage)
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: args[4])
        verify.arguments = [stage.path]
        try verify.run()
        verify.waitUntilExit()
        guard verify.terminationStatus == 0 else { throw Failure("OpenCore validation failed for " + name) }
        if new != old { changes.append(Change(path: name, before: old, after: new)) }
    }
    if args[1] == "check" || changes.isEmpty {
        print("Validated \(files.count) profiles. Files requiring an update: \(changes.count).")
        return
    }
    let backup = backupRoot.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    for change in changes {
        if let old = change.before {
            let copy = backup.appendingPathComponent(change.path)
            try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try old.write(to: copy, options: .atomic)
        }
    }
    let absent = changes.filter { $0.before == nil }.map { $0.path }
    try xml(["OriginallyAbsent": absent]).write(to: backup.appendingPathComponent("manifest.plist"), options: .atomic)
    var written = [Change]()
    do {
        for change in changes {
            let url = oc.appendingPathComponent(change.path)
            let current = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            guard current == change.before else { throw Failure("Contents changed during installation: " + change.path) }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try change.after.write(to: url, options: .atomic)
            written.append(change)
            guard try Data(contentsOf: url) == change.after else { throw Failure("Verification failed for " + change.path) }
        }
    } catch {
        let cause = error
        for change in written.reversed() {
            let url = oc.appendingPathComponent(change.path)
            if let old = change.before { try old.write(to: url, options: .atomic) }
            else { try fm.removeItem(at: url) }
        }
        throw cause
    }
    sync()
    print("Updated and read back \(files.count) OpenCore profiles. Backup: \(backup.path)")
}

do { try configure(CommandLine.arguments) }
catch { fputs("Wi-Fi setup: \(error.localizedDescription)\n", stderr); exit(1) }
