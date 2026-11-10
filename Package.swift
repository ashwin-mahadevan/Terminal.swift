// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "Terminal.swift",
	platforms: [.iOS(.v18), .macOS(.v15), .visionOS(.v2)],
	products: [
		.library(name: "Terminal", targets: ["Terminal"])
	],
	targets: [
		.target(name: "Terminal"),
		.testTarget(
			name: "TerminalTests",
			dependencies: ["Terminal"],
			resources: [.copy("Fixtures")]
		),
	]
)
