import Foundation

/// Audible marketplaces, in the same order as the original application.
public enum Region: String, CaseIterable, Codable, Sendable, Identifiable, Comparable {
    case de, us, uk, fr, ca, it, au, `in`, jp, es, br

    public var id: String { rawValue }

    public var domain: String {
        switch self {
        case .de: "de"
        case .us: "com"
        case .uk: "co.uk"
        case .fr: "fr"
        case .ca: "ca"
        case .it: "it"
        case .au: "com.au"
        case .in: "in"
        case .jp: "co.jp"
        case .es: "es"
        case .br: "com.br"
        }
    }

    public var marketPlaceId: String {
        switch self {
        case .de: "AN7V1F1VY261K"
        case .us: "AF2M0KC94RCEA"
        case .uk: "A2I9A3Q2GNFNGQ"
        case .fr: "A2728XDNODOQ8T"
        case .ca: "A2CQZ5RBY40XE"
        case .it: "A2N7FU2W2BU2ZC"
        case .au: "AN7EY7DTAW63G"
        case .in: "AJO3FBRUE6J4S"
        case .jp: "A1QAP3MOU4173J"
        case .es: "ALMIKO4SZCSAR"
        case .br: "A10J1VAYUDTYRN"
        }
    }

    public var displayName: String {
        switch self {
        case .de: "Germany"
        case .us: "United States"
        case .uk: "United Kingdom"
        case .fr: "France"
        case .ca: "Canada"
        case .it: "Italy"
        case .au: "Australia"
        case .in: "India"
        case .jp: "Japan"
        case .es: "Spain"
        case .br: "Brazil"
        }
    }

    /// Only these marketplaces still support legacy (pre-Amazon) Audible accounts.
    public var allowsPreAmazonAccount: Bool {
        self == .de || self == .uk || self == .us
    }

    public static func < (lhs: Region, rhs: Region) -> Bool {
        (allCases.firstIndex(of: lhs) ?? 0) < (allCases.firstIndex(of: rhs) ?? 0)
    }
}
