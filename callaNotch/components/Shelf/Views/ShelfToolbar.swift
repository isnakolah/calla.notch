//
//  ShelfToolbar.swift
//  callaNotch
//
//  Destination picker, reachability and queue summary for the Shelf tab.
//

import SwiftUI

struct ShelfToolbar: View {
    static let height: CGFloat = 18

    @ObservedObject var shelfShare: ShelfShareService
    let itemCount: Int
    let selectedCount: Int
    let summary: String
    let canClear: Bool
    let onClear: () -> Void

    @Namespace private var destinationNamespace

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Destination").font(.system(size: 11, weight: .semibold))
                Spacer()
                settingsButton
            }
            destinationPicker
            HStack(spacing: 4) {
                statusIndicator
                Spacer(minLength: 0)
                if canClear { clearButton }
            }
        }
        .padding(8)
        .frame(height: 104)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.06)))
    }

    private var destinationPicker: some View {
        VStack(spacing: 4) {
            ForEach(LocalSendDestination.allCases) { destination in
                let selected = shelfShare.selectedDestination == destination
                Button { withAnimation(.easeInOut(duration: 0.18)) { shelfShare.select(destination) } } label: {
                    HStack(spacing: 7) {
                        Image(systemName: destination.symbolName).frame(width: 14)
                        Text(destination.title).fontWeight(.medium)
                        Spacer(minLength: 0)
                        if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.effectiveAccent : NotchInk.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 23)
                    .background(selected ? Color.effectiveAccent.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send to \(destination.title)")
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    /// A dot alone when the destination is reachable; the word only shows up
    /// when something is actually wrong, which keeps the row narrow.
    private var statusIndicator: some View {
        Button {
            shelfShare.refreshDiscovery()
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 5, height: 5)
                    .opacity(shelfShare.isDiscovering ? 0.4 : 1)
                if let statusWord {
                    Text(statusWord)
                        .font(NotchGlassType.caption)
                        .foregroundStyle(NotchInk.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Refresh devices")
        .accessibilityLabel(statusWord.map { "Devices: \($0). Refresh" } ?? "Devices ready. Refresh")
        .animation(.smooth(duration: 0.3), value: shelfShare.isDiscovering)
    }

    private var statusColor: Color {
        if shelfShare.selectedDestinationReady { return NotchTint.healthy }
        return shelfShare.isPaired(shelfShare.selectedDestination) ? NotchTint.attention : NotchInk.tertiary
    }

    private var statusWord: String? {
        if shelfShare.selectedDestinationReady { return nil }
        return shelfShare.isPaired(shelfShare.selectedDestination) ? "Offline" : "Not paired"
    }

    // MARK: - Summary and controls

    private var summaryLabel: some View {
        Text(shelfShare.lastError ?? summary)
            .font(NotchGlassType.caption)
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(summaryColor)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var summaryColor: Color {
        if shelfShare.lastError != nil { return NotchTint.attention }
        return selectedCount > 0 ? Color.effectiveAccent : NotchInk.tertiary
    }

    private var clearButton: some View {
        Button(action: onClear) {
            Text("Clear")
                .font(NotchGlassType.caption)
                .foregroundStyle(NotchInk.tertiary)
        }
        .buttonStyle(.plain)
        .disabled(shelfShare.isSending)
        .help("Remove everything from the queue")
        .accessibilityLabel("Clear the queue")
    }

    private var settingsButton: some View {
        Button {
            SettingsWindowController.shared.showShelfWindow()
        } label: {
            Image(systemName: "gearshape")
                .font(NotchGlassType.glyph)
                .foregroundStyle(NotchInk.tertiary)
                .frame(width: Self.height, height: Self.height)
        }
        .buttonStyle(.plain)
        .help("Shelf settings")
        .accessibilityLabel("Shelf settings")
    }
}
