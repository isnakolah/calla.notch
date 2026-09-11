// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BoringCallaEngineValidation",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "CallaContracts"), .package(path: "Intelligence")],
    targets: [
        .target(
            name: "CallaEngineValidation",
            dependencies: [.product(name: "CallaContracts", package: "CallaContracts"),
                           .product(name: "IntelligenceCore", package: "Intelligence"),
                           .product(name: "IntelligenceProviders", package: "Intelligence")],
            path: "BoringCallaEngine",
            exclude: ["BoringCallaEngine.swift", "BoringCallaEngineProtocol.swift", "BoringCallaEngine.entitlements", "Info.plist", "main.swift", "TutorHistoryKey.swift", "TutorEngineIngress.swift", "QuizEngineController.swift", "QuizHistoryKey.swift"],
            sources: ["CallaCourseCommandValidation.swift", "CallaCoursePresentation.swift", "CallaCopilotCommandValidation.swift", "CallaAgyLoginParsing.swift", "TutorEngineGate.swift", "TutorAgyAttachmentStager.swift", "QuizReadinessCache.swift", "CodingSessionCore.swift", "CodingSessionController.swift", "CodingAgyWorker.swift", "WaveWorkerPool.swift", "CodingSessionVault.swift", "CodeHistoryKey.swift", "QuizHostRunner.swift"]
        ),
        .target(
            name: "CallaNotchPresentation",
            dependencies: [.product(name: "CallaContracts", package: "CallaContracts")],
            path: "boringNotch/components/Calla",
            exclude: [
                "CallaCalendarBindings.swift", "CallaCopilotLiveView.swift", "CallaCopilotSignInView.swift",
                "CallaCopilotEndingView.swift", "CallaCopilotStartFailure.swift", "CallaCopilotStartingView.swift",
                "CallaQuizLiveView.swift", "CallaQuizPreflightView.swift",
                "CallaCodingSetup.swift", "CallaModeChrome.swift", "CallaCodingPatchView.swift",
                "CallaWindowTargetMenu.swift", "CallaQuizCodeBlock.swift", "CallaQuizEndedView.swift",
                "CallaQuizLiveHeader.swift",
                "CallaCopilotTabView.swift", "CallaEngineClient.swift", "CallaKnowledge.swift",
                "CallaKnowledgeAttach.swift", "CallaKnowledgeDropView.swift", "CallaKnowledgeFocus.swift",
                "CallaKnowledgeLibrary.swift", "CallaTabView.swift", "CopilotLiveSession.swift",
                "CopilotNotchBadge.swift", "KnowledgeDocumentReader.swift", "NotchDropChooserView.swift",
                "NotchDropRouter.swift"
            ],
            sources: ["CallaNotchPresentation.swift", "CallaCopilotPresentation.swift",
                      "CallaQuizPresentation.swift", "CallaCodingPresentation.swift",
                      "WaveInterview.swift"]
        ),
        .target(
            name: "NotchSizing",
            path: "boringNotch/sizing",
            exclude: ["matters.swift", "NotchResizeSession.swift"],
            sources: ["NotchSizing.swift", "NotchBehaviour.swift"]
        ),
        // The live-session shortcut routing table, without KeyboardShortcuts or
        // AppKit: which action a key means on which surface is a decision worth
        // testing on its own.
        .target(
            name: "NotchShortcuts",
            path: "boringNotch/Shortcuts",
            exclude: ["ShortcutConstants.swift", "NotchSessionShortcuts.swift"],
            sources: ["NotchSessionRouting.swift"]
        ),
        .target(
            name: "IceConfiguration",
            path: "boringNotch/Ice",
            exclude: ["IceMenuBarController.swift", "NOTICE.md"],
            sources: ["IceConfiguration.swift"]
        ),
        .testTarget(
            name: "CallaEngineValidationTests",
            dependencies: ["CallaEngineValidation", "CallaNotchPresentation", "NotchSizing", "NotchShortcuts"],
            path: "BoringCallaEngineTests/Tests"
        ),
        .testTarget(
            name: "IceConfigurationTests",
            dependencies: ["IceConfiguration"],
            path: "BoringCallaEngineTests/IceTests"
        )
    ]
)
