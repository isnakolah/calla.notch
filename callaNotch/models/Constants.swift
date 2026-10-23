//
//  Constants.swift
//  callaNotch
//
//  Created by Richard Kunkli on 2024. 10. 17..
//

import SwiftUI
import Defaults
import CallaContracts

private let availableDirectories = FileManager
    .default
    .urls(for: .documentDirectory, in: .userDomainMask)
let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
let bundleIdentifier = Bundle.main.bundleIdentifier!
let appVersion = "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))"

let temporaryDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
let spacing: CGFloat = 16

struct CustomVisualizer: Codable, Hashable, Equatable, Defaults.Serializable {
    let UUID: UUID
    var name: String
    var url: URL
    var speed: CGFloat = 1.0
}

enum CalendarSelectionState: Codable, Defaults.Serializable {
    case all
    case selected(Set<String>)
}

enum HideNotchOption: String, Defaults.Serializable {
    case always
    case nowPlayingOnly
    case never
}

// Define notification names at file scope
extension Notification.Name {
    static let mediaControllerChanged = Notification.Name("mediaControllerChanged")
}

// Media controller types for selection in settings
enum MediaControllerType: String, CaseIterable, Identifiable, Defaults.Serializable {
    case nowPlaying = "Now Playing"
    case appleMusic = "Apple Music"
    case spotify = "Spotify"
    case youtubeMusic = "YouTube Music"
    
    var id: String { self.rawValue }
}

// Sneak peek styles for selection in settings
enum SneakPeekStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case standard = "Default"
    case inline = "Inline"
    
    var id: String { self.rawValue }
}

// Action to perform when Option (⌥) is held while pressing media keys
enum OptionKeyAction: String, CaseIterable, Identifiable, Defaults.Serializable {
    case openSettings = "Open System Settings"
    case showHUD = "Show HUD"
    case none = "No Action"

    var id: String { self.rawValue }
}

extension Defaults.Keys {
    // MARK: General
    static let menubarIcon = Key<Bool>("menubarIcon", default: true)
    static let showOnAllDisplays = Key<Bool>("showOnAllDisplays", default: false)
    static let automaticallySwitchDisplay = Key<Bool>("automaticallySwitchDisplay", default: true)
    static let releaseName = Key<String>("releaseName", default: "Flying Rabbit 🐇🪽")
    
    // MARK: Behavior
    static let minimumHoverDuration = Key<TimeInterval>("minimumHoverDuration", default: 0.3)
    static let enableHaptics = Key<Bool>("enableHaptics", default: true)
    static let openNotchOnHover = Key<Bool>("openNotchOnHover", default: true)
    static let extendHoverArea = Key<Bool>("extendHoverArea", default: false)
    static let notchHeightMode = Key<WindowHeightMode>(
        "notchHeightMode",
        default: WindowHeightMode.matchRealNotchSize
    )
    static let nonNotchHeightMode = Key<WindowHeightMode>(
        "nonNotchHeightMode",
        default: WindowHeightMode.matchMenuBar
    )
    static let nonNotchHeight = Key<CGFloat>("nonNotchHeight", default: 32)
    static let notchHeight = Key<CGFloat>("notchHeight", default: 32)
    //static let openLastTabByDefault = Key<Bool>("openLastTabByDefault", default: false)
    static let showOnLockScreen = Key<Bool>("showOnLockScreen", default: false)
    static let hideFromScreenRecording = Key<Bool>("hideFromScreenRecording", default: false)
    
    // MARK: Appearance
    static let showEmojis = Key<Bool>("showEmojis", default: false)
    //static let alwaysShowTabs = Key<Bool>("alwaysShowTabs", default: true)
    // Header placement now lives in `notchHeaderLeading` / `notchHeaderTrailing`
    // (see NotchHeaderItem.swift). `settingsIconInNotch` and
    // `showBatteryIndicator` were per-item presence flags for the same header
    // and are retired: the gear is a placeable item.
    static let lightingEffect = Key<Bool>("lightingEffect", default: true)
    static let enableShadow = Key<Bool>("enableShadow", default: true)
    static let cornerRadiusScaling = Key<Bool>("cornerRadiusScaling", default: true)

    // Open-notch profiles. Stored as Double because Defaults has no CGFloat
    // bridge; every read is clamped by NotchSizePreferences.
    static let normalNotchWidth = Key<Double>(
        "normalNotchWidth", default: Double(NotchSizeProfile.normal.defaultSize.width))
    static let normalNotchHeight = Key<Double>(
        "normalNotchHeight", default: Double(NotchSizeProfile.normal.defaultSize.height))

