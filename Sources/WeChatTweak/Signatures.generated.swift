// GENERATED FILE — do not edit. Source of truth: signatures.json (repo root).
// Regenerate: python3 tools/gen_signatures.py   (SignaturesSyncTests fails if stale)

extension RevokeLocator {
    static let offCbz: UInt64 = 0x270
    static let signatures: [Signature] = [
        Signature(name: "4.1.13 (269574+)", builds: "269574-269626", cbzHex: "40100034", branchHex: "82000014", delta: 0x7a0, strX0Hex: "60E600F9", strXzrHex: "7FE600F9", field: 0x1c8),
        Signature(name: "4.1.12 (269332-269341)", builds: "269332-269341", cbzHex: "40100034", branchHex: "82000014", delta: 0x7a0, strX0Hex: "60CE00F9", strXzrHex: "7FCE00F9", field: 0x198),
        Signature(name: "4.1.10-4.1.11 (<=269136)", builds: "268575-269136", cbzHex: "E00F0034", branchHex: "7F000014", delta: 0x794, strX0Hex: "60B600F9", strXzrHex: "7FB600F9", field: 0x168),
    ]
}

extension UpdateLocator {
    static let className = "XAppUpdateManager"
    static let retMethods: [String] = ["startUpdater", "checkForUpdates:", "startBackgroundUpdatesCheck:", "enableAutoUpdate:"]
    static let zeroAccessors: [(getter: String, setter: String)] = [
        (getter: "automaticallyDownloadsUpdates", setter: "setAutomaticallyDownloadsUpdates:"),
        (getter: "canCheckForUpdate", setter: "setCanCheckForUpdate:"),
    ]
    static let retHex = "C0035FD6"
    static let movW0ZeroHex = "00008052"
}
