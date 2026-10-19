//
//  MediaPane.swift
//  callaNotch
//

import Defaults
import SwiftUI

/// Music in the notch: one page, with the closed notch drawn at the top and
/// redrawn as the switches under it change.
///
/// Playback Controls used to be a page behind this one. The buttons are edited
/// in place now, at the bottom, because they are part of the same player.
struct Media: View {
    @ObservedObject private var coordinator = CallaViewCoordinator.shared
    @Default(.waitInterval) private var waitInterval
    @Default(.mediaController) private var mediaController
    @Default(.hideNotchOption) private var hideNotchOption
    @Default(.enableSneakPeek) private var enableSneakPeek
    @Default(.sneakPeekStyles) private var sneakPeekStyles
    @Default(.coloredSpectrogram) private var coloredSpectrogram
    @Default(.playerColorTinting) private var playerColorTinting
    @Default(.lightingEffect) private var lightingEffect
    @Default(.sliderColor) private var sliderColor

    private var on: Bool { coordinator.musicLiveActivityEnabled }

    var body: some View {
        SettingsPane(.music, isOn: $coordinator.musicLiveActivityEnabled) {
            stage

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: SettingsMetrics.groupGap) {
                    closedNotch
                    source
                }
                .frame(maxWidth: .infinity, alignment: .top)
                VStack(alignment: .leading, spacing: SettingsMetrics.groupGap) {
                    player
                    fullScreen
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }

            SettingsEmbedded(.controlSlots, caption: "Playback buttons") {
                MusicSlotConfigurationView()
            }
        }
        .onChange(of: mediaController) { _, _ in
            NotificationCenter.default.post(name: Notification.Name.mediaControllerChanged, object: nil)
        }
    }

    // MARK: - Preview

    private var stage: some View {
        NotchStage(height: 150, caption: caption) {
            NotchSlab(width: 300, height: on && enableSneakPeek ? 58 : 32, bottomRadius: 14) {
                VStack(spacing: 0) {
                    NotchMusicActivity(
                        tint: playerColorTinting ? Color(red: 1.0, green: 0.54, blue: 0.36) : .white,
                        showsArtwork: on)
                    if on && enableSneakPeek {
                        (Text("[Track title] ").foregroundStyle(.white)
                            + Text("· [Artist]").foregroundStyle(.white.opacity(0.55)))
                            .font(.system(size: 12))
                            .padding(.top, 4)
                            .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityLabel(Text("Live preview of the closed notch"))
    }

    private var caption: String {
        if !on { return "Music is off. The notch stays plain." }
        return enableSneakPeek ? "A new track just started" : "Playing, notch closed"
    }

    // MARK: - Groups

    private var closedNotch: some View {
        SettingsList("Closed notch") {
            SettingsToggleRow("Sneak peek on new track",
                              detail: "Title and artist under the notch for a moment.",
                              isOn: $enableSneakPeek.animation(NotchMotion.open))
            if enableSneakPeek {
                SettingsListRow("Sneak peek style") {
                    Picker("", selection: $sneakPeekStyles) {
                        ForEach(SneakPeekStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
            }
            SettingsListRow("Hide when paused for") {
                Picker("", selection: $waitInterval) {
                    Text("At once").tag(0.0)
                    Text("3 seconds").tag(3.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                    if ![0.0, 3, 5, 10].contains(waitInterval) {
                        Text("\(Int(waitInterval)) seconds").tag(waitInterval)
                    }
                }
                .labelsHidden().fixedSize()
            }
        }
        .settingsAnchor("music.closed")
    }

    private var source: some View {
        SettingsList("Source",
                     detail: MusicManager.shared.isNowPlayingDeprecated
                        ? "YouTube Music needs a third-party helper app installed."
                        : nil) {
            SettingsListRow("Read playback from") {
                Picker("", selection: $mediaController) {
                    ForEach(availableMediaControllers) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            if MusicManager.shared.isNowPlayingDeprecated {
                SettingsListRow("Helper app") {
                    Link("pear-desktop", destination: URL(string: "https://github.com/pear-devs/pear-desktop")!)
                }
            }
        }
        .settingsAnchor("music.source")
    }

    private var player: some View {
        SettingsList("Player") {
            SettingsToggleRow("Colour from the artwork", isOn: $playerColorTinting)
            SettingsToggleRow("Blur behind artwork", isOn: $lightingEffect)
            SettingsToggleRow("Coloured level meter", isOn: $coloredSpectrogram)
            SettingsListRow("Progress bar") {
                Picker("", selection: $sliderColor) {
                    Text("Artwork").tag(SliderColorEnum.albumArt)
                    Text("Accent").tag(SliderColorEnum.accent)
                    Text("White").tag(SliderColorEnum.white)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
        }
        .settingsAnchor("music.player")
    }

    private var fullScreen: some View {
        SettingsList("Full screen") {
            SettingsListRow("Hide the notch", detail: "When something goes full screen.") {
                Picker("", selection: $hideNotchOption) {
                    Text("For every app").tag(HideNotchOption.always)
                    Text("For the music app").tag(HideNotchOption.nowPlayingOnly)
                    Text("Never").tag(HideNotchOption.never)
                }
                .labelsHidden().fixedSize()
            }
        }
        .settingsAnchor("music.fullscreen")
    }

    /// Now Playing is not offered where macOS no longer supports it.
    private var availableMediaControllers: [MediaControllerType] {
        MusicManager.shared.isNowPlayingDeprecated
            ? MediaControllerType.allCases.filter { $0 != .nowPlaying }
            : MediaControllerType.allCases
    }
}
