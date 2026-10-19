//
//  ShelfView.swift
//  callaNotch
//
//  Created by Alexander on 2025-09-24.
//

import SwiftUI
import AppKit

struct ShelfView: View {
    @EnvironmentObject var vm: CallaViewModel
    @StateObject var tvm = ShelfStateViewModel.shared
    @StateObject var selection = ShelfSelectionModel.shared
    @StateObject private var shelfShare = ShelfShareService.shared
    @StateObject private var quickLookService = QuickLookService()

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                queueHeader
                if tvm.isEmpty {
                    dropZone
                } else {
                    queueRail
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(spacing: 8) {
                destinationChip
                sendButton
            }
            .frame(width: 132)
            .frame(maxHeight: .infinity)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 10)
        // One drop target for the whole tab: dropping queues, sending is always
        // an explicit press.
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data, .image], isTargeted: $vm.dropZoneTargeting) { providers in
            handleDrop(providers: providers)
        }
        .onChange(of: tvm.items.map(\.id)) {
            if !shelfShare.isSending { shelfShare.clearTransfers() }
        }
        .onChange(of: selection.selectedIDs) {
            updateQuickLookSelection()
        }
        .quickLookPresenter(using: quickLookService)
    }

    // MARK: - Queue

    /// What is queued, in the tab's accent, with Clear beside it. A send error
    /// takes the line over, since it is the one thing worth reading here then.
    private var queueHeader: some View {
        HStack(spacing: 8) {
            NotchCaps(shelfShare.lastError ?? summary,
                      tint: shelfShare.lastError == nil ? NotchAccent.shelf : NotchAccent.attention)
            Spacer(minLength: 4)
            if !tvm.isEmpty {
                Button { tvm.clear() } label: {
                    Text("Clear")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(NotchInk.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(shelfShare.isSending)
                .help("Remove everything from the queue")
                .accessibilityLabel("Clear the queue")
            }
        }
        .frame(height: 20)
    }

    private var dropZone: some View {
        Button { tvm.chooseFiles() } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(NotchAccent.shelf)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drop files here")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(NotchInk.primary)
                    Text("They wait here until you send them")
                        .font(NotchGlassType.caption)
                        .foregroundStyle(NotchInk.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 78)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(NotchAccent.shelf.opacity(isDropTargeted ? NotchAccent.fill : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(NotchAccent.shelf.opacity(isDropTargeted ? 0.9 : 0.45),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help("Choose files to queue")
    }

    private var queueRail: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(tvm.items) { item in
                    ShelfQueueChip(
                        item: item,
                        isSelected: selection.isSelected(item.id),
                        transfer: shelfShare.transfers[item.id],
                        onRemove: { tvm.remove(item) }
                    )
                }
                addTile
            }
            .padding(.top, 5)
            .padding(.trailing, 6)
        }
        .scrollIndicators(.never)
        .padding(.top, -5)
        .background(isDropTargeted ? NotchAccent.shelf.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .environmentObject(quickLookService)
        .onAppear { ShelfStateViewModel.shared.cleanupInvalidItems() }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !selection.consumeChipClick() else { return }
            selection.clear()
        }
    }

    private var addTile: some View {
        VStack(spacing: 5) {
            Button { tvm.chooseFiles() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NotchInk.secondary)
                    .frame(width: ShelfQueueChip.size.width, height: ShelfQueueChip.size.height)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.24),
                                          style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .help("Add files")
            .accessibilityLabel("Add files")
            Text("Add")
                .font(.system(size: 10))
                .foregroundStyle(NotchInk.tertiary)
        }
        .frame(width: ShelfQueueChip.columnWidth)
    }

    // MARK: - Send

    /// Where files go, and whether it can take them. The menu also carries
    /// Shelf settings, which had its own glyph before.
    private var destinationChip: some View {
        Menu {
            ForEach(LocalSendDestination.allCases) { destination in
                Button(destination.title) { shelfShare.select(destination) }
            }
            Divider()
            Button("Shelf settings…") { SettingsWindowController.shared.showShelfWindow() }
        } label: {
            // One Text with the dot drawn as a glyph: a borderless menu strips a
            // label's own background and reorders mixed children.
            (Text(Image(systemName: shelfShare.selectedDestination.symbolName))
             + Text("  \(shelfShare.selectedDestination.title)"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchInk.primary)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.leading, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                    .opacity(shelfShare.isDiscovering ? 0.4 : 1)
                Text(statusWord)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(NotchInk.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.trailing, 10)
            .allowsHitTesting(false)
        }
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
        .help("Destination: \(shelfShare.selectedDestination.title), \(statusWord). Change")
        .accessibilityLabel("Destination: \(shelfShare.selectedDestination.title), \(statusWord). Change")
    }

    private var sendButton: some View {
        Button {
            if shelfShare.isAvailable && shelfShare.selectedDestinationReady {
                Task { await shelfShare.shareShelfItems(queuedItems) }
            } else {
                SettingsWindowController.shared.showShelfWindow()
            }
        } label: {
            ZStack(alignment: .leading) {
                if shelfShare.isSending {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(NotchAccent.shelf)
                            .frame(width: geo.size.width * shelfShare.sendFraction)
                    }
                    .animation(.smooth(duration: 0.3), value: shelfShare.sendFraction)
                }
                HStack(spacing: 7) {
                    Image(systemName: canSend || shelfShare.isSending || tvm.isEmpty ? "arrow.up" : "exclamationmark.circle")
                        .font(.system(size: 12, weight: .heavy))
                    Text(actionTitle)
                        .font(.system(size: 13, weight: .bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundStyle(sendInk)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(sendFill))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(tvm.isEmpty || shelfShare.isSending)
        .help(actionTitle)
    }

    private var canSend: Bool {
        !tvm.isEmpty && shelfShare.isAvailable && shelfShare.selectedDestinationReady
    }

    private var sendFill: Color {
        if shelfShare.isSending { return NotchAccent.shelf.opacity(0.35) }
        if canSend { return NotchAccent.shelf }
        return Color.white.opacity(tvm.isEmpty ? 0.07 : 0.10)
    }

    private var sendInk: Color {
        if canSend && !shelfShare.isSending { return NotchAccent.onAccent }
        return tvm.isEmpty ? NotchInk.tertiary : NotchInk.primary
    }

    private var statusColor: Color {
        if shelfShare.selectedDestinationReady { return NotchAccent.call }
        return shelfShare.isPaired(shelfShare.selectedDestination) ? NotchAccent.attention : NotchInk.tertiary
    }

    private var statusWord: String {
        if shelfShare.isSending { return "Sending" }
        if shelfShare.selectedDestinationReady { return "Ready" }
        return shelfShare.isPaired(shelfShare.selectedDestination) ? "Offline" : "Not paired"
    }

    private var actionTitle: String {
        if shelfShare.isSending { return "Sending \(Int(shelfShare.sendFraction * 100))%" }
        let destination = shelfShare.selectedDestination.title
        if tvm.isEmpty { return "Send to \(destination)" }
        if !shelfShare.isAvailable { return "Set up sharing" }
        if !shelfShare.selectedDestinationReady {
            return shelfShare.isPaired(shelfShare.selectedDestination) ? "Connect \(destination)" : "Pair \(destination)"
        }
        return "Send to \(destination)"
    }

    // MARK: - Derived state

    private var isDropTargeted: Bool { vm.dropZoneTargeting || vm.dragDetectorTargeting }

    /// Selection narrows what Send targets, so the summary has to say so.
    private var queuedItems: [ShelfItem] {
        let selected = selection.selectedItems(in: tvm.items)
        return selected.isEmpty ? tvm.items : selected
    }

    private var summary: String {
        guard !tvm.isEmpty else { return "Nothing queued" }
        if selection.hasSelection {
            return "\(queuedItems.count) of \(tvm.items.count) selected"
        }
        return "\(tvm.items.count) queued"
    }

    // MARK: - Actions

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !selection.isDragging else { return false }
        vm.dropEvent = true
        ShelfStateViewModel.shared.load(providers)
        return true
    }

    private func updateQuickLookSelection() {
        guard quickLookService.isQuickLookOpen && !selection.selectedIDs.isEmpty else { return }

        let urls: [URL] = selection.selectedItems(in: tvm.items).compactMap { item in
            if let fileURL = item.fileURL { return fileURL }
            if case .link(let url) = item.kind { return url }
            return nil
        }

        if !urls.isEmpty {
            quickLookService.updateSelection(urls: urls)
        }
    }
}
