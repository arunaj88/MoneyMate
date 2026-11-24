import 'package:flutter/material.dart';

/// What a savings goal is for. [other] lets the user type their own purpose.
enum SavingsPurpose {
  investment('Investment', Icons.trending_up_rounded, Color(0xFF2563EB)),
  trip('Trip / Vacation', Icons.flight_takeoff_rounded, Color(0xFF0EA5E9)),
  gold('Gold', Icons.diamond_outlined, Color(0xFFD97706)),
  emergency(
    'Emergency Fund',
    Icons.health_and_safety_outlined,
    Color(0xFFDC2626),
  ),
  vehicle('Vehicle', Icons.directions_car_filled_outlined, Color(0xFF7C3AED)),
  house('House', Icons.home_outlined, Color(0xFF0F766E)),
  education('Education', Icons.school_outlined, Color(0xFF16A34A)),
  wedding('Wedding', Icons.favorite_border_rounded, Color(0xFFDB2777)),
  other('Other', Icons.savings_outlined, Color(0xFF64748B));

  const SavingsPurpose(this.label, this.icon, this.color);

  final String label;
  final IconData icon;
  final Color color;

  /// Unknown values (e.g. written by a newer app version) become [other].
  static SavingsPurpose fromName(String? value) => SavingsPurpose.values
      .firstWhere((p) => p.name == value, orElse: () => SavingsPurpose.other);
}

/// Who a savings goal belongs to. The three kinds are kept financially
/// separate: their totals are never added into one another's balances.
enum SavingsOwnership {
  /// The signed-in user's own goal (`users/{uid}/savingsGoals`). Money put
  /// in reduces their personal available balance.
  personal('Personal', Icons.person_outline_rounded),

  /// Belongs to the user's MoneyMate household
  /// (`households/{householdId}/savingsGoals`); every active household
  /// member can see it and contribute. Money put in reduces the household's
  /// available balance.
  household('Household', Icons.home_outlined),

  /// An independent goal shared with invited MoneyMate users
  /// (`sharedGoals/{goalId}`), unrelated to households. Contributions are
  /// amounts each member records as contributed; they do not change
  /// anyone's MoneyMate balance.
  shared('Shared', Icons.groups_outlined);

  const SavingsOwnership(this.label, this.icon);

  final String label;
  final IconData icon;

  /// Rows written before ownership existed are personal.
  static SavingsOwnership fromName(String? value) =>
      SavingsOwnership.values.firstWhere(
        (o) => o.name == value,
        orElse: () => SavingsOwnership.personal,
      );
}

/// Lifecycle of a savings goal.
enum SavingsGoalStatus {
  active('Active'),
  paused('Paused'),
  completed('Completed');

  const SavingsGoalStatus(this.label);

  final String label;

  static SavingsGoalStatus fromName(String? value) =>
      SavingsGoalStatus.values.firstWhere(
        (s) => s.name == value,
        orElse: () => SavingsGoalStatus.active,
      );
}

/// Money moved into a goal ([deposit]) or back out of it ([withdrawal]).
///
/// Neither is income or an expense: both are transfers between available
/// money and a goal, so they never appear in transaction totals, reports
/// or budgets.
enum SavingsEntryType {
  deposit('Added'),
  withdrawal('Withdrawn');

  const SavingsEntryType(this.label);

  final String label;

  static SavingsEntryType fromName(String value) =>
      SavingsEntryType.values.firstWhere(
        (t) => t.name == value,
        orElse: () => throw FormatException('Unknown savings entry: $value'),
      );
}

/// Limits shared by the form validation, the database and Firestore rules.
class SavingsLimits {
  SavingsLimits._();

  static const int nameMaxLength = 60;
  static const int purposeMaxLength = 40;
  static const int notesMaxLength = 300;
  static const int entryNoteMaxLength = 200;

  /// Days an invitation to a shared goal stays valid.
  static const int invitationDays = 14;
}

