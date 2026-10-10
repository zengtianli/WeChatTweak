import XCTest
@testable import WeChatTweak

/// 270134 (4.1.15.54) and 270102 (4.1.15.22) are the first 4.x builds with Intel patch points.
/// Pins what config.json claims for x86_64, so "known build" can never again stand in for
/// "patch points exist for this Mac's architecture" (issue #7).
final class ConfigIntelTests: XCTestCase {
    private func config(_ build: String) throws -> Config {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("config.json")
        let configs = try JSONDecoder().decode([Config].self, from: Data(contentsOf: url))
        return try XCTUnwrap(configs.first { $0.version == build })
    }

    private func target(_ config: Config, _ identifier: String) throws -> Config.Target {
        try XCTUnwrap(config.targets.first { $0.identifier == identifier })
    }

    func testIntelHasKeeptipAndUpdateBlockButNoSilentVariant() throws {
        for (build, keeptipVA, expected) in [("270134", UInt64(0x5502d5d), "E8CE47E9FF"), ("270102", UInt64(0x537e8cd), "E83E4BE9FF")] {
            let config = try config(build)
            // Silent is arm64 only: no equal-length x86_64 point has been established.
            XCTAssertFalse(Command.supports(.x86_64, [try target(config, Command.silentRevokeIdentifier)]), build)
            XCTAssertTrue(Command.supports(.arm64, [try target(config, Command.silentRevokeIdentifier)]), build)

            // Keep-tip: the call that produces newmsgid becomes `xor eax, eax` + 3 nops, so the
            // following store writes 0 — what `str xzr` does on arm64.
            let intel = try target(config, Command.keeptipRevokeIdentifier).entries.filter { $0.arch == .x86_64 }
            XCTAssertEqual(intel.count, 1, build)
            XCTAssertEqual(intel[0].addr, keeptipVA, build)
            XCTAssertEqual(intel[0].expected.map(\.hexString), [expected], build)
            XCTAssertEqual(intel[0].asm.hexString, "31C0909090", build)

            let update = try target(config, Command.updateIdentifier).entries
            XCTAssertEqual(update.filter { $0.arch == .arm64 }.count, 8, build)
            let intelUpdate = update.filter { $0.arch == .x86_64 }
            XCTAssertEqual(intelUpdate.count, 8, build)
            // Six entries return at once; the two getters keep their prologue and return 0.
            XCTAssertEqual(intelUpdate.filter { $0.asm.hexString == "C3909090" }.count, 6, build)
            XCTAssertEqual(intelUpdate.filter { $0.asm.hexString == "554889E531C09090" }.count, 2, build)
            for entry in intelUpdate {
                XCTAssertEqual(entry.expected.count, 1, build)
                XCTAssertEqual(entry.expected[0].count, entry.asm.count, build)
            }
        }
    }

    /// Every other 4.x build is still arm64 only, and says so through `supports`.
    func testOlderBuildsRemainAppleSiliconOnly() throws {
        let config = try config("270100")
        XCTAssertFalse(Command.supports(.x86_64, config.targets))
        XCTAssertTrue(Command.supports(.arm64, config.targets))
    }
}
