// swift-tools-version: 5.9.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

// ---------------------------------------------------------------------------
// Linux: resolve the pre-built static library from the XCFramework directory.
// SwiftPM on Linux does not support .binaryTarget / XCFrameworks, so we use a
// regular .target that provides the C headers + module map and link the
// pre-built .a via linker settings.
// ---------------------------------------------------------------------------
#if os(Linux)
    let packageDir = URL(fileURLWithPath: #file).deletingLastPathComponent().path

    #if arch(x86_64)
        let linuxArchDir = "linux-x86_64"
    #elseif arch(arm64)
        let linuxArchDir = "linux-aarch64"
    #else
        #error("Unsupported Linux architecture – only x86_64 and arm64 are supported.")
    #endif

    let linuxLibSearchPath = "\(packageDir)/Sources/CLibsql/CLibsql.xcframework/\(linuxArchDir)"

    let cLibsqlTarget: Target = .target(
        name: "CLibsql",
        path: "Sources/CLibsqlLinux",
        publicHeadersPath: "include",
        linkerSettings: [
            .unsafeFlags([
                "-L\(linuxLibSearchPath)",
                "-llibsql",
            ]),
        ]
    )
#else
    let cLibsqlTarget: Target = .binaryTarget(
        name: "CLibsql",
        path: "Sources/CLibsql/CLibsql.xcframework"
    )
#endif

var package = Package(
    name: "Libsql",
    platforms: [.iOS(.v12), .macOS(.v10_13)],
    products: [
        .library(name: "Libsql", targets: ["Libsql"]),

        // Examples
        .executable(name: "Query", targets: ["Query"]),
        .executable(name: "Transaction", targets: ["Transaction"]),
        .executable(name: "Batch", targets: ["Batch"]),
    ],
    targets: [
        .target(name: "Libsql", dependencies: ["CLibsql"]),
        cLibsqlTarget,
        .testTarget(name: "LibsqlTests", dependencies: ["Libsql"]),

        // Examples
        .executableTarget(
            name: "Query",
            dependencies: ["Libsql"],
            path: "Examples/Query"
        ),
        .executableTarget(
            name: "Transaction",
            dependencies: ["Libsql"],
            path: "Examples/Transaction"
        ),
        .executableTarget(
            name: "Batch",
            dependencies: ["Libsql"],
            path: "Examples/Batch",
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "Local",
            dependencies: ["Libsql"],
            path: "Examples/Local",
            exclude: ["README.md", "local.db"]
        ),
        .executableTarget(
            name: "Memory",
            dependencies: ["Libsql"],
            path: "Examples/Memory",
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "Remote",
            dependencies: ["Libsql"],
            path: "Examples/Remote",
            exclude: ["README.md", "local.db", "local.db-shm", "local.db-client_wal_index", "local.db-wal"]
        ),
        .executableTarget(
            name: "Sync",
            dependencies: ["Libsql"],
            path: "Examples/Sync",
            exclude: ["README.md", "local.db", "local.db-shm", "local.db-client_wal_index", "local.db-wal"]
        ),
        .executableTarget(
            name: "Transactions",
            dependencies: ["Libsql"],
            path: "Examples/Transactions",
            exclude: ["README.md", "local.db"]
        ),
        .executableTarget(
            name: "Vector",
            dependencies: ["Libsql"],
            path: "Examples/Vector",
            exclude: ["README.md"]
        ),
    ]
)