/// A savings goal.
///
/// The saved amount is not stored locally: it is the sum of the goal's
/// entries ([savedMinor], filled in when loaded), so every device arrives at
/// the same balance from the same history. (Household and shared goals also
/// keep a running total in the cloud, which security rules keep equal to
/// the entries.)
class SavingsGoal {
  const SavingsGoal({
    required this.id,
    required this.name,
    required this.purpose,
    this.customPurpose = '',
    required this.targetMinor,
    this.targetDate,
    this.notes = '',
    this.status = SavingsGoalStatus.active,
    required this.createdAt,
    required this.updatedAt,
    this.completedAt,
    this.ownership = SavingsOwnership.personal,
    this.householdId,
    this.ownerUid,
    this.createdBy,
    this.createdByName,
    this.updatedBy,
    this.savedMinor = 0,
    this.firstEntryDate,
    this.myContributionMinor = 0,
    this.memberCount = 0,
    this.pendingEntries = 0,
  }) : assert(targetMinor > 0, 'Target must be greater than zero'),
       assert(
         (ownership == SavingsOwnership.household) == (householdId != null),
         'Household goals need a household; others must not have one',
       );

  final String id;
  final String name;
  final SavingsPurpose purpose;

  /// The user's own purpose when [purpose] is [SavingsPurpose.other].
  final String customPurpose;
  final int targetMinor;
  final DateTime? targetDate;
  final String notes;
  final SavingsGoalStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;

  final SavingsOwnership ownership;

  /// Household of a household goal; null otherwise.
  final String? householdId;

  /// Owner of a shared goal (its creator); null for older personal goals.
  final String? ownerUid;
  final String? createdBy;
  final String? createdByName;

  /// Who last changed the goal's details.
  final String? updatedBy;

  /// Deposits minus withdrawals (derived, not persisted).
  final int savedMinor;

  /// Date of the earliest entry, used to project a completion date
  /// (derived).
  final DateTime? firstEntryDate;

  /// What the signed-in user put in minus what they took out (derived).
  final int myContributionMinor;

  /// Active members of a shared goal (derived; 0 for other kinds).
  final int memberCount;

  /// Contributions recorded on this device and not yet in the cloud
  /// (derived).
  final int pendingEntries;

  bool get isActive => status == SavingsGoalStatus.active;
  bool get isPaused => status == SavingsGoalStatus.paused;
  bool get isCompleted => status == SavingsGoalStatus.completed;

  bool get isPersonal => ownership == SavingsOwnership.personal;
  bool get isHousehold => ownership == SavingsOwnership.household;
  bool get isShared => ownership == SavingsOwnership.shared;

  /// Household and shared goals: their balance is shared with other people,
  /// so withdrawals are checked against the cloud first.
  bool get isCollaborative => !isPersonal;

  /// Amount still needed to reach the target (never negative).
  int get remainingMinor =>
      savedMinor >= targetMinor ? 0 : targetMinor - savedMinor;

  bool get targetReached => savedMinor >= targetMinor;

  /// 0..1 (capped).
  double get progress =>
      targetMinor <= 0 ? 0 : (savedMinor / targetMinor).clamp(0.0, 1.0);

  /// Whole percent, not capped (a goal can be over-saved).
  int get percent => targetMinor <= 0
      ? 0
      : (savedMinor * 100 / targetMinor).floor().clamp(0, 999);

  String get purposeLabel =>
      purpose == SavingsPurpose.other && customPurpose.trim().isNotEmpty
      ? customPurpose.trim()
      : purpose.label;

  SavingsGoal copyWith({
    String? name,
    SavingsPurpose? purpose,
    String? customPurpose,
    int? targetMinor,
    DateTime? Function()? targetDate,
    String? notes,
    SavingsGoalStatus? status,
    DateTime? updatedAt,
    DateTime? Function()? completedAt,
    String? updatedBy,
    int? savedMinor,
    DateTime? Function()? firstEntryDate,
    int? myContributionMinor,
    int? memberCount,
    int? pendingEntries,
  }) => SavingsGoal(
    id: id,
    name: name ?? this.name,
    purpose: purpose ?? this.purpose,
    customPurpose: customPurpose ?? this.customPurpose,
    targetMinor: targetMinor ?? this.targetMinor,
    targetDate: targetDate != null ? targetDate() : this.targetDate,
    notes: notes ?? this.notes,
    status: status ?? this.status,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    completedAt: completedAt != null ? completedAt() : this.completedAt,
    ownership: ownership,
    householdId: householdId,
    ownerUid: ownerUid,
    createdBy: createdBy,
    createdByName: createdByName,
    updatedBy: updatedBy ?? this.updatedBy,
    savedMinor: savedMinor ?? this.savedMinor,
    firstEntryDate: firstEntryDate != null
        ? firstEntryDate()
        : this.firstEntryDate,
    myContributionMinor: myContributionMinor ?? this.myContributionMinor,
    memberCount: memberCount ?? this.memberCount,
    pendingEntries: pendingEntries ?? this.pendingEntries,
  );

