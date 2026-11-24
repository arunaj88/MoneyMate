import 'dart:convert';

import 'package:money_mate/models/app_user.dart';

/// A member's role in a household.
enum HouseholdRole {
  owner,
  member;

  String get label => this == HouseholdRole.owner ? 'Owner' : 'Member';

  static HouseholdRole fromName(Object? value) =>
      value == HouseholdRole.owner.name
      ? HouseholdRole.owner
      : HouseholdRole.member;
}

/// Whether a member currently has access to the household.
enum MembershipStatus {
  active,
  removed,
  left;

  String get label => switch (this) {
    MembershipStatus.active => 'Active',
    MembershipStatus.removed => 'Removed',
    MembershipStatus.left => 'Left',
  };

  static MembershipStatus fromName(Object? value) =>
      MembershipStatus.values.firstWhere(
        (s) => s.name == value,
        orElse: () => MembershipStatus.removed,
      );
}

/// Lifecycle of an invitation. "Expired" is also derived on the device from
/// [HouseholdInvitation.expiresAt] for pending invitations.
enum InvitationStatus {
  pending,
  accepted,
  expired,
  revoked;

  String get label => switch (this) {
    InvitationStatus.pending => 'Pending',
    InvitationStatus.accepted => 'Accepted',
    InvitationStatus.expired => 'Expired',
    InvitationStatus.revoked => 'Revoked',
  };

  static InvitationStatus fromName(Object? value) =>
      InvitationStatus.values.firstWhere(
        (s) => s.name == value,
        orElse: () => InvitationStatus.revoked,
      );
}

DateTime? _date(Object? value) => switch (value) {
  final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
  final DateTime d => d,
  _ => null,
};

/// A household that shares transactions and budgets.
class Household {
  const Household({
    required this.id,
    required this.name,
    required this.ownerUid,
    this.createdAt,
  });

  final String id;
  final String name;
  final String ownerUid;
  final DateTime? createdAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'ownerUid': ownerUid,
    'createdAt': createdAt?.millisecondsSinceEpoch,
  };

  static Household? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    final owner = json['ownerUid'];
    if (id is! String || name is! String || owner is! String) return null;
    return Household(
      id: id,
      name: name,
      ownerUid: owner,
      createdAt: _date(json['createdAt']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Household &&
      other.id == id &&
      other.name == name &&
      other.ownerUid == ownerUid;

  @override
  int get hashCode => Object.hash(id, name, ownerUid);
}

/// A person in a household.
class HouseholdMember {
  const HouseholdMember({
    required this.uid,
    required this.role,
    required this.status,
    this.displayName,
    this.email,
    this.photoUrl,
    this.joinedAt,
  });

  final String uid;
  final HouseholdRole role;
  final MembershipStatus status;
  final String? displayName;
  final String? email;
  final String? photoUrl;
  final DateTime? joinedAt;

  bool get isOwner => role == HouseholdRole.owner;
  bool get isActive => status == MembershipStatus.active;

  /// Profile in the shape the avatar widget expects.
  AppUser get profile => AppUser(
    uid: uid,
    email: email,
    displayName: displayName,
    photoUrl: photoUrl,
  );

  String get name => profile.name;

  Map<String, Object?> toJson() => {
    'uid': uid,
    'role': role.name,
    'status': status.name,
    'displayName': displayName,
    'email': email,
    'photoUrl': photoUrl,
    'joinedAt': joinedAt?.millisecondsSinceEpoch,
  };

  static HouseholdMember? fromJson(Object? json) {
    if (json is! Map || json['uid'] is! String) return null;
    return HouseholdMember(
      uid: json['uid'] as String,
      role: HouseholdRole.fromName(json['role']),
      status: MembershipStatus.fromName(json['status']),
      displayName: json['displayName'] as String?,
      email: json['email'] as String?,
      photoUrl: json['photoUrl'] as String?,
      joinedAt: _date(json['joinedAt']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HouseholdMember &&
      other.uid == uid &&
      other.role == role &&
      other.status == status &&
      other.displayName == displayName &&
      other.email == email &&
      other.photoUrl == photoUrl;

  @override
  int get hashCode =>
      Object.hash(uid, role, status, displayName, email, photoUrl);
}

/// An invitation to join a household (visible to the owner only).
class HouseholdInvitation {
  const HouseholdInvitation({
    required this.id,
    required this.status,
    required this.expiresAt,
    this.code,
    this.createdAt,
    this.invitedEmail,
    this.acceptedBy,
    this.acceptedByName,
  });

  final String id;
  final InvitationStatus status;
  final DateTime expiresAt;

  /// The one-time code, so the owner can share it again.
  final String? code;
  final DateTime? createdAt;

  /// When set, only an account with this email can accept it.
  final String? invitedEmail;
  final String? acceptedBy;
  final String? acceptedByName;

  /// Status at [now]: a pending invitation past its expiry is expired.
  InvitationStatus statusAt(DateTime now) =>
      status == InvitationStatus.pending && !now.isBefore(expiresAt)
      ? InvitationStatus.expired
      : status;
}

/// Result of creating an invitation.
class InvitationCode {
  const InvitationCode({
    required this.invitationId,
    required this.code,
    required this.expiresAt,
  });

  final String invitationId;
  final String code;
  final DateTime expiresAt;

  /// Code split into two groups for reading aloud, e.g. "K7QM2-XRP9D".
  String get formatted => formatInvitationCode(code);
}

/// What an invitation code leads to, shown before the user accepts it.
class InvitationPreview {
  const InvitationPreview({
    required this.householdName,
    required this.expiresAt,
    this.invitedByName,
  });

  final String householdName;
  final String? invitedByName;
  final DateTime expiresAt;
}

/// Groups an invitation code in fives for display.
String formatInvitationCode(String code) {
  final clean = normalizeInvitationCode(code);
  if (clean.length <= 5) return clean;
  return '${clean.substring(0, 5)}-${clean.substring(5)}';
}

/// Uppercases and strips spaces / dashes from a typed code.
String normalizeInvitationCode(String input) =>
    input.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

/// The user's household as last seen online, kept on the device so shared
/// transactions can be recorded and shown offline.
class HouseholdCache {
  const HouseholdCache({required this.household, required this.members});

  final Household household;
  final List<HouseholdMember> members;

  String toJson() => jsonEncode({
    'household': household.toJson(),
    'members': [for (final m in members) m.toJson()],
  });

  static HouseholdCache? fromJson(String? source) {
    if (source == null || source.isEmpty) return null;
    try {
      final map = jsonDecode(source);
      if (map is! Map) return null;
      final household = Household.fromJson(map['household']);
      if (household == null) return null;
      final members = <HouseholdMember>[
        for (final m in (map['members'] as List? ?? const []))
          if (HouseholdMember.fromJson(m) case final member?) member,
      ];
      return HouseholdCache(household: household, members: members);
    } on FormatException {
      return null;
    }
  }
}
