// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PushifySDK",
    platforms: [.iOS(.v15), .macOS(.v10_15)],
    products: [.library(name: "PushifySDK", targets: ["PushifySDK"])],
    dependencies: [.package(url: "https://github.com/airbnb/lottie-spm.git", from: "4.6.1")],
    targets: [.target(name: "PushifySDK", dependencies: [.product(name: "Lottie", package: "lottie-spm")])]
)