  /// Stored columns (derived fields excluded).
  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'purpose': purpose.name,
    'custom_purpose': customPurpose,
    'target_minor': targetMinor,
    'target_date': targetDate?.millisecondsSinceEpoch,
    'notes': notes,
    'status': status.name,
    'created_at': createdAt.millisecondsSinceEpoch,
    'updated_at': updatedAt.millisecondsSinceEpoch,
    'completed_at': completedAt?.millisecondsSinceEpoch,
    'ownership': ownership.name,
    'household_id': householdId ?? '',
    'owner_uid': ownerUid,
    'created_by': createdBy,
    'created_by_name': createdByName,
    'updated_by': updatedBy,
  };

  factory SavingsGoal.fromMap(Map<String, Object?> map) {
    final target = map['target_minor'];
    final name = map['name'];
    if (target is! int || target <= 0) {
      throw const FormatException('Savings goal: bad target');
    }
    if (name is! String || name.trim().isEmpty) {
      throw const FormatException('Savings goal: bad name');
    }
    DateTime? date(String key) => map[key] is int
        ? DateTime.fromMillisecondsSinceEpoch(map[key]! as int)
        : null;
    final ownership = SavingsOwnership.fromName(map['ownership'] as String?);
    final household = map['household_id'];
    if (ownership == SavingsOwnership.household &&
        (household is! String || household.isEmpty)) {
      throw const FormatException('Savings goal: household missing');
    }
    return SavingsGoal(
      id: map['id']! as String,
      name: name,
      purpose: SavingsPurpose.fromName(map['purpose'] as String?),
      customPurpose: (map['custom_purpose'] as String?) ?? '',
      targetMinor: target,
      targetDate: date('target_date'),
      notes: (map['notes'] as String?) ?? '',
      status: SavingsGoalStatus.fromName(map['status'] as String?),
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at']! as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at']! as int),
      completedAt: date('completed_at'),
      ownership: ownership,
      householdId: ownership == SavingsOwnership.household
          ? household! as String
          : null,
      ownerUid: map['owner_uid'] as String?,
      createdBy: map['created_by'] as String?,
      createdByName: map['created_by_name'] as String?,
      updatedBy: map['updated_by'] as String?,
      savedMinor: (map['saved_minor'] as int?) ?? 0,
      firstEntryDate: date('first_entry_date'),
      myContributionMinor: (map['my_saved_minor'] as int?) ?? 0,
      memberCount: (map['member_count'] as int?) ?? 0,
      pendingEntries: (map['pending_entries'] as int?) ?? 0,
    );
  }

  /// Fields of the Firestore document (id / updatedAt / deleted are added by
  /// the store). The running total of household and shared goals is never
  /// part of it: only the entry transactions change that.
  Map<String, Object?> toCloudMap() => {
    'name': name,
    'purpose': purpose.name,
    'customPurpose': customPurpose,
    'targetMinor': targetMinor,
    'targetDate': targetDate?.millisecondsSinceEpoch,
    'notes': notes,
    'status': status.name,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'completedAt': completedAt?.millisecondsSinceEpoch,
    'ownership': ownership.name,
    'householdId': ?householdId,
    'ownerUid': ?ownerUid,
    'createdBy': ?createdBy,
    'createdByName': ?createdByName,
    'updatedBy': ?updatedBy,
  };

  /// Parses a Firestore document; null when it is not a valid goal. The
  /// ownership comes from where the document was read, not from its fields.
  static SavingsGoal? fromCloudMap(
    String id,
    Map<String, Object?> data,
    int updatedAtMs, {
    SavingsOwnership ownership = SavingsOwnership.personal,
    String? householdId,
  }) {
    final name = data['name'];
    final target = data['targetMinor'];
    final createdAt = data['createdAt'];
    if (name is! String || name.trim().isEmpty) return null;
    if (target is! int || target <= 0 || createdAt is! int) return null;
    if ((ownership == SavingsOwnership.household) != (householdId != null)) {
      return null;
    }
    DateTime? date(String key) => data[key] is int
        ? DateTime.fromMillisecondsSinceEpoch(data[key]! as int)
        : null;
    return SavingsGoal(
      id: id,
      name: name,
      purpose: SavingsPurpose.fromName(data['purpose'] as String?),
      customPurpose: (data['customPurpose'] as String?) ?? '',
      targetMinor: target,
      targetDate: date('targetDate'),
      notes: (data['notes'] as String?) ?? '',
      status: SavingsGoalStatus.fromName(data['status'] as String?),
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAtMs),
      completedAt: date('completedAt'),
      ownership: ownership,
      householdId: householdId,
      ownerUid: data['ownerUid'] as String?,
      createdBy: data['createdBy'] as String?,
      createdByName: data['createdByName'] as String?,
      updatedBy: data['updatedBy'] as String?,
    );
  }

  Map<String, Object?> toJson() => toMap();

  factory SavingsGoal.fromJson(Map<String, dynamic> json) =>
      SavingsGoal.fromMap(json);
}

