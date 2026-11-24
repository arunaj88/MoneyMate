import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:money_mate/models/savings_model.dart';
import 'package:money_mate/models/sync_models.dart';
import 'package:money_mate/core/services/cloud_transaction_store.dart';

/// A savings change the user is not allowed to make, with a message that
/// can be shown as is.
class SavingsException implements Exception {
  const SavingsException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The goal and entry collections of personal and household savings.
enum SavingsCollection {
  /// `users/{uid}/savingsGoals` / `households/{hid}/savingsGoals`
  goals('savingsGoals'),

  /// `users/{uid}/savingsEntries` / `households/{hid}/savingsEntries`
  /// (`sharedGoals/{goalId}/entries` for a shared goal)
  entries('savingsEntries');

  const SavingsCollection(this.path);

  /// Collection name; also the `collection` value of local tombstones.
  final String path;
}

/// Where one set of savings lives in Firestore, as seen by [uid]:
///
/// * personal: `users/{uid}/savingsGoals|savingsEntries`
/// * household: `households/{householdId}/savingsGoals|savingsEntries`
/// * shared: `sharedGoals/{goalId}` and its `entries` / `members`
class SavingsPartition {
  const SavingsPartition.personal(this.uid)
    : ownership = SavingsOwnership.personal,
      householdId = null,
      goalId = null;

  const SavingsPartition.household(this.uid, String this.householdId)
    : ownership = SavingsOwnership.household,
      goalId = null;

  const SavingsPartition.shared(this.uid, String this.goalId)
    : ownership = SavingsOwnership.shared,
      householdId = null;

  /// The signed-in user reading and writing.
  final String uid;
  final SavingsOwnership ownership;
  final String? householdId;

  /// The one goal of a shared partition.
  final String? goalId;

  bool get isPersonal => ownership == SavingsOwnership.personal;

  /// Value of `cloud_tombstones.household_id` for this partition.
  String get tombstoneKey => householdId ?? '';

  /// For error reporting through [guardFirestore].
  CloudPartition get cloudPartition => householdId != null
      ? CloudPartition.household(uid, householdId!)
      : CloudPartition.personal(uid);

  @override
  bool operator ==(Object other) =>
      other is SavingsPartition &&
      other.uid == uid &&
      other.ownership == ownership &&
      other.householdId == householdId &&
      other.goalId == goalId;

  @override
  int get hashCode => Object.hash(uid, ownership, householdId, goalId);

  @override
  String toString() =>
      'SavingsPartition(${ownership.name}, ${householdId ?? goalId ?? uid})';
}

/// A savings document read from the change feed.
class CloudSavingsChange {
  const CloudSavingsChange(this.record, this.position);

  /// Null when the document cannot be read; it is skipped, but its
  /// [position] still moves the pull cursor past it.
  final CloudRecord? record;

  /// Where the document sits in the change feed.
  final SyncCursor? position;
}

/// Result of writing one household / shared entry.
enum EntryWriteOutcome {
  /// Written together with the goal's new running total.
  recorded,

  /// An entry with this ID is already in the cloud (an earlier attempt
  /// succeeded): nothing was written again.
  alreadyRecorded,

  /// The goal no longer exists (deleted on another device).
  goalMissing,
}

/// Cloud side of savings.
///
/// Every document is written with the goal's or entry's own ID, so retrying
/// an upload never duplicates it. Deletions are soft (`deleted: true`).
///
/// Household and shared goals keep a running total (`savedMinor`) on the
/// goal document. Each entry is written in a Firestore transaction together
/// with the new total; security rules check that the total changes by
/// exactly the entry's amount and never goes below zero, so concurrent
/// contributions and withdrawals from several people stay consistent.
abstract class CloudSavingsStore {
  /// Writes goal details. Personal goals are written whole; household and
  /// shared goals are merged so their running total is never overwritten.
  Future<void> upsertGoals(SavingsPartition partition, List<CloudRecord> goals);

  /// Writes personal entries (batched).
  Future<void> upsertPersonalEntries(String uid, List<CloudRecord> entries);

  /// Writes one household / shared [entry] and the goal's new total in one
  /// transaction. Throws [SavingsException] when a withdrawal exceeds the
  /// latest balance.
  Future<EntryWriteOutcome> recordEntry(
    SavingsPartition partition,
    SavingsEntry entry,
  );

  /// Documents of [collection] written after [after], oldest first. For a
  /// shared partition only entries are read this way.
  Future<List<CloudSavingsChange>> fetchChangedSince(
    SavingsPartition partition,
    SavingsCollection collection,
    SyncCursor? after, {
    int limit = 300,
  });

  // ---------------------------------------------------------- shared goals

