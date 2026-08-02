import ProjectDescription

let project = Project(
    name: "Bleank",
    targets: [
        .target(
            name: "ClaudeLED",
            destinations: [.mac],
            product: .commandLineTool,
            productName: "claude-led",
            bundleId: "com.bleank.claude-led",
            deploymentTargets: .macOS("12.0"), // kIOMainPortDefault
            sources: ["Sources/ClaudeLED/**"]
        )
    ]
)
