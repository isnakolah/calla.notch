import Foundation
import IntelligenceCore

public extension ModelCatalog {
    /// What `agy` exposes, and the tier tokens `agentapi` accepts.
    ///
    /// The pairing was verified by asking each tier what it was running as:
    /// `flash` answered "Gemini 3.7 Flash", `pro` answered Gemini Pro,
    /// `flash_lite` answered generically. The exact ids come from `agy models`
    /// and only the print transport can honour them.
    ///
    /// The flash ids moved to 3.8 when `agy models` began offering it. The deep
    /// tier stays on `gemini-3.1-pro-high` because there is no 3.8 pro — the
    /// catalogue lists 3.8 in flash only — and a flash model on the tier that
    /// exists to think would be a quality change dressed as a version bump.
    ///
    /// Note the tier *tokens* are unchanged and cannot select a version.
    /// `agentapi` takes `flash_lite|flash|pro` and nothing else — measured
    /// against a live host, `--model=gemini-3.8-flash-low` comes back
    /// `"no available models found for tier gemini-3.8-flash-low"` while
    /// `--model=flash_lite` opens a conversation. So `exactID` reaches only the
    /// print transport and the workers that spawn `agy --model` themselves;
    /// every lane on the resident host gets whatever the token resolves to
    /// server-side, and no change here can pin a version for them.
    static let agy = ModelCatalog(
        provider: .localAgy,
        entries: [
            Entry(
                tier: .fast,
                tierToken: "flash_lite",
                exactID: "gemini-3.8-flash-low",
                displayName: "Gemini 3.8 Flash (Low)"
            ),
            Entry(
                tier: .balanced,
                tierToken: "flash",
                exactID: "gemini-3.8-flash-medium",
                displayName: "Gemini 3.8 Flash (Medium)"
            ),
            Entry(
                tier: .deep,
                tierToken: "pro",
                exactID: "gemini-3.1-pro-high",
                displayName: "Gemini 3.1 Pro (High)"
            ),
        ]
    )
}