  /// IDs of the shared goals [uid] joined (`users/{uid}/sharedGoalMemberships`).
  Future<List<String>> fetchSharedGoalIds(String uid);

  /// The goal document; null when it does not exist.
  Future<CloudRecord?> fetchSharedGoal(String uid, String goalId);

  Future<List<SharedGoalMember>> fetchSharedMembers(String uid, String goalId);

  /// Creates [goal] with [owner] as its owner, in one batch.
  Future<void> createSharedGoal(SavingsGoal goal, SharedGoalMember owner);

  /// Removes [goalId] from [uid]'s own list of shared goals.
  Future<void> forgetSharedGoal(String uid, String goalId);

  /// Changes a member's status or permissions (owner), or lets a member
  /// leave (their own document).
  Future<void> updateMember(String uid, SharedGoalMember member);

  // ----------------------------------------------------------- invitations

  Future<void> createInvitation(SharedGoalInvitation invitation);

  /// Invitations [uid] sent for [goalId].
  Future<List<SharedGoalInvitation>> fetchSentInvitations(
    String uid,
    String goalId,
  );

  /// Pending invitations addressed to [email].
  Future<List<SharedGoalInvitation>> fetchReceivedInvitations(
    String uid,
    String email,
  );

  /// The invitation behind [code]; null when there is none.
  Future<SharedGoalInvitation?> fetchInvitation(String uid, String code);

  /// Accepts [invitation] as [me]: marks it accepted, adds the member and
  /// lists the goal under the user, in one batch.
  Future<void> acceptInvitation(
    SharedGoalInvitation invitation,
    SharedGoalMember me,
  );

  /// Rejects (invitee) or revokes (inviter) a pending invitation.
  Future<void> setInvitationStatus(
    String uid,
    String code,
    SharedInvitationStatus status,
  );
}

/// Firestore paths of shared goals (also used by the security rules).
class SharedGoalPaths {
  SharedGoalPaths._();

  static const goals = 'sharedGoals';
  static const entries = 'entries';
  static const members = 'members';
  static const invitations = 'sharedGoalInvitations';
  static const userIndex = 'sharedGoalMemberships';
}

/// [CloudSavingsStore] backed by Cloud Firestore (server reads only).
class FirestoreSavingsStore implements CloudSavingsStore {
  FirestoreSavingsStore({FirebaseFirestore? firestore, Duration? timeout})
    : _firestore = firestore ?? FirebaseFirestore.instance,
      _timeout = timeout ?? const Duration(seconds: 30);

  final FirebaseFirestore _firestore;
  final Duration _timeout;

  static const _serverField = 'serverUpdatedAt';
  static const _serverOnly = GetOptions(source: Source.server);
  static const _batchSize = 400;

  Object get _now => FieldValue.serverTimestamp();

  DocumentReference<Map<String, dynamic>> _sharedGoal(String goalId) =>
      _firestore.collection(SharedGoalPaths.goals).doc(goalId);

  CollectionReference<Map<String, dynamic>> _collection(
    SavingsPartition p,
    SavingsCollection c,
  ) => switch (p.ownership) {
    SavingsOwnership.personal =>
      _firestore.collection(CloudPaths.users).doc(p.uid).collection(c.path),
    SavingsOwnership.household =>
      _firestore
          .collection(CloudPaths.households)
          .doc(p.householdId)
          .collection(c.path),
    SavingsOwnership.shared => _sharedGoal(
      p.goalId!,
    ).collection(SharedGoalPaths.entries),
  };

  DocumentReference<Map<String, dynamic>> _goalRef(
    SavingsPartition p,
    String goalId,
  ) => p.ownership == SavingsOwnership.shared
      ? _sharedGoal(goalId)
      : _collection(p, SavingsCollection.goals).doc(goalId);

  Future<T> _guard<T>(SavingsPartition p, Future<T> Function() action) =>
      guardFirestore(p.cloudPartition, action);

  Future<T> _guardUser<T>(String uid, Future<T> Function() action) =>
      guardFirestore(CloudPartition.personal(uid), action);

  Map<String, Object?> _goalFields(SavingsPartition p, CloudRecord r) =>
      r.deleted
      ? {
          'id': r.id,
          'deleted': true,
          'deletedAt': r.updatedAtMs,
          'updatedAt': r.updatedAtMs,
          if (!p.isPersonal) 'updatedBy': p.uid,
          _serverField: _now,
        }
      : {
          ...r.data,
          'id': r.id,
          'updatedAt': r.updatedAtMs,
          'deleted': false,
          if (!p.isPersonal) 'updatedBy': p.uid,
          _serverField: _now,
        };