    static let tileShowLabels = Key<Bool>("tileShowLabels", default: false)
    static let showCalendar = Key<Bool>("showCalendar", default: false)
    static let hideCompletedReminders = Key<Bool>("hideCompletedReminders", default: true)
    static let sliderColor = Key<SliderColorEnum>(
        "sliderUseAlbumArtColor",
        default: SliderColorEnum.white
    )
    static let playerColorTinting = Key<Bool>("playerColorTinting", default: true)
    static let useMusicVisualizer = Key<Bool>("useMusicVisualizer", default: true)
    static let customVisualizers = Key<[CustomVisualizer]>("customVisualizers", default: [])
    static let selectedVisualizer = Key<CustomVisualizer?>("selectedVisualizer", default: nil)
    
    // MARK: Gestures
    static let enableGestures = Key<Bool>("enableGestures", default: true)
    static let closeGestureEnabled = Key<Bool>("closeGestureEnabled", default: true)
    static let gestureSensitivity = Key<CGFloat>("gestureSensitivity", default: 200.0)
    
    // MARK: Media playback
    static let coloredSpectrogram = Key<Bool>("coloredSpectrogram", default: true)
    static let enableSneakPeek = Key<Bool>("enableSneakPeek", default: false)
    static let sneakPeekStyles = Key<SneakPeekStyle>("sneakPeekStyles", default: .standard)
    static let waitInterval = Key<Double>("waitInterval", default: 3)
    static let showShuffleAndRepeat = Key<Bool>("showShuffleAndRepeat", default: false)
    static let enableLyrics = Key<Bool>("enableLyrics", default: false)
    static let musicControlSlots = Key<[MusicControlButton]>(
        "musicControlSlots",
        default: MusicControlButton.defaultLayout
    )
    static let musicControlSlotLimit = Key<Int>(
        "musicControlSlotLimit",
        default: MusicControlButton.defaultLayout.count
    )
    
    
    // MARK: HUD
    static let hudReplacement = Key<Bool>("hudReplacement", default: false)
    static let inlineHUD = Key<Bool>("inlineHUD", default: false)
    static let enableGradient = Key<Bool>("enableGradient", default: false)
    static let systemEventIndicatorShadow = Key<Bool>("systemEventIndicatorShadow", default: false)
    static let systemEventIndicatorUseAccent = Key<Bool>("systemEventIndicatorUseAccent", default: false)
    static let showOpenNotchHUD = Key<Bool>("showOpenNotchHUD", default: true)
    static let showOpenNotchHUDPercentage = Key<Bool>("showOpenNotchHUDPercentage", default: true)
    static let showClosedNotchHUDPercentage = Key<Bool>("showClosedNotchHUDPercentage", default: false)
    static let showInlineHUDLabel = Key<Bool>("showInlineHUDLabel", default: false)
    // Option key modifier behaviour for media keys
    static let optionKeyAction = Key<OptionKeyAction>("optionKeyAction", default: OptionKeyAction.openSettings)
    
    // MARK: Shelf
    static let callaShelf = Key<Bool>("callaShelf", default: true)
    static let openShelfByDefault = Key<Bool>("openShelfByDefault", default: true)
    static let shelfTapToOpen = Key<Bool>("shelfTapToOpen", default: true)
    static let localSendDestination = Key<String>("localSendDestination", default: LocalSendDestination.phone.rawValue)
    static let localSendBindings = Key<String>("localSendBindings", default: "[]")
    static let localSendIdentity = Key<String>("localSendIdentity", default: "")
    static let shelfShareTransport = Key<String>("shelfShareTransport", default: ShelfShareTransport.localSend.rawValue)
    static let kdeConnectBindings = Key<String>("kdeConnectBindings", default: "[]")
    // A send provider that is off opens no listener, publishes no Bonjour
    // service and touches no Keychain identity, so macOS never asks for the
    // local network permission on its behalf. KDE Connect starts off for that
    // reason; anyone who had already paired a device keeps it (see
    // `KDEConnectService.migrateEnabledFlagIfNeeded`).
    static let localSendEnabled = Key<Bool>("localSendEnabled", default: true)
    static let kdeConnectEnabled = Key<Bool>("kdeConnectEnabled", default: false)
    static let didMigrateKDEConnectEnabled = Key<Bool>("didMigrateKDEConnectEnabled", default: false)
    static let copyOnDrag = Key<Bool>("copyOnDrag", default: false)
    static let autoRemoveShelfItems = Key<Bool>("autoRemoveShelfItems", default: false)
    static let shelfRemoveAfterSend = Key<Bool>("shelfRemoveAfterSend", default: false)
    static let expandedDragDetection = Key<Bool>("expandedDragDetection", default: true)

