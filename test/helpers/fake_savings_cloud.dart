import 'package:money_mate/core/services/cloud_savings_store.dart';
import 'package:money_mate/core/services/cloud_transaction_store.dart';
import 'package:money_mate/models/savings_model.dart';
import 'package:money_mate/models/sync_models.dart';

class _Doc {
  _Doc(this.data, this.micros);

  Map<String, Object?> data;
  int micros;
}

/// In-memory stand-in for the savings part of Firestore, enforcing the
/// same permissions as `firestore.rules`: personal data for its owner,
/// household savings for active household members, shared goals for their
/// active members, entry totals moved only together with an entry, owner-
/// only management, and one-time invitations.
///
/// A batch shares one server timestamp; documents are never removed.
class InMemorySavingsCloudStore implements CloudSavingsStore {
  /// Path of a collection -> document ID -> document.
  final Map<String, Map<String, _Doc>> _collections = {};
  int _serverMicros = 1000000;

  /// When true every call fails like an unreachable server.
  bool offline = false;

  /// When true all savings collections are refused (rules not deployed).
  bool denied = false;

  /// Active members of each household.
  final Map<String, Set<String>> householdMembers = {};

  /// Email of each user (for email-bound invitations).
  final Map<String, String> emails = {};

  int writes = 0;

  /// Runs before the next entry transaction commits (to simulate another
  /// device writing in between).
  Future<void> Function()? beforeNextCommit;

  // ---------------------------------------------------------------- paths

  static String _personal(String uid, SavingsCollection c) =>
      'users/$uid/${c.path}';

  static String _household(String hid, SavingsCollection c) =>
      'households/$hid/${c.path}';

  static const _sharedGoals = 'sharedGoals';
  static String _sharedEntries(String goalId) => 'sharedGoals/$goalId/entries';
  static String _members(String goalId) => 'sharedGoals/$goalId/members';
  static String _index(String uid) => 'users/$uid/sharedGoalMemberships';
  static const _invitations = 'sharedGoalInvitations';

  String _path(SavingsPartition p, SavingsCollection c) =>
      switch (p.ownership) {
        SavingsOwnership.personal => _personal(p.uid, c),
        SavingsOwnership.household => _household(p.householdId!, c),
        SavingsOwnership.shared =>
          c == SavingsCollection.goals
              ? _sharedGoals
              : _sharedEntries(p.goalId!),
      };

  Map<String, _Doc> _col(String path) => _collections[path] ??= {};

  // ------------------------------------------------------------- helpers

  /// Every document in [path] (for assertions).
  Map<String, Map<String, Object?>> docs(String path) => {
    for (final e in (_collections[path] ?? const <String, _Doc>{}).entries)
      e.key: e.value.data,
  };

  Map<String, Object?>? doc(String path, String id) =>
      _collections[path]?[id]?.data;

  /// Total stored on a household / shared goal.
  int savedOn(String path, String goalId) =>
      (doc(path, goalId)?['savedMinor'] as int?) ?? 0;

  void _write(String path, String id, Map<String, Object?> data) {
    writes++;
    _col(path)[id] = _Doc(data, _serverMicros);
  }

  void _tick() => _serverMicros += 10;

  void _check(String uid) {
    if (offline) throw const CloudUnavailableException('offline');
    if (denied) throw CloudAccessDeniedException(CloudPartition.personal(uid));
  }

  Never _deny(String uid) =>
      throw CloudAccessDeniedException(CloudPartition.personal(uid));

  SharedGoalMember? _member(String goalId, String uid) {
    final data = doc(_members(goalId), uid);
    return data == null
        ? null
        : SharedGoalMember.fromCloudMap(goalId, uid, data);
  }

  bool _isSharedMember(String goalId, String uid) =>
      _member(goalId, uid)?.isActive ?? false;

  void _checkAccess(SavingsPartition p) {
    _check(p.uid);
    switch (p.ownership) {
      case SavingsOwnership.personal:
        break;
      case SavingsOwnership.household:
        if (!(householdMembers[p.householdId]?.contains(p.uid) ?? false)) {
          _deny(p.uid);
        }
      case SavingsOwnership.shared:
        if (!_isSharedMember(p.goalId!, p.uid)) _deny(p.uid);
    }
  }

  /// Adds a member to a shared goal as the cloud would after acceptance.
  void putMember(SharedGoalMember member) {
    _tick();
    _write(_members(member.goalId), member.uid, member.toCloudMap());
    _write(_index(member.uid), member.goalId, {'goalId': member.goalId});
  }

  // ---------------------------------------------------------------- store

