//
//  UsageReportDTO.swift
//  CallaNotch
//
//  Shared Codable payload passed across the XPC boundary for CLI usage data.
//  This file is duplicated verbatim in callaNotch/XPCHelperClient/ and
//  CallaNotchXPCHelper/ — keep both copies identical.
//

import Foundation

struct UsageReportDTO: Codable, Equatable {
    enum Status: String, Codable {
        case ok
        case cliNotInstalled
        case notLoggedIn
        case error
    }

    struct Quota: Codable, Equatable {
        var percentRemaining: Double   // 0...100
        var resetText: String?         // "Resets in 4h 7m"
        var resetsAt: Date?            // for client-side countdown when parseable
    }

    var provider: String
    var status: Status
    var errorDescription: String?
    var session: Quota?
    var weekly: Quota?
    var capturedAt: Date
    var profileID: String? = nil
    var accountIdentity: String? = nil
    var gemini: QuotaGroup? = nil
    var claudeGPT: QuotaGroup? = nil

    struct QuotaGroup: Codable, Equatable {
        var session: Quota?
        var weekly: Quota?
    }

    var weeklyExhausted: Bool { weekly.map { $0.percentRemaining <= 0 } ?? false }

    /// Usable session allowance. An exhausted weekly quota blocks the session
    /// even when its independent five-hour bucket still has capacity.
    /// Keep the provider's raw quota and reset time intact for caching.
    var effectiveSession: Quota? {
        guard var quota = session else { return nil }
        if weeklyExhausted {
            quota.percentRemaining = 0
        }
        return quota
    }

    /// Shared JSON coders — `.secondsSince1970` dates on both sides of the XPC boundary.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}