  @override
  Future<void> upsertGoals(SavingsPartition p, List<CloudRecord> goals) =>
      _guard(p, () async {
        for (var i = 0; i < goals.length; i += _batchSize) {
          final batch = _firestore.batch();
          for (final r in goals.skip(i).take(_batchSize)) {
            batch.set(
              _goalRef(p, r.id),
              _goalFields(p, r),
              // The running total of shared balances is never overwritten.
              p.isPersonal ? null : SetOptions(merge: true),
            );
          }
          await batch.commit().timeout(_timeout);
        }
      });

  @override
  Future<void> upsertPersonalEntries(String uid, List<CloudRecord> entries) {
    final p = SavingsPartition.personal(uid);
    return _guard(p, () async {
      for (var i = 0; i < entries.length; i += _batchSize) {
        final batch = _firestore.batch();
        for (final r in entries.skip(i).take(_batchSize)) {
          batch.set(_collection(p, SavingsCollection.entries).doc(r.id), {
            ...r.data,
            'id': r.id,
            'updatedAt': r.updatedAtMs,
            'deleted': r.deleted,
            _serverField: _now,
          });
        }
        await batch.commit().timeout(_timeout);
      }
    });
  }

  @override
  Future<EntryWriteOutcome> recordEntry(SavingsPartition p, SavingsEntry e) =>
      _guard(p, () async {
        final goalRef = _goalRef(p, e.goalId);
        final entryRef = _collection(p, SavingsCollection.entries).doc(e.id);
        return _firestore
            .runTransaction((tx) async {
              // Idempotent: a retry after a lost response writes nothing.
              if ((await tx.get(entryRef)).exists) {
                return EntryWriteOutcome.alreadyRecorded;
              }
              final goal = (await tx.get(goalRef)).data();
              if (goal == null || goal['deleted'] == true) {
                return EntryWriteOutcome.goalMissing;
              }
              final saved = goal['savedMinor'];
              final next = (saved is int ? saved : 0) + e.signedMinor;
              if (next < 0) {
                throw const SavingsException(
                  'Someone withdrew money meanwhile: there is not enough '
                  'left in this goal.',
                );
              }
              tx.set(entryRef, {
                ...e.toCloudMap(),
                'id': e.id,
                'updatedAt': e.updatedAt.millisecondsSinceEpoch,
                'deleted': false,
                _serverField: _now,
              });
              tx.update(goalRef, {'savedMinor': next, 'lastEntryId': e.id});
              return EntryWriteOutcome.recorded;
            })
            .timeout(_timeout);
      });

  @override
  Future<List<CloudSavingsChange>> fetchChangedSince(
    SavingsPartition p,
    SavingsCollection c,
    SyncCursor? after, {
    int limit = 300,
  }) => _guard(p, () async {
    Query<Map<String, dynamic>> query = _collection(
      p,
      c,
    ).orderBy(_serverField).orderBy(FieldPath.documentId);
    if (after != null) {
      query = query.startAfter([
        Timestamp.fromMicrosecondsSinceEpoch(after.serverMicros),
        after.docId,
      ]);
    }
    final snap = await query.limit(limit).get(_serverOnly).timeout(_timeout);
    return [
      for (final doc in snap.docs)
        CloudSavingsChange(
          CloudRecord.fromCloudMap(doc.id, doc.data()),
          _position(doc),
        ),
    ];
  });

  static SyncCursor? _position(DocumentSnapshot<Map<String, dynamic>> doc) {
    final server = doc.data()?[_serverField];
    return server is Timestamp
        ? SyncCursor(server.microsecondsSinceEpoch, doc.id)
        : null;
  }

  // ---------------------------------------------------------- shared goals

  @override
  Future<List<String>> fetchSharedGoalIds(String uid) =>
      _guardUser(uid, () async {
        final snap = await _firestore
            .collection(CloudPaths.users)
            .doc(uid)
            .collection(SharedGoalPaths.userIndex)
            .get(_serverOnly)
            .timeout(_timeout);
        return [for (final d in snap.docs) d.id];
      });

  @override
  Future<CloudRecord?> fetchSharedGoal(String uid, String goalId) => _guardUser(
    uid,
    () async {
      final doc = await _sharedGoal(goalId).get(_serverOnly).timeout(_timeout);
      final data = doc.data();
      return data == null ? null : CloudRecord.fromCloudMap(doc.id, data);
    },
  );

  @override
  Future<List<SharedGoalMember>> fetchSharedMembers(
    String uid,
    String goalId,
  ) => _guardUser(uid, () async {
    final snap = await _sharedGoal(
      goalId,
    ).collection(SharedGoalPaths.members).get(_serverOnly).timeout(_timeout);
    return [
      for (final d in snap.docs)
        if (SharedGoalMember.fromCloudMap(goalId, d.id, d.data()) case final m?)
          m,
    ];
  });

