import AurralKit
import Foundation
import MagpieCore

extension AppModel {
    nonisolated static let discoverClaimsKeyPrefix = "magpie.discoverClaims."
    nonisolated static func discoverClaimsKey(_ scope: String) -> String { discoverClaimsKeyPrefix + scope }

    func discoverOwnerCaption(playlistId: String) -> String? { nil }
}