    // MARK: Calla Call Copilot
    static let callaCopilotEnabled = Key<Bool>("callaCopilotEnabled", default: true)
    /// Screen Quiz remains opt-in until accuracy, privacy, and signed-runtime
    /// gates have been exercised on this build.
    static let callaQuizEnabled = Key<Bool>("callaQuizEnabled", default: false)
    /// The preferred live surface. Legacy values are preserved;
    /// `CallaMode.resolved` maps unavailable modes to Call.
    static let callaCopilotMode = Key<String>("callaCopilotMode", default: "call")
    static let callVPNDisconnectEnabled = Key<Bool>("callVPNDisconnectEnabled", default: false)
    static let callVPNSelectedServiceIDs = Key<[String]>("callVPNSelectedServiceIDs", default: [])
    static let callVPNPendingRestoreIDs = Key<[String]>("callVPNPendingRestoreIDs", default: [])
    /// Write each finished call to ~/Documents/Calls/<Type>/<date title>/.
    /// During a call, rest as a borderless frosted summary that blends into
    /// the screen; hovering brings the collapsed panel back.
    static let callaCopilotAmbient = Key<Bool>("callaCopilotAmbient", default: true)
    /// Where a live call's panel opens: `notch`, `floating`, or `remembered`
    /// (wherever the last call ended). See `CallPanelHome`.
    static let callaCallPanelHome = Key<String>("callaCallPanelHome", default: "notch")
    /// Whether the last call ended in the floating window, for `remembered`.
    static let callaLastCallFloated = Key<Bool>("callaLastCallFloated", default: false)
    /// The floating window's frame on each display, keyed by display UUID, as
    /// `NSStringFromRect`. A display it has never been on gets the top right.
    static let callaFloatingFrames = Key<[String: String]>("callaFloatingFrames", default: [:])
    /// Pop the notch open on the get-ready panel two minutes before a linked
    /// meeting. Off: the closed notch says "Get ready" and waits to be clicked.
    static let callaMeetingOpensNotch = Key<Bool>("callaMeetingOpensNotch", default: false)
    static let callaCallFoldersEnabled = Key<Bool>("callaCallFoldersEnabled", default: true)
    /// Include both sides' audio, compressed, in each call folder.
    static let callaCallFoldersAudio = Key<Bool>("callaCallFoldersAudio", default: true)
    /// Keep a voiceprint for each speaker you name or confirm, so later calls
    /// recognise them. Stored only on this Mac.
    static let callaRememberVoices = Key<Bool>("callaRememberVoices", default: true)
    /// Send every finished call, whole, to the call archive on nomonhomelab.
    static let callaBackendSync = Key<Bool>("callaBackendSync", default: true)
    static let callaQuizVoterOneModel = Key<String>("callaQuizVoterOneModel", default: "gemini-3.1-pro-high")
    static let callaQuizVoterTwoModel = Key<String>("callaQuizVoterTwoModel", default: "claude-opus-4-6-thinking")
    static let callaQuizVoterThreeModel = Key<String>("callaQuizVoterThreeModel", default: "claude-sonnet-4-6")
    static let callaQuizArbiterModel = Key<String>("callaQuizArbiterModel", default: "claude-opus-4-6-thinking")
    /// One council per question mode.
    ///
    /// The four keys above are the legacy flat council. They are kept because a
    /// user who has configured them should not lose that on upgrade — they are
    /// folded into the `fallback` profile once, by `QuizProfileStore.migrateIfNeeded`.
    static let callaQuizProfiles = Key<[String: QuizModeProfile]>(
        "callaQuizProfiles", default: QuizProfileStore.factoryDefaults)
    static let callaQuizWarmMode = Key<String>("callaQuizWarmMode", default: QuizMode.choice.rawValue)
    static let callaQuizProfilesMigrated = Key<Bool>("callaQuizProfilesMigrated", default: false)
    /// Answer before the screen has finished settling, cancelling if it moves.
    static let callaQuizSpeculative = Key<Bool>("callaQuizSpeculative", default: true)
    /// How a code answer is set. Falls back to the system monospaced face when the
    /// named font is not installed, so a missing font degrades rather than
    /// silently rendering code in a proportional face.
    static let callaQuizCodeFont = Key<String>("callaQuizCodeFont",
                                               default: "CaskaydiaCove Nerd Font")
    static let callaQuizCodeFontSize = Key<Double>("callaQuizCodeFontSize", default: 10.5)
    static let callaQuizCodeLineNumbers = Key<Bool>("callaQuizCodeLineNumbers", default: true)
    static let callaQuizCaptureResolution = Key<String>("callaQuizCaptureResolution", default: QuizContract.defaultCaptureResolution.rawValue)
    static let callaQuizTargetWindowID = Key<String>("callaQuizTargetWindowID", default: "")
    static let callaQuizTargetBundleID = Key<String>("callaQuizTargetBundleID", default: "")
    static let callaQuizTargetWindowTitle = Key<String>("callaQuizTargetWindowTitle", default: "")
    /// Which conversation the pointers are tuned for. Bound at call start; the
    /// gateway validates it against the same allowlist.
    static let callaCopilotPersona = Key<String>("callaCopilotPersona", default: "generic")
    /// Calendar sources whose linked meetings may be offered in the Call notch.
    static let calendarCallAccountIDs = Key<[String]>("calendarCallAccountIDs", default: [])
    static let calendarDefaultCallPersona = Key<String>("calendarDefaultCallPersona", default: "generic")

