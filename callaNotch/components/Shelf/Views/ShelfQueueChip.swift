//
//  ShelfQueueChip.swift
//  callaNotch
//
//  A single queued item in the Shelf rail.
//

import AppKit
import SwiftUI

/// A 52×58 tile with the file's extension as a badge, and its name under it.
///
/// The tile, not the name, is what the eye scans: four of them sit beside the
/// send column, and the badge says what kind of thing each one is before a
/// filename is read. The name below takes the column's full 60pt.
struct ShelfQueueChip: View {
    static let size = CGSize(width: 52, height: 58)
    static let columnWidth: CGFloat = 60

    let item: ShelfItem
    let isSelected: Bool
    let transfer: ShelfTransferState?
    let onRemove: () -> Void

    @EnvironmentObject private var quickLookService: QuickLookService
    @StateObject private var viewModel: ShelfItemViewModel
    @State private var meta: ShelfItemMetadata?
    @State private var isHovering = false

    init(item: ShelfItem, isSelected: Bool, transfer: ShelfTransferState?, onRemove: @escaping () -> Void) {
        self.item = item
        self.isSelected = isSelected
        self.transfer = transfer
        self.onRemove = onRemove
        _viewModel = StateObject(wrappedValue: ShelfItemViewModel(item: item))
    }

    private static let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        VStack(spacing: 5) {
            tile
            name
        }
        .frame(width: Self.columnWidth)
    }

    private var tile: some View {
        tileContent
            .frame(width: Self.size.width, height: Self.size.height)
            .background { background }
            .overlay(alignment: .bottom) { progressBar }
            .clipShape(Self.shape)
            .contentShape(Self.shape)
            .overlay { dragHandler }
            .overlay(alignment: .topTrailing) { trailingSlot.offset(x: 5, y: -5) }
            .onHover { hovering in
                withAnimation(.smooth(duration: 0.2)) { isHovering = hovering }
            }
            .task(id: item.id) {
                meta = await ShelfItemMetadataCache.shared.metadata(for: item)
            }
            .onAppear {
                viewModel.onQuickLookRequest = { urls in
                    quickLookService.show(urls: urls, selectFirst: true)
                }
            }
            .help(meta?.displayName ?? "")
    }

    private var tileContent: some View {
        VStack(spacing: 5) {
            thumbnail
            extensionBadge
        }
        .padding(.top, 8)
        .padding(.bottom, 7)
    }

    private var name: some View {
        Text(nameLine)
            .font(.system(size: 10))
            .foregroundStyle(Color.white.opacity(0.80))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: Self.columnWidth)
            .redacted(reason: meta == nil ? .placeholder : [])
    }

    /// The name, unless a transfer has something to say instead.
    private var nameLine: String {
        switch transfer {
        case .sending(let fraction): "\(Int(fraction * 100))%"
        case .sent: "Sent"
        case .failed(let reason): reason
        default: meta?.displayName ?? " "
        }
    }

    private var extensionBadge: some View {
        Text(badgeText)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(Color.black)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .frame(height: 15)
            .background(RoundedRectangle(cornerRadius: 4).fill(badgeColor))
    }

    private var badgeText: String {
        switch item.kind {
        case .text: return "TXT"
        case .link: return "URL"
        case .file:
            let ext = (meta?.url?.pathExtension ?? (meta?.displayName as NSString?)?.pathExtension ?? "")
            return ext.isEmpty ? "FILE" : String(ext.uppercased().prefix(4))
        }
    }

    private var badgeColor: Color {
        switch badgeText {
        case "PDF", "DOC", "DOCX", "PAGES", "TXT", "MD", "RTF": return NotchAccent.home
        case "PNG", "JPG", "JPEG", "HEIC", "GIF", "WEBP", "MOV", "MP4", "URL": return NotchAccent.quiz
        case "ZIP", "DMG", "TAR", "GZ", "7Z", "PKG": return NotchAccent.shelf
        default: return Color.white.opacity(0.70)
        }
    }

    private var background: some View {
        Self.shape
            .fill(fillColor)
            .overlay { Self.shape.strokeBorder(strokeColor, lineWidth: 1) }
    }

    private var dragHandler: some View {
        ShelfDragHandler(
            item: item,
            viewModel: viewModel,
            dragPreviewImage: viewModel.thumbnail,
            passthroughRects: isHovering ? actionHitRects : [],
            onRightClick: { event, view in viewModel.handleRightClick(event: event, view: view) },
            onClick: { event, view in viewModel.handleClick(event: event, view: view) }
        )
    }

    /// Kept in sync with the layout above so the AppKit drag overlay lets these
    /// two clicks through. Top-left origin, in the tile's own 52×58.
    private var actionHitRects: [CGRect] {
        [
            CGRect(x: 12, y: 6, width: 28, height: 24),   // Quick Look, over the thumbnail
            CGRect(x: 36, y: 0, width: 16, height: 16)    // remove, at the corner
        ]
    }

    // MARK: - Pieces

    private var thumbnail: some View {
        ZStack {
            Image(nsImage: viewModel.thumbnail ?? item.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .opacity(isHovering ? 0.2 : 1)

            if isHovering {
                Image(systemName: "eye")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .transition(.opacity)
            }
        }
        .frame(width: 22, height: 22)
        .onTapGesture { viewModel.quickLookSelection() }
        .help("Quick Look")
        .accessibilityLabel("Quick Look")
    }

    /// The corner of the tile: remove on hover, otherwise a transfer's outcome
    /// or the selection check.
    @ViewBuilder
    private var trailingSlot: some View {
        if isHovering {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color(white: 0.28)))
                    .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .transition(.opacity)
            .help("Remove from queue")
            .accessibilityLabel("Remove from queue")
        } else if let badge = stateBadge {
            Image(systemName: badge.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(badge.color)
                .background(Circle().fill(.black).padding(1))
        } else if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(NotchAccent.shelf)
                .background(Circle().fill(.black).padding(1))
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if case .sending(let fraction) = transfer {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.12))
                    Rectangle()
                        .fill(NotchAccent.shelf)
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 3)
            .animation(.smooth(duration: 0.25), value: fraction)
        }
    }

    // MARK: - Derived state

    private var fillColor: Color {
        if isSelected { return NotchAccent.shelf.opacity(NotchAccent.fill) }
        return Color.white.opacity(isHovering ? 0.11 : 0.07)
    }

    private var strokeColor: Color {
        isSelected ? NotchAccent.shelf.opacity(0.7) : Color.white.opacity(0.10)
    }

    private var stateBadge: (symbol: String, color: Color)? {
        switch transfer {
        case .sent: ("checkmark.circle.fill", NotchAccent.call)
        case .failed: ("exclamationmark.triangle.fill", NotchAccent.attention)
        default: nil
        }
    }
}