/// One contribution to or withdrawal from a goal, attributed to the user
/// who made it. Household and shared entries are never edited or deleted:
/// a mistake is corrected with an opposite entry. Personal entries can be
/// deleted.
class SavingsEntry {
  const SavingsEntry({
    required this.id,
    required this.goalId,
    required this.type,
    required this.amountMinor,
    required this.date,
    this.note = '',
    required this.createdAt,
    required this.updatedAt,
    this.userUid,
    this.userName,
    this.isPending = false,
  }) : assert(amountMinor > 0, 'Amount must be greater than zero');

  final String id;
  final String goalId;
  final SavingsEntryType type;
  final int amountMinor;
  final DateTime date;
  final String note;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Who recorded it (null for personal entries made before sign-in).
  final String? userUid;

  /// Their name when it was recorded, for showing it offline.
  final String? userName;

  /// Recorded on this device and not yet confirmed by the cloud (derived).
  final bool isPending;

  bool get isDeposit => type == SavingsEntryType.deposit;

  /// Positive for deposits, negative for withdrawals.
  int get signedMinor => isDeposit ? amountMinor : -amountMinor;

  Map<String, Object?> toMap() => {
    'id': id,
    'goal_id': goalId,
    'type': type.name,
    'amount_minor': amountMinor,
    'date': date.millisecondsSinceEpoch,
    'note': note,
    'created_at': createdAt.millisecondsSinceEpoch,
    'updated_at': updatedAt.millisecondsSinceEpoch,
    'user_uid': userUid,
    'user_name': userName,
  };

