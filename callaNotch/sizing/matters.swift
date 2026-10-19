//
//  sizeMatters.swift
//  callaNotch
//
//  Created by Harsh Vardhan  Goswami  on 05/08/24.
//

import Defaults
import Foundation
import SwiftUI

let downloadSneakSize: CGSize = .init(width: 65, height: 1)
let batterySneakSize: CGSize = .init(width: 160, height: 1)

let shadowPadding: CGFloat = 20
let resizeEditorCanvasAllowance: CGFloat = NotchResizeGeometry.editorVerticalAllowance
let resizeGripCanvasAllowance: CGFloat = 32

/// Normal tabs all share this persisted profile.
var openNotchSize: CGSize { NotchSizePreferences.size(.normal) }

/// The notch while a call copilot session is live.
///
/// Wider and much taller than a normal tab: it carries a running transcript
/// beside the pointer, and a transcript that only shows two turns is not one.
///
/// The default. What is actually used is `CallaPanelSize.full`, which lets the
/// user resize the panel — how much of a call you want on screen is a matter of
/// screen size and taste, and no single pair of numbers is right for everyone.
let copilotNotchSize: CGSize = NotchSizeProfile.callExpanded.defaultSize

/// How far the call panel may be resized.
///
/// The window behind the notch is created **once** at `maxOpenNotchSize` and
/// never resized — the shape is clipped to `vm.notchSize` and anything unused
/// stays transparent. So a user-chosen size larger than that ceiling would be
/// silently cut off rather than shown, which is why the ceiling below is
/// computed from these maxima and not from the defaults.
enum CallaPanelBounds {
    static let width: ClosedRange<CGFloat> = NotchSizeProfile.callExpanded.widthBounds
    static let fullHeight: ClosedRange<CGFloat> = NotchSizeProfile.callExpanded.heightBounds
    /// The floor is not arbitrary: below about 150 the answer, the caption strip
    /// and the controls cannot all be on screen, and the answer is what gives
    /// way. See the note on `copilotCompactNotchSize`.
    static let compactHeight: ClosedRange<CGFloat> = NotchSizeProfile.callCollapsed.heightBounds

    static func clampWidth(_ value: CGFloat) -> CGFloat {
        min(max(value, width.lowerBound), width.upperBound)
    }

    static func clampFullHeight(_ value: CGFloat) -> CGFloat {
        min(max(value, fullHeight.lowerBound), fullHeight.upperBound)
    }

    static func clampCompactHeight(_ value: CGFloat) -> CGFloat {
        min(max(value, compactHeight.lowerBound), compactHeight.upperBound)
    }
}

/// The notch while the call panel is collapsed to the answer alone.
///
/// Deleted once, as an unused constant, on the reasoning that a call should keep
/// the full slab in both layouts so collapsing could never read as the call
/// having ended. Watching it run says otherwise: the answer alone in a 600x340
/// panel is mostly empty card, and "compact" that is the same size as "full" is
/// not compact. The header band keeps the state and the clock, so the call is
/// still plainly running at this size.
// The default. `CallaPanelSize.compact` is what is used.
//
// 200 rather than 220, 220 rather than 250, and 250 rather than 210.
//
// At 210 the column had ~124pt after the header band, the insets and the
// controls' strip, and a three-line answer plus a two-line caption wanted about
// 150 — SwiftUI resolved that by compressing the answer to a single ellipsised
// line, so the one thing the panel exists to show was the one thing that could
// not be read.
//
// 220 bought the height back from the caption rather than from the answer: the
// strip is one line here instead of two (`captionStream`), which is 15pt, and
// the newest words are still the ones on screen because it truncates from the
// head. 200 takes the rest out of the gaps between recap lines, which had more
// air than the lines needed.
let copilotCompactNotchSize: CGSize = NotchSizeProfile.callCollapsed.defaultSize

/// The notch while a file is being filed against a meeting.
///
/// Two columns — drop on one side, choose on the other — so it needs the copilot's
/// width rather than a normal tab's. At `openNotchSize`'s 168pt the drop target
/// and the list of what is already attached could not both be on screen, and the
/// whole point of the surface is seeing the second while you use the first.
var knowledgeNotchSize: CGSize {
    NotchResizeGeometry.applyingMinimum(
        CGSize(width: 600, height: 300),
        to: NotchSizePreferences.size(.normal)
    )
}

/// The notch while a dragged file is being aimed at one half or the other.
///
/// Two tiles side by side need width more than height; taller than a normal tab
/// only because each tile says what it will do rather than just naming itself.
var dropChooserNotchSize: CGSize {
    NotchResizeGeometry.applyingMinimum(
        CGSize(width: 512, height: 200),
        to: NotchSizePreferences.size(.normal)
    )
}

/// The largest the open notch can ever be.
///
/// The panel is created once at this size and never resized — the notch shape
/// is clipped to `vm.notchSize` and pinned to the top, so anything the current
/// mode does not use stays transparent. That is already how the 185pt closed
/// notch lives inside a 512pt window; growing the ceiling just extends it.
/// The largest the open notch can ever be.
///
/// Driven by `CallaPanelBounds`' upper limits rather than by the copilot's
/// current size, because the call panel is user-resizable and the window is
/// created once. Sizing this to today's default would clip anyone who made the
/// panel bigger, and the symptom — a panel cut off at the bottom — would look
/// like a layout bug rather than a window that was never big enough.
let maxOpenNotchSize: CGSize = .init(
    width: max(NotchSizeProfile.normal.widthBounds.upperBound,
               CallaPanelBounds.width.upperBound),
    height: max(
        NotchSizeProfile.normal.heightBounds.upperBound,
        max(CallaPanelBounds.compactHeight.upperBound,
            CallaPanelBounds.fullHeight.upperBound)))

