//
//  ShelfView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import SwiftUI
import AppKit

struct ShelfView: View {
    @EnvironmentObject var vm: BoringViewModel
    @StateObject var tvm = ShelfStateViewModel.shared
    @StateObject var selection = ShelfSelectionModel.shared
    @StateObject private var shelfShare = ShelfShareService.shared
    @StateObject private var quickLookService = QuickLookService()

    // 18 + 3 + 56 + 3 + 24 = 104, the same content canvas as Usage and
    // Pomodoro. The rail takes the majority so queue rows can be legible.
    private static let rowSpacing: CGFloat = 3
    private static let railHeight: CGFloat = 56

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: NotchGlassSpace.snug) {
                HStack(spacing: 5) {
                    NotchStatusDot(live: shelfShare.isSending,
                                   tint: shelfShare.selectedDestinationReady ? NotchTint.healthy : NotchTint.attention)
                    NotchCaps(shelfShare.isSending ? "Sending" : (shelfShare.selectedDestinationReady ? "Ready" : "Offline"))
                    Spacer(minLength: 0)
                    NotchGlyphButton(symbol: "gearshape", help: "Shelf settings") {
                        SettingsWindowController.shared.showShelfWindow()
                    }
                }
                CallaContextChip(title: shelfShare.selectedDestination.title,
                                 symbol: shelfShare.selectedDestination.symbolName) {
                    ForEach(LocalSendDestination.allCases) { destination in
                        Button(destination.title) { shelfShare.select(destination) }
                    }
                }
                Text(shelfShare.lastError ?? "Choose where your files go.")
                    .font(NotchGlassType.caption).foregroundStyle(NotchInk.tertiary)
                    .lineLimit(2)
                CallaPrimaryButton(title: actionTitle,
                                   symbol: tvm.isEmpty ? "plus" : "arrow.up.right",
                                   enabled: !shelfShare.isSending) {
                    if tvm.isEmpty { tvm.chooseFiles() }
                    else if shelfShare.isAvailable && shelfShare.selectedDestinationReady {
                        Task { await shelfShare.shareShelfItems(queuedItems) }
                    } else { SettingsWindowController.shared.showShelfWindow() }
                }
            }
            .frame(width: 158, alignment: .leading)
            NotchColumnDivider()
            VStack(alignment: .leading, spacing: NotchGlassSpace.snug) {
                HStack {
                    NotchCaps(tvm.isEmpty ? "Files" : summary)
                    Spacer(minLength: 4)
                    NotchGlyphButton(symbol: "plus", help: "Add files") { tvm.chooseFiles() }
                    if !tvm.isEmpty {
                        NotchGlyphButton(symbol: "trash", help: "Clear queue") { tvm.clear() }
                            .disabled(shelfShare.isSending)
                    }
                }
                if tvm.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Drop files here").font(NotchGlassType.title).foregroundStyle(NotchInk.primary)
                        Text("They stay queued until you send.")
                            .font(NotchGlassType.caption).foregroundStyle(NotchInk.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                } else {
                    queueRail.frame(maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .notchCard()
        .notchTabInsets()
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

    // MARK: - Queue rail

    private var actionTitle: String {
        if shelfShare.isSending { return "Sending \(Int(shelfShare.sendFraction * 100))%" }
        if tvm.isEmpty { return "Choose files" }
        if !shelfShare.isAvailable { return "Set up sharing" }
        if !shelfShare.selectedDestinationReady {
            return shelfShare.isPaired(shelfShare.selectedDestination)
                ? "Connect \(shelfShare.selectedDestination.title)" : "Pair \(shelfShare.selectedDestination.title)"
        }
        return "Send to \(shelfShare.selectedDestination.title)"
    }

    private var queueRail: some View {
        railContent
            .padding(2)
            .background(isDropTargeted ? Color.effectiveAccent.opacity(0.1) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture {
                guard !selection.consumeChipClick() else { return }
                selection.clear()
            }
    }

    @ViewBuilder
    private var railContent: some View {
        if tvm.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(Color.effectiveAccent.opacity(0.8))
                Text("Drop files to queue")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NotchInk.primary)
                Button { tvm.chooseFiles() } label: {
                    Label("Choose files", systemImage: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(NotchInk.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Two columns, filling row-major, scrolling down.
            //
            // It was two rows scrolling sideways, which put the fifth item off
            // the right-hand edge with nothing to say it was there — and a
            // sideways scroller of wide, short chips reads as a broken list
            // rather than a grid. Down is the direction a list of things grows.
            ScrollView(.vertical) {
                LazyVGrid(
                    columns: [GridItem(.flexible())],
                    alignment: .leading,
                    spacing: 4
                ) {
                    ForEach(tvm.items) { item in
                        ShelfQueueChip(
                            item: item,
                            isSelected: selection.isSelected(item.id),
                            transfer: shelfShare.transfers[item.id],
                            onRemove: { tvm.remove(item) }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.never)
            .environmentObject(quickLookService)
            .onAppear { ShelfStateViewModel.shared.cleanupInvalidItems() }
        }
    }

    // MARK: - Derived state

    private var isDropTargeted: Bool { vm.dropZoneTargeting || vm.dragDetectorTargeting }

    /// Selection narrows what Send targets, so the summary has to say so.
    private var queuedItems: [ShelfItem] {
        let selected = selection.selectedItems(in: tvm.items)
        return selected.isEmpty ? tvm.items : selected
    }

    private var summary: String {
        guard !tvm.isEmpty else { return "" }
        if selection.hasSelection {
            return "\(queuedItems.count) of \(tvm.items.count) selected"
        }
        return tvm.items.count == 1 ? "1 item" : "\(tvm.items.count) items"
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
