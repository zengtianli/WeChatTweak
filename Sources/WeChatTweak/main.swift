//
//  main.swift
//
//  Created by Sunny Young.
//

import Foundation
import Dispatch
import ArgumentParser

/// Which anti-revoke behaviour to apply.
/// - silent: neutralise the revoke XML parser entirely — message stays, no tip. (default, WeChat 4.x current release behaviour)
/// - keeptip: let the parser run (tip renders) but zero out `newmsgid` so the downstream
///            delete-by-id finds nothing — message stays AND the recall tip still shows.
enum PatchVariant: String, ExpressibleByArgument {
    case silent
    case keeptip
}

// MARK: Versions
extension Tweak {
    struct Versions: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all supported WeChat versions")

        @OptionGroup
        var options: Tweak.Options

        mutating func run() async throws {
            print("------ Current version ------")
            print(try await Command.version(app: options.app) ?? "unknown")
            print("------ Supported versions ------")
            try await Config.load(url: options.config).forEach({ print($0.version) })
            Darwin.exit(EXIT_SUCCESS)
        }
    }
}

// MARK: Patch
extension Tweak {
    struct Patch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Patch WeChat.app")

        @OptionGroup
        var options: Tweak.Options

        @Option(
            name: .shortAndLong,
            help: "Anti-revoke variant: silent (keep message, no tip) | keeptip (keep message + still show the recall tip). keeptip needs a revoke-keeptip target in config.json, or --auto-locate to derive it."
        )
        var variant: PatchVariant = .silent

        @Flag(
            help: "If this build has no curated revoke-keeptip target, locate the patch point by scanning the binary for the revoke code signature instead of failing. The derived address still goes through the expected-byte check before any write."
        )
        var autoLocate: Bool = false

        mutating func run() async throws {
            print("------ Version ------")
            let version = try await Command.version(app: options.app)
            print("WeChat version: \(version ?? "unknown")")

            print("------ Config ------")
            guard let config = (try await Config.load(url: options.config)).first(where: { $0.version == version }) else {
                throw Error.unsupportedVersion
            }
            print("Matched config: \(config)")

            print("------ Patch ------")
            print("Variant: \(variant.rawValue)")
            let patched = try Command.patch(
                app: options.app,
                config: config,
                variant: variant,
                autoLocate: autoLocate
            )
            print("Done!")

            print("------ Resign ------")
            try await Command.resign(
                app: options.app,
                patchedBinaries: patched
            )
            print("Done!")

            Darwin.exit(EXIT_SUCCESS)
        }
    }

}

// MARK: Tweak
struct Tweak: AsyncParsableCommand {
    enum Error: LocalizedError {
        case invalidApp
        case invalidConfig
        case invalidVersion
        case unsupportedVersion

        var errorDescription: String? {
            switch self {
            case .invalidApp:
                return "Invalid app path"
            case .invalidConfig:
                return "Invalid patch config"
            case .invalidVersion:
                return "Invalid app version"
            case .unsupportedVersion:
                return "Unsupported WeChat version"
            }
        }
    }

    struct Options: ParsableArguments {
        @Option(
            name: .shortAndLong,
            help: "Path of WeChat.app",
            transform: {
                guard FileManager.default.fileExists(atPath: $0) else {
                    throw Error.invalidApp
                }
                return URL(fileURLWithPath: $0)
            }
        )
        var app: URL = URL(fileURLWithPath: "/Applications/WeChat.app", isDirectory: true)

        @Option(
            name: .shortAndLong,
            help: "Local path or Remote URL of config.json",
            transform: {
                if FileManager.default.fileExists(atPath: $0) {
                    return URL(fileURLWithPath: $0)
                } else {
                    guard let url = URL(string: $0) else {
                        throw Error.invalidConfig
                    }
                    return url
                }
            }
        )
        var config: URL = Options.resolveDefaultConfig()

        /// Resolve the config.json to use by default.
        ///
        /// Prefer a **local** config.json so that a build you just added via
        /// `tools/locate_revoke.py --append` is picked up without having to pass `-c`.
        /// Search order: current directory, then walk up from the executable's directory
        /// (covers `.build/release/wechattweak` → repo root). Only when no local file is
        /// found do we fall back to the fork's remote master config.json (e.g. running a
        /// bare prebuilt binary outside any checkout).
        private static func resolveDefaultConfig() -> URL {
            let fm = FileManager.default
            var dirs: [URL] = [URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)]

            let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            var dir = exe.deletingLastPathComponent()
            for _ in 0..<8 {
                dirs.append(dir)
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }

            for directory in dirs {
                let candidate = directory.appendingPathComponent("config.json")
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            return URL(string: "https://raw.githubusercontent.com/zengtianli/WeChatTweak/refs/heads/master/config.json")!
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "wechattweak",
        abstract: "A command-line tool for tweaking WeChat.",
        subcommands: [
            Versions.self,
            Patch.self
        ]
    )

    mutating func run() async throws {
        print(Tweak.helpMessage())
        Darwin.exit(EXIT_SUCCESS)
    }
}

Task {
    await Tweak.main()
}

Dispatch.dispatchMain()
