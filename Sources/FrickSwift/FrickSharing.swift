import Foundation

/// Permission a {@link FrickInvitation} carries (and the corresponding
/// {@link FrickGrant} confers). The framework's authz flow treats `"write"`
/// as a superset of `"read"`: a write-grant satisfies an `object.read`
/// check, but a read-grant does not satisfy an `object.write` check.
public enum FrickSharingPermission: String, Codable, Sendable, Equatable {
    case read
    case write
}


/// Transient, single-use token an owner ships to a recipient. The
/// recipient calls `acceptInvitation(token:)` to redeem; the server marks
/// `redeemedAt` on the first successful accept and rejects every
/// subsequent attempt. Default lifetime is 14 days.
public struct FrickInvitation: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let tenantId: String
    public let ownerUserId: String
    public let recordType: String
    public let recordId: String
    public let permission: FrickSharingPermission
    public let token: String
    public let createdAt: String
    public let expiresAt: String
    public let redeemedAt: String?
    public let redeemedByUserId: String?

    public init(
        id: String,
        tenantId: String,
        ownerUserId: String,
        recordType: String,
        recordId: String,
        permission: FrickSharingPermission,
        token: String,
        createdAt: String,
        expiresAt: String,
        redeemedAt: String? = nil,
        redeemedByUserId: String? = nil
    ) {
        self.id = id
        self.tenantId = tenantId
        self.ownerUserId = ownerUserId
        self.recordType = recordType
        self.recordId = recordId
        self.permission = permission
        self.token = token
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.redeemedAt = redeemedAt
        self.redeemedByUserId = redeemedByUserId
    }
}


/// Durable "user U has permission P on record R" record. Created when a
/// recipient redeems an invitation; revoked when the owner calls
/// `revokeGrant(grantId:)`. The framework's authz flow only honours grants
/// where `revokedAt == nil`.
public struct FrickGrant: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let tenantId: String
    public let ownerUserId: String
    public let recordType: String
    public let recordId: String
    public let granteeUserId: String
    public let permission: FrickSharingPermission
    public let createdAt: String
    public let revokedAt: String?

    ///FIX: owner's login email, enriched server-side onto GET /share/grants for the
    /// RangerCRM "shared from <email>" cell. Optional — absent on older servers / unknown owners.
    public let ownerEmail: String?

    ///FIX: grantee's login email, enriched server-side onto GET /share/grants for the
    /// owner-side "Shared With" participants list. Optional — absent on older servers /
    /// unknown grantees.
    public let granteeEmail: String?

    ///FIX: display names, enriched server-side onto GET /share/grants — the user's
    /// RangerCRM Profile first/last name, falling back to the auth account's
    /// displayName. Optional — absent on older servers / unknown users. UIs show
    /// `name ?? email ?? userId`.
    public let ownerName: String?
    public let granteeName: String?

    public init(
        id: String,
        tenantId: String,
        ownerUserId: String,
        recordType: String,
        recordId: String,
        granteeUserId: String,
        permission: FrickSharingPermission,
        createdAt: String,
        revokedAt: String? = nil,
        ownerEmail: String? = nil,
        granteeEmail: String? = nil,
        ownerName: String? = nil,
        granteeName: String? = nil
    ) {
        self.id = id
        self.tenantId = tenantId
        self.ownerUserId = ownerUserId
        self.recordType = recordType
        self.recordId = recordId
        self.granteeUserId = granteeUserId
        self.permission = permission
        self.createdAt = createdAt
        self.revokedAt = revokedAt
        self.ownerEmail = ownerEmail
        self.granteeEmail = granteeEmail
        self.ownerName = ownerName
        self.granteeName = granteeName
    }
}


struct CreateInvitationBody: Encodable {
    let recordType: String
    let recordId: String
    let permission: FrickSharingPermission
    let expiresInSeconds: Int?
}


struct CreateInvitationEnvelope: Decodable {
    let invitation: FrickInvitation
}


struct AcceptInvitationBody: Encodable {
    let token: String
}


struct AcceptInvitationEnvelope: Decodable {
    let grant: FrickGrant
}


struct ListGrantsEnvelope: Decodable {
    let grants: [FrickGrant]
}


struct RevokeGrantEnvelope: Decodable {
    let grant: FrickGrant
}


// MARK: - RangerCRM share-notification additions


///FIX: body for registerDevice(token:platform:environment:) → POST /push/registrations
struct RegisterDeviceBody: Encodable {
    let deviceId: String
    let platform: String
    let token: String
    let environment: String
}


///FIX: body for declineInvitation(token:) → POST /share/decline
struct DeclineInvitationBody: Encodable {
    let token: String
}


struct DeclineInvitationEnvelope: Decodable {
    let invitation: FrickInvitation
}


///FIX: read-only preview of an invitation (from `invitationPreview(token:)`),
/// rendering the receiver's Accept/Decline prompt + invitations inbox WITHOUT
/// redeeming. `status` ∈ "pending" | "declined" | "redeemed" | "expired".
public struct FrickInvitationPreview: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let ownerUserId: String
    public let recordType: String
    public let recordId: String
    public let permission: FrickSharingPermission
    public let createdAt: String
    public let expiresAt: String
    public let status: String

    public init(
        id: String,
        ownerUserId: String,
        recordType: String,
        recordId: String,
        permission: FrickSharingPermission,
        createdAt: String,
        expiresAt: String,
        status: String
    ) {
        self.id = id
        self.ownerUserId = ownerUserId
        self.recordType = recordType
        self.recordId = recordId
        self.permission = permission
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.status = status
    }
}


struct InvitationPreviewEnvelope: Decodable {
    let invitation: FrickInvitationPreview
}