    // How big the call panel is, in both layouts. Stored as Double because
    // `Defaults` has no CGFloat bridge; clamped on read by `CallaPanelSize`, so
    // a value edited by hand in the plist cannot produce a panel the window is
    // too small to draw.
    static let callaPanelWidth = Key<Double>(
        "callaPanelWidth", default: Double(NotchSizeProfile.callExpanded.defaultSize.width))
    static let callaPanelHeight = Key<Double>(
        "callaPanelHeight", default: Double(NotchSizeProfile.callExpanded.defaultSize.height))
    static let callaCompactPanelWidth = Key<Double>(
        "callaCompactPanelWidth", default: Double(NotchSizeProfile.callCollapsed.defaultSize.width))
    static let callaCompactPanelHeight = Key<Double>(
        "callaCompactPanelHeight", default: Double(NotchSizeProfile.callCollapsed.defaultSize.height))
    /// Live transcription model. The archive model is deliberately not offered:
    /// its CoreML encoder forces whisper's full 30s context per utterance.
    static let callaCopilotLiveModel = Key<String>("callaCopilotLiveModel", default: "whisper-small-en")
    /// Peek the newest pointer in the notch as it arrives.
    static let callaCopilotAutoReveal = Key<Bool>("callaCopilotAutoReveal", default: true)
    /// Re-transcribe the saved audio with the large model after the call ends.
    static let callaCopilotArchiveRetranscribe = Key<Bool>("callaCopilotArchiveRetranscribe", default: false)
    /// Start the copilot on its own when a meeting starts, and stop it when the
    /// meeting does.
    /// Legacy storage only. Automatic meeting start is no longer supported.
    static let callaCopilotAutoStartOnMeeting = Key<Bool>("callaCopilotAutoStartOnMeeting", default: false)
    /// Legacy storage only. Calla uses manual-only Call start policy.
    static let callaCopilotPrerollEnabled = Key<Bool>("callaCopilotPrerollEnabled", default: false)
    /// Legacy storage only. Retained for settings decode compatibility.
    static let callaCopilotPrerollLead = Key<Double>("callaCopilotPrerollLead", default: 120)
    /// Events the user has told the pre-roll to leave alone, by event id.
    static let callaCopilotPrerollExcluded = Key<[String]>("callaCopilotPrerollExcluded", default: [])
    /// How much of the desktop shows through the live panel. 0 is the opaque
    /// slab every other tab uses.
    /// Default deliberately low. At 0.45 the desktop behind the notch showed
    /// through hard enough to compete with the text, and this panel is read at a
    /// glance mid-sentence — legibility outranks the effect.
    static let callaCopilotGlassLevel = Key<Double>("callaCopilotGlassLevel", default: 0.12)
    /// Free-text context about the user, injected into every call's prompt.
    static let callaCopilotAboutMe = Key<String>("callaCopilotAboutMe", default: "")
    /// Persona guidance the user has edited, keyed by persona id. Absent keys
    /// fall back to the gateway's own defaults.
    static let callaCopilotPersonaOverrides = Key<[String: String]>("callaCopilotPersonaOverrides", default: [:])
    /// User-defined personas beyond the four the gateway seeds.
    static let callaCopilotCustomPersonas = Key<[String: String]>("callaCopilotCustomPersonas", default: [:])
    /// Replacement for the gateway's base guidance block. Empty means "use the
    /// gateway's own", which is what almost everyone should do.
    static let callaCopilotBaseGuidance = Key<String>("callaCopilotBaseGuidance", default: "")
    /// Which surface the live panel shows: `summary` or `answers`.
    ///
    /// One choice rather than two switches, because both jobs now run the whole time
    /// — questions get answered and the account keeps building regardless — so this
    /// only decides what is on screen. Summary is the resting state; an arriving
    /// answer takes the panel briefly whichever is selected.
    static let callaCopilotPanelSurface = Key<String>("callaCopilotPanelSurface", default: "summary")
    /// Copilot-only settings schema. Never use global reset for a domain migration.
    static let callaCopilotSettingsSchemaVersion = Key<Int>("callaCopilotSettingsSchemaVersion", default: 0)

