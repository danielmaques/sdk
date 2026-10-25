// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PushifySDK",
    platforms: [.iOS(.v15)],
    products: [.library(name: "PushifySDK", targets: ["PushifySDK"])],
    targets: [.target(name: "PushifySDK")]
)
