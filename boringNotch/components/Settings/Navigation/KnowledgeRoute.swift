//
//  KnowledgeRoute.swift
//  boringNotch
//
//  Part of the route model: it is the payload of `SettingsPage`'s one
//  depth-two case, so it sits with the other route types rather than in the
//  pane that used to own a NavigationStack of its own.
//

import Foundation

/// Where a piece of knowledge lives, as a navigable destination.
enum KnowledgeRoute: Hashable {
    case event(id: String)
    /// The Wave interview. Its own case rather than `.event`, because it has no
    /// EventKit row to look up — the identity is fixed in `WaveInterview` — and
    /// everything the event branch does starts by finding that row.
    case waveInterview
    case everyCall
    case byPersona
    case orphaned
}
