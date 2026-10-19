//
//  ShelfPane.swift
//  callaNotch
//

import Defaults
import SwiftUI

struct Shelf: View {
    @ObservedObject var coordinator = CallaViewCoordinator.shared

    
    @Default(.shelfTapToOpen) var shelfTapToOpen: Bool
    @Default(.expandedDragDetection) var expandedDragDetection: Bool
    
    init() {
        QuickShareService.shared.refreshDiscovery()
        KDEConnectService.shared.refreshDiscovery()
    }
    
    @Default(.callaShelf) private var callaShelf
    @Default(.openShelfByDefault) private var openShelfByDefault
    @Default(.copyOnDrag) private var copyOnDrag
    @Default(.autoRemoveShelfItems) private var autoRemoveShelfItems
    @Default(.shelfRemoveAfterSend) private var shelfRemoveAfterSend

    var body: some View {
        SettingsPane(.shelf, isOn: $callaShelf) {
            SettingCard("Shelf") {
                VStack(spacing: 12) {
                    SettingRow("Open when it has items") {
                        Toggle("", isOn: $openShelfByDefault).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Always show the Shelf tab",
                               detail: "Off hides it in the notch until the shelf has something in it.") {
                        Toggle("", isOn: $coordinator.alwaysShowTabs).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Expanded drag target",
                               detail: "A larger area around the notch accepts a drop.") {
                        Toggle("", isOn: $expandedDragDetection).labelsHidden().toggleStyle(.switch)
                    }
                }
            }

            .settingsAnchor("shelf.shelf")

            SettingCard("Dragging") {
                VStack(spacing: 12) {
                    SettingRow("Copy instead of move") {
                        Toggle("", isOn: $copyOnDrag).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Remove after dragging out") {
                        Toggle("", isOn: $autoRemoveShelfItems).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Remove after sending") {
                        Toggle("", isOn: $shelfRemoveAfterSend).labelsHidden().toggleStyle(.switch)
                    }
                }
            }

            .settingsAnchor("shelf.dragging")

            SettingsEmbedded(.localSend) { LocalSendPane() }
            SettingsEmbedded(.kdeConnect) { KDEConnectPane() }
        }
        .onChange(of: expandedDragDetection) {
            NotificationCenter.default.post(
                name: Notification.Name.expandedDragDetectionChanged, object: nil)
        }
    }


}