    // MARK: Calla Intelligence
    /// Which brain answers: "local" (the Antigravity CLI on this Mac) or
    /// "gateway". Local by default — it needs no remote host to be reachable, and
    /// with a resident language server it answers in about the same time.
    static let callaIntelligenceProvider = Key<String>("callaIntelligenceProvider", default: "local")
    /// Model tier for live suggestions: fast | balanced | deep. A tier rather
    /// than a model name because the only transport quick enough for a live call
    /// accepts tiers and nothing finer.
    /// Measured: the fast tier answers in ~1.9s against ~5.2s for balanced, on the
    /// same prompt and the same warm host. On a live call the faster answer is worth
    /// more than the better one — a pointer that lands after the moment has passed is
    /// worth nothing. The end-of-call summary still runs on the deep tier.
    static let callaIntelligenceLiveTier = Key<String>("callaIntelligenceLiveTier", default: "fast")
    /// Exact model for the end-of-call summary, where a slower, better model is
    /// worth the extra seconds.
    static let callaIntelligenceSummaryModel = Key<String>(
        "callaIntelligenceSummaryModel", default: "gemini-3.1-pro-high")
    /// Let the gateway answer when the local brain cannot.
    static let callaIntelligenceFallback = Key<Bool>("callaIntelligenceFallback", default: true)
    /// When the gateway socket opens on a call the local brain is answering:
    /// `off` | `on-failure` | `warm`.
    ///
    /// Was not a choice: the socket connected on every call, received every turn
    /// whether or not the gateway was allowed to answer, and the host awaited its
    /// handshake before opening either microphone — ~1s of startup for a
    /// connection a healthy local call never uses. `warm` keeps the instant
    /// handover and is the default; `on-failure` connects only when the local
    /// brain gives up, and backfills the recent transcript so the handover is not
    /// blind; `off` never opens it, so nothing about the call leaves this Mac.
    static let callaGatewayStandby = Key<String>("callaGatewayStandby", default: "warm")

    // MARK: Usage Monitor
    static let usageMonitorTab = Key<Bool>("usageMonitorTab", default: false)
    static let usageMonitorRefreshInterval = Key<Double>("usageMonitorRefreshInterval", default: 300)
    static let showUsageBesideNotch = Key<Bool>("showUsageBesideNotch", default: false)

    /// Which of the two CLIs to read. Someone who only uses one should not have
    /// the other reported as missing forever.
    static let usageClaudeProfile = Key<String>("usageClaudeProfile", default: "personal")
    static let usageCodexProfile = Key<String>("usageCodexProfile", default: "work")
    static let usageShowClaude = Key<Bool>("usageShowClaude", default: true)
    static let usageShowCodex = Key<Bool>("usageShowCodex", default: true)
    /// Below this much remaining, a quota is drawn as critical. The thresholds
    /// were hard-coded at 50 and 20, which is a guess about how close to the
    /// edge someone likes to run.
    static let usageLowThreshold = Key<Double>("usageLowThreshold", default: 20)
    /// Say something when a quota first drops below that threshold.
    static let usageNotifyOnLow = Key<Bool>("usageNotifyOnLow", default: false)
    // Last successful usage report per provider (UsageReportDTO JSON), shown
    // while a fresh probe fails or before the first probe completes.
    static let cachedClaudeUsage = Key<Data?>("cachedClaudeUsage", default: nil)
    static let cachedCodexUsage = Key<Data?>("cachedCodexUsage", default: nil)
    /// Last failed refresh is stored separately so a good cached allowance never
    /// masquerades as a fresh reading.
    static let usageLastClaudeError = Key<String?>("usageLastClaudeError", default: nil)
    static let usageLastCodexError = Key<String?>("usageLastCodexError", default: nil)