  factory SavingsEntry.fromMap(Map<String, Object?> map) {
    final amount = map['amount_minor'];
    if (amount is! int || amount <= 0) {
      throw const FormatException('Savings entry: bad amount');
    }
    return SavingsEntry(
      id: map['id']! as String,
      goalId: map['goal_id']! as String,
      type: SavingsEntryType.fromName(map['type']! as String),
      amountMinor: amount,
      date: DateTime.fromMillisecondsSinceEpoch(map['date']! as int),
      note: (map['note'] as String?) ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at']! as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at']! as int),
      userUid: map['user_uid'] as String?,
      userName: map['user_name'] as String?,
      isPending: map['sync_status'] == 'pending',
    );
  }

  Map<String, Object?> toCloudMap() => {
    'goalId': goalId,
    'type': type.name,
    'amountMinor': amountMinor,
    'date': date.millisecondsSinceEpoch,
    'note': note,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'userUid': ?userUid,
    'userName': ?userName,
  };

  static SavingsEntry? fromCloudMap(
    String id,
    Map<String, Object?> data,
    int updatedAtMs,
  ) {
    final goalId = data['goalId'];
    final type = data['type'];
    final amount = data['amountMinor'];
    final date = data['date'];
    final createdAt = data['createdAt'];
    if (goalId is! String || goalId.isEmpty || type is! String) return null;
    if (amount is! int || amount <= 0 || date is! int || createdAt is! int) {
      return null;
    }
    final SavingsEntryType parsed;
    try {
      parsed = SavingsEntryType.fromName(type);
    } on FormatException {
      return null;
    }
    return SavingsEntry(
      id: id,
      goalId: goalId,
      type: parsed,
      amountMinor: amount,
      date: DateTime.fromMillisecondsSinceEpoch(date),
      note: (data['note'] as String?) ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAtMs),
      userUid: data['userUid'] as String?,
      userName: data['userName'] as String?,
    );
  }

  Map<String, Object?> toJson() => toMap();

  factory SavingsEntry.fromJson(Map<String, dynamic> json) =>
      SavingsEntry.fromMap(json);
}

/// Role in an independent shared goal.
enum SharedGoalRole {
  owner('Owner'),
  member('Member');

  const SharedGoalRole(this.label);

  final String label;

  static SharedGoalRole fromName(Object? value) =>
      value == 'owner' ? SharedGoalRole.owner : SharedGoalRole.member;
}

/// Whether a member still has access to a shared goal.
enum SharedMemberStatus {
  active('Active'),
  removed('Removed'),
  left('Left');

  const SharedMemberStatus(this.label);

  final String label;

  static SharedMemberStatus fromName(Object? value) =>
      SharedMemberStatus.values.firstWhere(
        (s) => s.name == value,
        orElse: () => SharedMemberStatus.removed,
      );
}

/// A user's membership of an independent shared goal
/// (`sharedGoals/{goalId}/members/{uid}`).
class SharedGoalMember {
  const SharedGoalMember({
    required this.goalId,
    required this.uid,
    required this.role,
    this.status = SharedMemberStatus.active,
    this.canContribute = true,
    this.canWithdraw = false,
    this.displayName,
    this.email,
    this.joinedAt,
  });

  final String goalId;
  final String uid;
  final SharedGoalRole role;
  final SharedMemberStatus status;
  final bool canContribute;

  /// Owners can always withdraw; members only when granted.
  final bool canWithdraw;
  final String? displayName;
  final String? email;
  final DateTime? joinedAt;

  bool get isOwner => role == SharedGoalRole.owner;
  bool get isActive => status == SharedMemberStatus.active;

  /// Owner, or a member the owner allowed to withdraw.
  bool get mayWithdraw => isActive && (isOwner || canWithdraw);
  bool get mayContribute => isActive && (isOwner || canContribute);

  String get name {
    final n = displayName?.trim() ?? '';
    if (n.isNotEmpty) return n;
    final local = email?.split('@').first.trim() ?? '';
    return local.isEmpty ? 'Member' : local;
  }

  SharedGoalMember copyWith({
    SharedMemberStatus? status,
    bool? canContribute,
    bool? canWithdraw,
  }) => SharedGoalMember(
    goalId: goalId,
    uid: uid,
    role: role,
    status: status ?? this.status,
    canContribute: canContribute ?? this.canContribute,
    canWithdraw: canWithdraw ?? this.canWithdraw,
    displayName: displayName,
    email: email,
    joinedAt: joinedAt,
  );

  Map<String, Object?> toMap() => {
    'goal_id': goalId,
    'uid': uid,
    'role': role.name,
    'status': status.name,
    'can_contribute': canContribute ? 1 : 0,
    'can_withdraw': canWithdraw ? 1 : 0,
    'display_name': displayName,
    'email': email,
    'joined_at': joinedAt?.millisecondsSinceEpoch,
  };

