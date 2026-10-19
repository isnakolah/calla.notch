// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CallaEngineValidation",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "CallaContracts"), .package(path: "Intelligence")],
    targets: [
        .target(
            name: "CallaEngineValidation",
            dependencies: [.product(name: "CallaContracts", package: "CallaContracts"),
                           .product(name: "IntelligenceCore", package: "Intelligence"),
                           .product(name: "IntelligenceProviders", package: "Intelligence")],
            path: "CallaEngine",
            exclude: ["CallaEngine.swift", "CallaEngineProtocol.swift", "CallaEngine.entitlements", "Info.plist", "main.swift", "QuizEngineController.swift", "QuizHistoryKey.swift"],
            sources: ["CallaCopilotCommandValidation.swift", "CallaAgyLoginParsing.swift", "CallFolderExport.swift", "QuizReadinessCache.swift", "CodingSessionCore.swift", "CodingSessionController.swift", "CodingAgyWorker.swift", "WaveWorkerPool.swift", "CodingSessionVault.swift", "CodeHistoryKey.swift", "QuizHostRunner.swift"]
        ),
        .target(
            name: "CallaNotchPresentation",
            dependencies: [.product(name: "CallaContracts", package: "CallaContracts")],
            path: "callaNotch/components/Calla",
            exclude: [
                "CallaCopilotLiveView.swift", "CallaCopilotSignInView.swift",
                "CallaCopilotEndingView.swift", "CallaCopilotStartFailure.swift", "CallaCopilotStartingView.swift",
                "CallaQuizLiveView.swift", "CallaQuizPreflightView.swift",
                "CallaModeChrome.swift",
                "CallaWindowTargetMenu.swift", "CallaQuizCodeBlock.swift", "CallaQuizEndedView.swift",
                "CallaQuizLiveHeader.swift",
                "CallaCopilotTabView.swift", "CallaEngineClient.swift", "CallaKnowledge.swift",
                "CallaKnowledgeAttach.swift", "CallaKnowledgeDropView.swift", "CallaKnowledgeFocus.swift",
                "CallaKnowledgeLibrary.swift", "CopilotLiveSession.swift",
                "CopilotNotchBadge.swift", "KnowledgeDocumentReader.swift", "NotchDropChooserView.swift",
                "NotchDropRouter.swift"
            ],
            sources: ["CallaCopilotPresentation.swift",
                      "CallaQuizPresentation.swift", "CallaMode.swift"]
        ),
        .target(
            name: "NotchSizing",
            path: "callaNotch/sizing",
            exclude: ["matters.swift", "NotchResizeSession.swift"],
            sources: ["NotchSizing.swift", "NotchBehaviour.swift"]
        ),
        // The live-session shortcut routing table, without KeyboardShortcuts or
        // AppKit: which action a key means on which surface is a decision worth
        // testing on its own.
        .target(
            name: "NotchShortcuts",
            path: "callaNotch/Shortcuts",
            exclude: ["ShortcutConstants.swift", "NotchSessionShortcuts.swift"],
            sources: ["NotchSessionRouting.swift"]
        ),
        .testTarget(
            name: "CallaEngineValidationTests",
            dependencies: ["CallaEngineValidation", "CallaNotchPresentation", "NotchSizing", "NotchShortcuts"],
            path: "CallaEngineTests/Tests"
        )
    ]
)