  @override
  Future<void> upsertGoals(SavingsPartition p, List<CloudRecord> goals) async {
    _checkAccess(p);
    if (p.ownership == SavingsOwnership.shared &&
        !(_member(p.goalId!, p.uid)?.isOwner ?? false)) {
      _deny(p.uid);
    }
    _tick();
    final path = _path(p, SavingsCollection.goals);
    for (final r in goals) {
      final existing = doc(path, r.id);
      final fields = r.deleted
          ? {
              'id': r.id,
              'deleted': true,
              'deletedAt': r.updatedAtMs,
              'updatedAt': r.updatedAtMs,
            }
          : {
              ...r.data,
              'id': r.id,
              'updatedAt': r.updatedAtMs,
              'deleted': false,
            };
      // Personal goals are replaced; others are merged so their running
      // total is kept.
      _write(
        path,
        r.id,
        p.isPersonal || existing == null ? fields : {...existing, ...fields},
      );
    }
  }

  @override
  Future<void> upsertPersonalEntries(
    String uid,
    List<CloudRecord> entries,
  ) async {
    _check(uid);
    _tick();
    for (final r in entries) {
      _write(_personal(uid, SavingsCollection.entries), r.id, {
        ...r.data,
        'id': r.id,
        'updatedAt': r.updatedAtMs,
        'deleted': r.deleted,
      });
    }
  }

  @override
  Future<EntryWriteOutcome> recordEntry(
    SavingsPartition p,
    SavingsEntry e,
  ) async {
    _checkAccess(p);
    final hook = beforeNextCommit;
    beforeNextCommit = null;
    if (hook != null) await hook();

    final entries = _path(p, SavingsCollection.entries);
    if (doc(entries, e.id) != null) return EntryWriteOutcome.alreadyRecorded;
    final goalPath = _path(p, SavingsCollection.goals);
    final goal = doc(goalPath, e.goalId);
    if (goal == null || goal['deleted'] == true) {
      return EntryWriteOutcome.goalMissing;
    }
    // Same checks as the rules.
    if (e.userUid != p.uid) _deny(p.uid);
    if (p.ownership == SavingsOwnership.shared) {
      final me = _member(e.goalId, p.uid)!;
      if (e.isDeposit ? !me.mayContribute : !me.mayWithdraw) _deny(p.uid);
    }
    if (e.isDeposit && goal['status'] != 'active') _deny(p.uid);
    final next = ((goal['savedMinor'] as int?) ?? 0) + e.signedMinor;
    if (next < 0) {
      throw const SavingsException(
        'Someone withdrew money meanwhile: there is not enough left in this '
        'goal.',
      );
    }
    _tick();
    _write(entries, e.id, {
      ...e.toCloudMap(),
      'id': e.id,
      'updatedAt': e.updatedAt.millisecondsSinceEpoch,
      'deleted': false,
    });
    final goalDoc = _col(goalPath)[e.goalId]!;
    goalDoc.data = {...goal, 'savedMinor': next, 'lastEntryId': e.id};
    return EntryWriteOutcome.recorded;
  }

  @override
  Future<List<CloudSavingsChange>> fetchChangedSince(
    SavingsPartition p,
    SavingsCollection collection,
    SyncCursor? after, {
    int limit = 300,
  }) async {
    _checkAccess(p);
    final path = _path(p, collection);
    final all = [
      for (final e in (_collections[path] ?? const <String, _Doc>{}).entries)
        CloudSavingsChange(
          CloudRecord.fromCloudMap(e.key, e.value.data),
          SyncCursor(e.value.micros, e.key),
        ),
    ]..sort((a, b) => a.position!.compareTo(b.position!));
    return all
        .where((c) => after == null || c.position!.isAfter(after))
        .take(limit)
        .toList();
  }

  // ---------------------------------------------------------- shared goals

  @override
  Future<List<String>> fetchSharedGoalIds(String uid) async {
    _check(uid);
    return docs(_index(uid)).keys.toList();
  }

  @override
  Future<CloudRecord?> fetchSharedGoal(String uid, String goalId) async {
    _check(uid);
    if (!_isSharedMember(goalId, uid)) _deny(uid);
    final data = doc(_sharedGoals, goalId);
    return data == null ? null : CloudRecord.fromCloudMap(goalId, data);
  }

  @override
  Future<List<SharedGoalMember>> fetchSharedMembers(
    String uid,
    String goalId,
  ) async {
    _check(uid);
    if (!_isSharedMember(goalId, uid)) _deny(uid);
    return [
      for (final e in docs(_members(goalId)).entries)
        if (SharedGoalMember.fromCloudMap(goalId, e.key, e.value) case final m?)
          m,
    ];
  }

  @override
  Future<void> createSharedGoal(
    SavingsGoal goal,
    SharedGoalMember owner,
  ) async {
    _check(owner.uid);
    if (doc(_sharedGoals, goal.id) != null || goal.ownerUid != owner.uid) {
      _deny(owner.uid);
    }
    _tick();
    _write(_sharedGoals, goal.id, {
      ...goal.toCloudMap(),
      'id': goal.id,
      'updatedAt': goal.updatedAt.millisecondsSinceEpoch,
      'deleted': false,
      'savedMinor': 0,
    });
    _write(_members(goal.id), owner.uid, owner.toCloudMap());
    _write(_index(owner.uid), goal.id, {'goalId': goal.id});
  }

