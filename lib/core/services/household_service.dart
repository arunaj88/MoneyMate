import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import 'package:money_mate/models/household_models.dart';
import 'package:money_mate/core/services/cloud_transaction_store.dart';

/// A household request that failed, with a message for the user.
class HouseholdException implements Exception {
  const HouseholdException(this.message, {this.code});

  final String message;
  final String? code;

  bool get isOffline => code == 'unavailable' || code == 'deadline-exceeded';

  @override
  String toString() => message;
}

/// The household IDs a user is an active member of, as reported by the
/// server.
class MembershipUpdate {
  const MembershipUpdate(this.householdIds);

  final List<String> householdIds;
}

/// Household management.
///
/// Reads come straight from Firestore (security rules only let active
/// members read a household). Every change to membership, roles or
/// invitations goes through Cloud Functions, which validate it with admin
/// rights: clients cannot write those documents at all.
abstract class HouseholdService {
  /// Households [uid] is an active member of; emits on every change.
  Stream<MembershipUpdate> watchMemberships(String uid);

  /// One server read of the same list, used to confirm a lost membership.
  Future<MembershipUpdate> fetchMemberships(String uid);

  Stream<Household?> watchHousehold(String householdId);

  Stream<List<HouseholdMember>> watchMembers(String householdId);

  /// Invitations of a household (owner only).
  Stream<List<HouseholdInvitation>> watchInvitations(String householdId);

  /// Creates a household owned by the caller; returns its ID.
  Future<String> createHousehold(String name);

  Future<void> renameHousehold(String householdId, String name);

  Future<InvitationCode> createInvitation(
    String householdId, {
    String? email,
    int expiresInDays = 7,
  });

  Future<void> revokeInvitation(String householdId, String invitationId);

  /// Checks [code] without using it (household name, inviter, expiry).
  Future<InvitationPreview> previewInvitation(String code);

  /// Joins the household of [code]; returns its ID.
  Future<String> acceptInvitation(String code);

  Future<void> removeMember(String householdId, String memberUid);

  Future<void> leaveHousehold(String householdId);

  Future<void> transferOwnership(String householdId, String newOwnerUid);

  /// Deletes the household and its shared data (owner, no other members).
  Future<void> deleteHousehold(String householdId);

  /// Copies the caller's current account name, email and photo to their
  /// member document, so other members see profile changes.
  Future<void> refreshMemberProfile(String householdId);
}