let windowSize: CGSize = .init(
    width: maxOpenNotchSize.width + resizeGripCanvasAllowance,
    height: maxOpenNotchSize.height + shadowPadding + resizeEditorCanvasAllowance
)
let cornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) = (opened: (top: 19, bottom: 24), closed: (top: 6, bottom: 14))

enum MusicPlayerImageSizes {
    static let cornerRadiusInset: (opened: CGFloat, closed: CGFloat) = (opened: 13.0, closed: 4.0)
    static let size = (opened: CGSize(width: 90, height: 90), closed: CGSize(width: 20, height: 20))
}

@MainActor func getScreenFrame(_ screenUUID: String? = nil) -> CGRect? {
    var selectedScreen = NSScreen.main

    if let uuid = screenUUID {
        selectedScreen = NSScreen.screen(withUUID: uuid)
    }
    
    if let screen = selectedScreen {
        return screen.frame
    }
    
    return nil
}

@MainActor func getClosedNotchSize(screenUUID: String? = nil) -> CGSize {
    // Default notch size, to avoid using optionals
    var notchHeight: CGFloat = Defaults[.nonNotchHeight]
    var notchWidth: CGFloat = 185

    var selectedScreen = NSScreen.main

    if let uuid = screenUUID {
        selectedScreen = NSScreen.screen(withUUID: uuid)
    }

    // Check if the screen is available
    if let screen = selectedScreen {
        // Calculate and set the exact width of the notch
        if let topLeftNotchpadding: CGFloat = screen.auxiliaryTopLeftArea?.width,
           let topRightNotchpadding: CGFloat = screen.auxiliaryTopRightArea?.width
        {
            notchWidth = screen.frame.width - topLeftNotchpadding - topRightNotchpadding + 4
        }

        // Check if the Mac has a notch
        if screen.safeAreaInsets.top > 0 {
            // This is a display WITH a notch - use notch height settings
            notchHeight = Defaults[.notchHeight]
            if Defaults[.notchHeightMode] == .matchRealNotchSize {
                notchHeight = screen.safeAreaInsets.top
            } else if Defaults[.notchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        } else {
            // This is a display WITHOUT a notch - use non-notch height settings
            notchHeight = Defaults[.nonNotchHeight]
            if Defaults[.nonNotchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        }
    }

    return .init(width: notchWidth, height: notchHeight)
}


/// The call panel's size, as the user has set it.
///
/// A type rather than two `Defaults` reads at the call site, for one reason:
/// every read has to be clamped. The window behind the notch is created once at
/// `maxOpenNotchSize`, so a stored value outside `CallaPanelBounds` would draw a
/// panel the window cannot contain — and the symptom is a panel quietly cut off
/// at the bottom, which reads as a layout bug rather than a setting out of range.
enum CallaPanelSize {
    static var full: CGSize {
        NotchSizePreferences.size(.callExpanded)
    }

    static var compact: CGSize {
        NotchSizePreferences.size(.callCollapsed)
    }

    /// Puts both layouts back to the shipped numbers.
    static func reset() {
        NotchSizePreferences.reset(.callExpanded)
        NotchSizePreferences.reset(.callCollapsed)
    }

    static var isDefault: Bool {
        NotchSizePreferences.isDefault(.callExpanded)
            && NotchSizePreferences.isDefault(.callCollapsed)
    }
}

enum NotchSizePreferences {
    static func size(_ profile: NotchSizeProfile) -> CGSize {
        let stored: CGSize
        switch profile {
        case .normal:
            stored = CGSize(width: Defaults[.normalNotchWidth],
                            height: Defaults[.normalNotchHeight])
        case .callExpanded:
            stored = CGSize(width: Defaults[.callaPanelWidth],
                            height: Defaults[.callaPanelHeight])
        case .callCollapsed:
            // One width for a call, not one per layout.
            //
            // The two layouts had a width each, so collapsing the transcript
            // mid-call also changed how wide the notch was — the panel jumped
            // sideways every time the reader hid or showed the transcript, and
            // any auto layout change did it unprompted. Collapsing is about
            // *height*: it drops the transcript column. `callaCompactPanelWidth`
            // is left in Defaults unread rather than migrated; nothing writes it
            // any more.
            stored = CGSize(width: Defaults[.callaPanelWidth],
                            height: Defaults[.callaCompactPanelHeight])
        }
        return NotchResizeGeometry.clamped(stored, for: profile)
    }

    static func set(_ size: CGSize, for profile: NotchSizeProfile) {
        let clamped = NotchResizeGeometry.clamped(size, for: profile)
        switch profile {
        case .normal:
            Defaults[.normalNotchWidth] = Double(clamped.width)
            Defaults[.normalNotchHeight] = Double(clamped.height)
        case .callExpanded:
            Defaults[.callaPanelWidth] = Double(clamped.width)
            Defaults[.callaPanelHeight] = Double(clamped.height)
        case .callCollapsed:
            // Width is shared with the expanded layout — see `size(_:)`. Sizing
            // either call profile sets the one width a call has.
            Defaults[.callaPanelWidth] = Double(clamped.width)
            Defaults[.callaCompactPanelHeight] = Double(clamped.height)
        }
    }

    static func reset(_ profile: NotchSizeProfile) {
        set(profile.defaultSize, for: profile)
    }

    static func isDefault(_ profile: NotchSizeProfile) -> Bool {
        let size = size(profile)
        return size.width == profile.defaultSize.width
            && size.height == profile.defaultSize.height
    }
}