  factory SharedGoalMember.fromMap(Map<String, Object?> map) =>
      SharedGoalMember(
        goalId: map['goal_id']! as String,
        uid: map['uid']! as String,
        role: SharedGoalRole.fromName(map['role']),
        status: SharedMemberStatus.fromName(map['status']),
        canContribute: map['can_contribute'] != 0,
        canWithdraw: map['can_withdraw'] == 1,
        displayName: map['display_name'] as String?,
        email: map['email'] as String?,
        joinedAt: map['joined_at'] is int
            ? DateTime.fromMillisecondsSinceEpoch(map['joined_at']! as int)
            : null,
      );

  Map<String, Object?> toCloudMap() => {
    'uid': uid,
    'role': role.name,
    'status': status.name,
    'canContribute': canContribute,
    'canWithdraw': canWithdraw,
    'displayName': displayName,
    'email': email,
    'joinedAt': joinedAt?.millisecondsSinceEpoch,
  };

  static SharedGoalMember? fromCloudMap(
    String goalId,
    String uid,
    Map<String, Object?> data,
  ) {
    if (data['role'] is! String || data['status'] is! String) return null;
    final joined = data['joinedAt'];
    return SharedGoalMember(
      goalId: goalId,
      uid: uid,
      role: SharedGoalRole.fromName(data['role']),
      status: SharedMemberStatus.fromName(data['status']),
      canContribute: data['canContribute'] != false,
      canWithdraw: data['canWithdraw'] == true,
      displayName: data['displayName'] as String?,
      email: data['email'] as String?,
      joinedAt: joined is int
          ? DateTime.fromMillisecondsSinceEpoch(joined)
          : null,
    );
  }
}

/// Lifecycle of an invitation to a shared goal. "Expired" is derived on
/// the device for pending invitations past [SharedGoalInvitation.expiresAt].
enum SharedInvitationStatus {
  pending('Pending'),
  accepted('Accepted'),
  rejected('Rejected'),
  revoked('Revoked'),
  expired('Expired');

  const SharedInvitationStatus(this.label);

  final String label;

  static SharedInvitationStatus fromName(Object? value) =>
      SharedInvitationStatus.values.firstWhere(
        (s) => s.name == value,
        orElse: () => SharedInvitationStatus.revoked,
      );
}

/// An invitation to an independent shared goal
/// (`sharedGoalInvitations/{code}`).
///
/// The document ID is the secret invitation code: whoever has it can open
/// the invitation. An invitation with [invitedEmail] can only be accepted
/// by an account signed in with that email; one without it (a link / code
/// invitation) by the first signed-in user who uses the code. Either way it
/// can be used once.
class SharedGoalInvitation {
  const SharedGoalInvitation({
    required this.code,
    required this.goalId,
    required this.goalName,
    this.invitedEmail,
    required this.invitedBy,
    this.invitedByName,
    this.status = SharedInvitationStatus.pending,
    required this.createdAt,
    required this.expiresAt,
    this.acceptedBy,
    this.acceptedByName,
  });

  final String code;
  final String goalId;
  final String goalName;
  final String? invitedEmail;
  final String invitedBy;
  final String? invitedByName;
  final SharedInvitationStatus status;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String? acceptedBy;
  final String? acceptedByName;

  /// [status], with pending invitations past their expiry shown as expired.
  SharedInvitationStatus statusAt(DateTime now) =>
      status == SharedInvitationStatus.pending && !now.isBefore(expiresAt)
      ? SharedInvitationStatus.expired
      : status;

  bool isOpenAt(DateTime now) =>
      statusAt(now) == SharedInvitationStatus.pending;

  /// Grouped for reading out or typing, e.g. "ABCD-EFGH-JKMN-PQRS".
  String get formattedCode => formatSharedGoalCode(code);

  Map<String, Object?> toMap() => {
    'id': code,
    'goal_id': goalId,
    'goal_name': goalName,
    'invited_email': invitedEmail,
    'invited_by': invitedBy,
    'invited_by_name': invitedByName,
    'status': status.name,
    'created_at': createdAt.millisecondsSinceEpoch,
    'expires_at': expiresAt.millisecondsSinceEpoch,
    'accepted_by': acceptedBy,
    'accepted_by_name': acceptedByName,
  };