/// [HouseholdService] backed by Firestore and callable Cloud Functions.
class FirebaseHouseholdService implements HouseholdService {
  FirebaseHouseholdService({
    FirebaseFirestore? firestore,
    FirebaseFunctions? functions,
    Duration? timeout,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _functions = functions ?? FirebaseFunctions.instance,
       _timeout = timeout ?? const Duration(seconds: 30);

  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;
  final Duration _timeout;

  CollectionReference<Map<String, dynamic>> _memberships(String uid) =>
      _firestore
          .collection(CloudPaths.users)
          .doc(uid)
          .collection(CloudPaths.memberships);

  DocumentReference<Map<String, dynamic>> _household(String id) =>
      _firestore.collection(CloudPaths.households).doc(id);

  static MembershipUpdate _toUpdate(QuerySnapshot<Map<String, dynamic>> s) =>
      MembershipUpdate([
        for (final d in s.docs)
          if (d.data()['status'] == MembershipStatus.active.name) d.id,
      ]);

  @override
  Stream<MembershipUpdate> watchMemberships(String uid) =>
      _memberships(uid).snapshots().map(_toUpdate);

  @override
  Future<MembershipUpdate> fetchMemberships(String uid) => _guard(() async {
    final snap = await _memberships(
      uid,
    ).get(const GetOptions(source: Source.server)).timeout(_timeout);
    return _toUpdate(snap);
  });

  static DateTime? _time(Object? value) => switch (value) {
    final Timestamp t => t.toDate(),
    final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
    _ => null,
  };

  @override
  Stream<Household?> watchHousehold(String householdId) =>
      _household(householdId).snapshots().map((doc) {
        final data = doc.data();
        if (data == null || data['status'] == 'deleted') return null;
        return Household(
          id: doc.id,
          name: (data['name'] as String?) ?? 'Household',
          ownerUid: (data['ownerUid'] as String?) ?? '',
          createdAt: _time(data['createdAt']),
        );
      });

  @override
  Stream<List<HouseholdMember>> watchMembers(String householdId) =>
      _household(householdId)
          .collection(CloudPaths.members)
          .snapshots()
          .map(
            (snap) => [
              for (final doc in snap.docs)
                HouseholdMember(
                  uid: doc.id,
                  role: HouseholdRole.fromName(doc.data()['role']),
                  status: MembershipStatus.fromName(doc.data()['status']),
                  displayName: doc.data()['displayName'] as String?,
                  email: doc.data()['email'] as String?,
                  photoUrl: doc.data()['photoUrl'] as String?,
                  joinedAt: _time(doc.data()['joinedAt']),
                ),
            ],
          );

  @override
  Stream<List<HouseholdInvitation>> watchInvitations(String householdId) =>
      _household(householdId)
          .collection(CloudPaths.invitations)
          .orderBy('createdAt', descending: true)
          .limit(50)
          .snapshots()
          .map(
            (snap) => [
              for (final doc in snap.docs)
                if (_time(doc.data()['expiresAt']) case final expires?)
                  HouseholdInvitation(
                    id: doc.id,
                    status: InvitationStatus.fromName(doc.data()['status']),
                    expiresAt: expires,
                    code: doc.data()['code'] as String?,
                    createdAt: _time(doc.data()['createdAt']),
                    invitedEmail: doc.data()['invitedEmail'] as String?,
                    acceptedBy: doc.data()['acceptedBy'] as String?,
                    acceptedByName: doc.data()['acceptedByName'] as String?,
                  ),
            ],
          );

  Future<Map<String, dynamic>> _call(String name, Map<String, Object?> data) =>
      _guard(() async {
        final result = await _functions
            .httpsCallable(
              name,
              options: HttpsCallableOptions(timeout: _timeout),
            )
            .call<Object?>(data);
        final value = result.data;
        return value is Map ? Map<String, dynamic>.from(value) : const {};
      });

  @override
  Future<String> createHousehold(String name) async =>
      (await _call('createHousehold', {'name': name}))['householdId'] as String;

  @override
  Future<void> renameHousehold(String householdId, String name) =>
      _call('updateHousehold', {'householdId': householdId, 'name': name});

  @override
  Future<InvitationCode> createInvitation(
    String householdId, {
    String? email,
    int expiresInDays = 7,
  }) async {
    final data = await _call('createInvitation', {
      'householdId': householdId,
      if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
      'expiresInDays': expiresInDays,
    });
    return InvitationCode(
      invitationId: data['invitationId'] as String,
      code: data['code'] as String,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(data['expiresAt'] as int),
    );
  }

  @override
  Future<void> revokeInvitation(String householdId, String invitationId) =>
      _call('revokeInvitation', {
        'householdId': householdId,
        'invitationId': invitationId,
      });

  @override
  Future<InvitationPreview> previewInvitation(String code) async {
    final data = await _call('previewInvitation', {
      'code': normalizeInvitationCode(code),
    });
    return InvitationPreview(
      householdName: data['householdName'] as String,
      invitedByName: data['invitedByName'] as String?,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(data['expiresAt'] as int),
    );
  }

  @override
  Future<String> acceptInvitation(String code) async =>
      (await _call('acceptInvitation', {
            'code': normalizeInvitationCode(code),
          }))['householdId']
          as String;

  @override
  Future<void> removeMember(String householdId, String memberUid) => _call(
    'removeMember',
    {'householdId': householdId, 'memberUid': memberUid},
  );

  @override
  Future<void> leaveHousehold(String householdId) =>
      _call('leaveHousehold', {'householdId': householdId});

  @override
  Future<void> transferOwnership(String householdId, String newOwnerUid) =>
      _call('transferOwnership', {
        'householdId': householdId,
        'newOwnerUid': newOwnerUid,
      });

  @override
  Future<void> deleteHousehold(String householdId) =>
      _call('deleteHousehold', {'householdId': householdId});

  @override
  Future<void> refreshMemberProfile(String householdId) =>
      _call('refreshMemberProfile', {'householdId': householdId});

  /// Turns Functions / Firestore errors into [HouseholdException]s. The
  /// functions return user-facing messages for expected failures.
  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on FirebaseFunctionsException catch (e) {
      debugPrint('Household function failed: ${e.code} ${e.message}');
      throw HouseholdException(_message(e.code, e.message), code: e.code);
    } on FirebaseException catch (e) {
      throw HouseholdException(_message(e.code, e.message), code: e.code);
    } on TimeoutException {
      throw const HouseholdException(
        'The request timed out. Check your connection and try again.',
        code: 'deadline-exceeded',
      );
    }
  }

  static String _message(String code, String? serverMessage) {
    switch (code) {
      case 'unavailable':
      case 'deadline-exceeded':
        return 'You are offline. Connect to the internet and try again.';
      case 'unauthenticated':
        return 'Please sign in again to continue.';
      case 'not-found' when serverMessage == null:
        return 'Household management is not set up on the server yet.';
      case 'internal':
        return 'Something went wrong on the server. Please try again.';
      default:
        return serverMessage ?? 'Something went wrong. Please try again.';
    }
  }
}