  @override
  Future<void> forgetSharedGoal(String uid, String goalId) async {
    _check(uid);
    _collections[_index(uid)]?.remove(goalId);
  }

  @override
  Future<void> updateMember(String uid, SharedGoalMember member) async {
    _check(uid);
    final current = _member(member.goalId, member.uid);
    if (current == null) _deny(uid);
    final ownerEditing =
        (_member(member.goalId, uid)?.isOwner ?? false) &&
        _isSharedMember(member.goalId, uid) &&
        member.uid != uid &&
        !current.isOwner &&
        (member.status == current.status ||
            (current.isActive && member.status == SharedMemberStatus.removed));
    final leaving =
        member.uid == uid &&
        !current.isOwner &&
        current.isActive &&
        member.status == SharedMemberStatus.left &&
        member.canWithdraw == current.canWithdraw;
    if (!ownerEditing && !leaving) _deny(uid);
    _tick();
    _write(_members(member.goalId), member.uid, {
      ...doc(_members(member.goalId), member.uid)!,
      'status': member.status.name,
      'canContribute': member.canContribute,
      'canWithdraw': member.canWithdraw,
    });
  }

  // ----------------------------------------------------------- invitations

  @override
  Future<void> createInvitation(SharedGoalInvitation invitation) async {
    _check(invitation.invitedBy);
    if (!(_member(invitation.goalId, invitation.invitedBy)?.isOwner ?? false)) {
      _deny(invitation.invitedBy);
    }
    _tick();
    _write(_invitations, invitation.code, invitation.toCloudMap());
  }

  List<SharedGoalInvitation> _allInvitations() => [
    for (final e in docs(_invitations).entries)
      if (SharedGoalInvitation.fromCloudMap(e.key, e.value) case final i?) i,
  ];

  @override
  Future<List<SharedGoalInvitation>> fetchSentInvitations(
    String uid,
    String goalId,
  ) async {
    _check(uid);
    return [
      for (final i in _allInvitations())
        if (i.invitedBy == uid && i.goalId == goalId) i,
    ];
  }

  @override
  Future<List<SharedGoalInvitation>> fetchReceivedInvitations(
    String uid,
    String email,
  ) async {
    _check(uid);
    if (emails[uid] != email) _deny(uid);
    return [
      for (final i in _allInvitations())
        if (i.invitedEmail == email &&
            i.status == SharedInvitationStatus.pending)
          i,
    ];
  }

  @override
  Future<SharedGoalInvitation?> fetchInvitation(String uid, String code) async {
    _check(uid);
    final data = doc(_invitations, code);
    return data == null ? null : SharedGoalInvitation.fromCloudMap(code, data);
  }

  @override
  Future<void> acceptInvitation(
    SharedGoalInvitation invitation,
    SharedGoalMember me,
  ) async {
    _check(me.uid);
    final current = await fetchInvitation(me.uid, invitation.code);
    final goal = doc(_sharedGoals, invitation.goalId);
    final existing = _member(invitation.goalId, me.uid);
    if (current == null ||
        current.status != SharedInvitationStatus.pending ||
        !DateTime.now().isBefore(current.expiresAt) ||
        (current.invitedEmail != null &&
            current.invitedEmail != emails[me.uid]) ||
        goal == null ||
        goal['deleted'] == true ||
        (existing != null && existing.isActive) ||
        me.role != SharedGoalRole.member ||
        me.canWithdraw) {
      _deny(me.uid);
    }
    _tick();
    _write(_invitations, invitation.code, {
      ...doc(_invitations, invitation.code)!,
      'status': 'accepted',
      'acceptedBy': me.uid,
      'acceptedByName': me.displayName,
    });
    _write(_members(invitation.goalId), me.uid, {
      ...me.toCloudMap(),
      'invitationId': invitation.code,
    });
    _write(_index(me.uid), invitation.goalId, {'goalId': invitation.goalId});
  }

  @override
  Future<void> setInvitationStatus(
    String uid,
    String code,
    SharedInvitationStatus status,
  ) async {
    _check(uid);
    final current = await fetchInvitation(uid, code);
    if (current == null || current.status != SharedInvitationStatus.pending) {
      _deny(uid);
    }
    final allowed = switch (status) {
      SharedInvitationStatus.revoked => current.invitedBy == uid,
      SharedInvitationStatus.rejected =>
        current.invitedEmail != null && current.invitedEmail == emails[uid],
      _ => false,
    };
    if (!allowed) _deny(uid);
    _tick();
    _write(_invitations, code, {
      ...doc(_invitations, code)!,
      'status': status.name,
    });
  }
}