  @override
  Future<void> createSharedGoal(SavingsGoal goal, SharedGoalMember owner) =>
      _guardUser(owner.uid, () async {
        final batch = _firestore.batch()
          ..set(_sharedGoal(goal.id), {
            ...goal.toCloudMap(),
            'id': goal.id,
            'updatedAt': goal.updatedAt.millisecondsSinceEpoch,
            'deleted': false,
            'savedMinor': 0,
            _serverField: _now,
          })
          ..set(
            _sharedGoal(
              goal.id,
            ).collection(SharedGoalPaths.members).doc(owner.uid),
            {...owner.toCloudMap(), _serverField: _now},
          )
          ..set(_index(owner.uid, goal.id), {
            'goalId': goal.id,
            'joinedAt': goal.createdAt.millisecondsSinceEpoch,
          });
        await batch.commit().timeout(_timeout);
      });

  DocumentReference<Map<String, dynamic>> _index(String uid, String goalId) =>
      _firestore
          .collection(CloudPaths.users)
          .doc(uid)
          .collection(SharedGoalPaths.userIndex)
          .doc(goalId);

  @override
  Future<void> forgetSharedGoal(String uid, String goalId) =>
      _guardUser(uid, () => _index(uid, goalId).delete().timeout(_timeout));

  @override
  Future<void> updateMember(String uid, SharedGoalMember member) =>
      _guardUser(uid, () async {
        await _sharedGoal(member.goalId)
            .collection(SharedGoalPaths.members)
            .doc(member.uid)
            .update({
              'status': member.status.name,
              'canContribute': member.canContribute,
              'canWithdraw': member.canWithdraw,
              _serverField: _now,
            })
            .timeout(_timeout);
      });

  // ----------------------------------------------------------- invitations

  CollectionReference<Map<String, dynamic>> get _invitations =>
      _firestore.collection(SharedGoalPaths.invitations);

  List<SharedGoalInvitation> _parseInvitations(
    QuerySnapshot<Map<String, dynamic>> snap,
  ) => [
    for (final d in snap.docs)
      if (SharedGoalInvitation.fromCloudMap(d.id, d.data()) case final i?) i,
  ];

  @override
  Future<void> createInvitation(SharedGoalInvitation invitation) =>
      _guardUser(invitation.invitedBy, () async {
        await _invitations
            .doc(invitation.code)
            .set({...invitation.toCloudMap(), _serverField: _now})
            .timeout(_timeout);
      });

  @override
  Future<List<SharedGoalInvitation>> fetchSentInvitations(
    String uid,
    String goalId,
  ) => _guardUser(uid, () async {
    final snap = await _invitations
        .where('invitedBy', isEqualTo: uid)
        .where('goalId', isEqualTo: goalId)
        .get(_serverOnly)
        .timeout(_timeout);
    return _parseInvitations(snap);
  });

  @override
  Future<List<SharedGoalInvitation>> fetchReceivedInvitations(
    String uid,
    String email,
  ) => _guardUser(uid, () async {
    final snap = await _invitations
        .where('invitedEmail', isEqualTo: email.trim().toLowerCase())
        .where('status', isEqualTo: SharedInvitationStatus.pending.name)
        .get(_serverOnly)
        .timeout(_timeout);
    return _parseInvitations(snap);
  });

  @override
  Future<SharedGoalInvitation?> fetchInvitation(String uid, String code) =>
      _guardUser(uid, () async {
        final doc = await _invitations
            .doc(code)
            .get(_serverOnly)
            .timeout(_timeout);
        final data = doc.data();
        return data == null
            ? null
            : SharedGoalInvitation.fromCloudMap(doc.id, data);
      });

  @override
  Future<void> acceptInvitation(
    SharedGoalInvitation invitation,
    SharedGoalMember me,
  ) => _guardUser(me.uid, () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = _firestore.batch()
      ..update(_invitations.doc(invitation.code), {
        'status': SharedInvitationStatus.accepted.name,
        'acceptedBy': me.uid,
        'acceptedByName': me.displayName,
        'updatedAt': now,
        _serverField: _now,
      })
      ..set(
        _sharedGoal(
          invitation.goalId,
        ).collection(SharedGoalPaths.members).doc(me.uid),
        {
          ...me.toCloudMap(),
          'invitationId': invitation.code,
          _serverField: _now,
        },
      )
      ..set(_index(me.uid, invitation.goalId), {
        'goalId': invitation.goalId,
        'joinedAt': now,
      });
    await batch.commit().timeout(_timeout);
  });

  @override
  Future<void> setInvitationStatus(
    String uid,
    String code,
    SharedInvitationStatus status,
  ) => _guardUser(uid, () async {
    await _invitations
        .doc(code)
        .update({
          'status': status.name,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
          _serverField: _now,
        })
        .timeout(_timeout);
  });
}
