// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "pushify_purchases",
    platforms: [.iOS("15.0")],
    products: [
        .library(name: "pushify-purchases", targets: ["pushify_purchases"]),
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ],
    targets: [
        .target(
            name: "pushify_purchases",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ]
        ),
    ]
)