    // MARK: Pomodoro
    static let pomodoroTab = Key<Bool>("pomodoroTab", default: false)
    static let pomodoroPresets = Key<[PomodoroPreset]>("pomodoroPresets", default: PomodoroPreset.seeded)
    static let pomodoroSelectedPresetID = Key<String>("pomodoroSelectedPresetID", default: PomodoroPreset.classic.id)
    static let pomodoroAutoStartBreaks = Key<Bool>("pomodoroAutoStartBreaks", default: true)
    static let pomodoroAutoStartWork = Key<Bool>("pomodoroAutoStartWork", default: false)
    static let pomodoroOpenNotchOnPhaseEnd = Key<Bool>("pomodoroOpenNotchOnPhaseEnd", default: true)
    static let pomodoroAutoResumeAfterWake = Key<Bool>("pomodoroAutoResumeAfterWake", default: false)
    static let pomodoroPlaySound = Key<Bool>("pomodoroPlaySound", default: true)
    // Name of a built-in macOS system sound (NSSound(named:)) — no bundled asset.
    static let pomodoroSoundName = Key<String>("pomodoroSoundName", default: "Glass")
    static let pomodoroPostNotification = Key<Bool>("pomodoroPostNotification", default: true)
    static let pomodoroShowInMenuBar = Key<Bool>("pomodoroShowInMenuBar", default: false)
    static let pomodoroCalendarIcon = Key<Bool>("pomodoroCalendarIcon", default: true)
    // Names of user-authored Shortcuts run at focus start/end. macOS exposes no
    // public API for Do Not Disturb, so this is the only sandbox-safe hook.
    static let pomodoroFocusShortcutStart = Key<String>("pomodoroFocusShortcutStart", default: "")
    static let pomodoroFocusShortcutEnd = Key<String>("pomodoroFocusShortcutEnd", default: "")
    // Live session snapshot (PomodoroPersistedState JSON) so a relaunch resumes.
    static let pomodoroPersistedState = Key<Data?>("pomodoroPersistedState", default: nil)
    // Completed phases (PomodoroRecord JSON), trimmed on write.
    static let pomodoroHistory = Key<Data?>("pomodoroHistory", default: nil)

    // MARK: Calendar
    static let calendarSelectionState = Key<CalendarSelectionState>("calendarSelectionState", default: .all)
    static let hideAllDayEvents = Key<Bool>("hideAllDayEvents", default: false)
    static let showFullEventTitles = Key<Bool>("showFullEventTitles", default: false)
    static let autoScrollToNextEvent = Key<Bool>("autoScrollToNextEvent", default: true)
    static let openMeetingsInApp = Key<Bool>("openMeetingsInApp", default: true)
    
    // MARK: Fullscreen Media Detection
    static let hideNotchOption = Key<HideNotchOption>("hideNotchOption", default: .nowPlayingOnly)
    
    // MARK: Media Controller
    static let mediaController = Key<MediaControllerType>("mediaController", default: defaultMediaController)
    
    // MARK: Advanced Settings
    static let useCustomAccentColor = Key<Bool>("useCustomAccentColor", default: false)
    static let customAccentColorData = Key<Data?>("customAccentColorData", default: nil)
    // Show or hide the title bar
    static let hideTitleBar = Key<Bool>("hideTitleBar", default: true)
    
    // Helper to determine the default media controller based on NowPlaying deprecation status
    static var defaultMediaController: MediaControllerType {
        if MusicManager.shared.isNowPlayingDeprecated {
            return .appleMusic
        } else {
            return .nowPlaying
        }
    }

    static let didClearLegacyURLCacheV1 = Key<Bool>("didClearLegacyURLCache_v1", default: false)
}