  factory SharedGoalInvitation.fromMap(
    Map<String, Object?> map,
  ) => SharedGoalInvitation(
    code: map['id']! as String,
    goalId: map['goal_id']! as String,
    goalName: map['goal_name']! as String,
    invitedEmail: map['invited_email'] as String?,
    invitedBy: map['invited_by']! as String,
    invitedByName: map['invited_by_name'] as String?,
    status: SharedInvitationStatus.fromName(map['status']),
    createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at']! as int),
    expiresAt: DateTime.fromMillisecondsSinceEpoch(map['expires_at']! as int),
    acceptedBy: map['accepted_by'] as String?,
    acceptedByName: map['accepted_by_name'] as String?,
  );

  Map<String, Object?> toCloudMap() => {
    'id': code,
    'goalId': goalId,
    'goalName': goalName,
    'invitedEmail': invitedEmail,
    'invitedBy': invitedBy,
    'invitedByName': invitedByName,
    'status': status.name,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'expiresAt': expiresAt.millisecondsSinceEpoch,
    'updatedAt': createdAt.millisecondsSinceEpoch,
  };

  static SharedGoalInvitation? fromCloudMap(
    String code,
    Map<String, Object?> data,
  ) {
    final goalId = data['goalId'];
    final goalName = data['goalName'];
    final invitedBy = data['invitedBy'];
    final createdAt = data['createdAt'];
    final expiresAt = data['expiresAt'];
    if (goalId is! String || goalName is! String || invitedBy is! String) {
      return null;
    }
    if (createdAt is! int || expiresAt is! int) return null;
    return SharedGoalInvitation(
      code: code,
      goalId: goalId,
      goalName: goalName,
      invitedEmail: data['invitedEmail'] as String?,
      invitedBy: invitedBy,
      invitedByName: data['invitedByName'] as String?,
      status: SharedInvitationStatus.fromName(data['status']),
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt),
      acceptedBy: data['acceptedBy'] as String?,
      acceptedByName: data['acceptedByName'] as String?,
    );
  }
}

/// Characters of shared-goal invitation codes (no 0/O, 1/I/L).
const sharedGoalCodeAlphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

/// Length of an invitation code: 16 characters ≈ 79 bits, far too many to
/// guess.
const sharedGoalCodeLength = 16;

/// Uppercases and strips everything but code characters.
String normalizeSharedGoalCode(String input) =>
    input.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

bool isWellFormedSharedGoalCode(String code) =>
    code.length == sharedGoalCodeLength &&
    code.split('').every(sharedGoalCodeAlphabet.contains);

String formatSharedGoalCode(String code) {
  final clean = normalizeSharedGoalCode(code);
  final groups = <String>[];
  for (var i = 0; i < clean.length; i += 4) {
    groups.add(clean.substring(i, i + 4 > clean.length ? clean.length : i + 4));
  }
  return groups.join('-');
}

/// How much one person put into (or took out of) a goal.
class MemberContribution {
  const MemberContribution({
    required this.uid,
    required this.name,
    required this.depositedMinor,
    required this.withdrawnMinor,
  });

  final String? uid;
  final String name;
  final int depositedMinor;
  final int withdrawnMinor;

  int get netMinor => depositedMinor - withdrawnMinor;
}

/// Totals for one kind of goal, or all of them.
class SavingsSummary {
  const SavingsSummary({
    required this.totalSavedMinor,
    required this.totalTargetMinor,
    required this.remainingActiveMinor,
    required this.activeCount,
    required this.pausedCount,
    required this.completedCount,
  });

  static const empty = SavingsSummary(
    totalSavedMinor: 0,
    totalTargetMinor: 0,
    remainingActiveMinor: 0,
    activeCount: 0,
    pausedCount: 0,
    completedCount: 0,
  );

  /// Money currently held in the goals.
  final int totalSavedMinor;
  final int totalTargetMinor;

  /// Still needed to reach the targets of active goals.
  final int remainingActiveMinor;
  final int activeCount;
  final int pausedCount;
  final int completedCount;

  int get goalCount => activeCount + pausedCount + completedCount;

  /// 0..1 progress of all money saved towards all targets.
  double get overallProgress => totalTargetMinor <= 0
      ? 0
      : (totalSavedMinor / totalTargetMinor).clamp(0.0, 1.0);
}
