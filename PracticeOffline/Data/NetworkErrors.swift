import Foundation

/// Why the latest favorites request failed. Port of LoadProblem in StatusBanner.tsx.
nonisolated enum LoadProblem: Sendable {
    case offline
    case failed
}

/// Port of src/data/networkErrors.ts. The Expo app guesses from the error's wording;
/// iOS gives exact error codes, so those are used instead.
nonisolated func isOfflineError(_ error: any Error) -> Bool {
    guard let urlError = error as? URLError else { return false }
    switch urlError.code {
    case .notConnectedToInternet, .networkConnectionLost, .timedOut,
         .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
         .dataNotAllowed, .internationalRoamingOff, .callIsActive:
        return true
    default:
        return false
    }
}
