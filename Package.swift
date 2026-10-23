// swift-tools-version:5.9
import PackageDescription

var products: [Product] = [
    .library(name: "CalendarSyncCore", targets: ["CalendarSyncCore"]),
]

var targets: [Target] = [
    // Pure Foundation: sync rules, formatting, parsing. Builds and tests on Linux too.
    .target(name: "CalendarSyncCore"),
    .testTarget(name: "CalendarSyncCoreTests", dependencies: ["CalendarSyncCore"]),
]

#if os(macOS)
// The menu bar app itself (EventKit, SwiftUI, WebKit). macOS only.
products.append(.executable(name: "CalendarSync", targets: ["CalendarSync"]))
targets.append(.executableTarget(name: "CalendarSync", dependencies: ["CalendarSyncCore"]))
#endif

let package = Package(
    name: "CalendarSync",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
