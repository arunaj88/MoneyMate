import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'package:money_mate/core/services/cloud_transaction_store.dart'
    show CloudPaths;

/// What this installation tells the Cloud Functions about itself, stored
/// at users/{uid}/devices/{deviceId}.
@immutable
class DeviceRegistration {
  const DeviceRegistration({
    required this.deviceId,
    required this.token,
    required this.platform,
    required this.currencyCode,
    required this.householdActivity,
    required this.householdBudgets,
    required this.savingsUpdates,
  });

  /// Random ID of this app installation (kept in SharedPreferences).
  final String deviceId;
  final String token;
  final String platform;

  /// Amounts in pushes are formatted in this currency.
  final String currencyCode;
  final bool householdActivity;
  final bool householdBudgets;
  final bool savingsUpdates;

  Map<String, Object?> toCloudMap(int updatedAtMs) => {
    'deviceId': deviceId,
    'token': token,
    'platform': platform,
    'currencyCode': currencyCode,
    'householdActivity': householdActivity,
    'householdBudgets': householdBudgets,
    'savingsUpdates': savingsUpdates,
    'updatedAt': updatedAtMs,
  };

  @override
  bool operator ==(Object other) =>
      other is DeviceRegistration &&
      other.deviceId == deviceId &&
      other.token == token &&
      other.platform == platform &&
      other.currencyCode == currencyCode &&
      other.householdActivity == householdActivity &&
      other.householdBudgets == householdBudgets &&
      other.savingsUpdates == savingsUpdates;

  @override
  int get hashCode => Object.hash(
    deviceId,
    token,
    platform,
    currencyCode,
    householdActivity,
    householdBudgets,
    savingsUpdates,
  );
}

/// A shared budget that crossed a threshold, written once per budget,
/// period and level to households/{hid}/budgetAlerts so the other members
/// get a push (see functions/src/notifications.js).
@immutable
class HouseholdBudgetAlert {
  const HouseholdBudgetAlert({
    required this.householdId,
    required this.key,
    required this.level,
    required this.title,
    required this.message,
    required this.periodEnd,
  });

  final String householdId;

  /// Budget and period, e.g. `monthly.20261101`.
  final String key;

  /// 'approaching', 'warning' or 'exceeded'.
  final String level;
  final String title;

  /// Worded for any member ("the shared monthly budget").
  final String message;

  /// Pushes for an alert that reaches the server after its period ended
  /// (written offline) are dropped.
  final DateTime periodEnd;

  /// Document ID: one alert per budget, period and level.
  String get id => '$key.$level'.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
}

/// Cloud side of notifications.
abstract class NotificationCloud {
  Future<void> register(String uid, DeviceRegistration registration);

  Future<void> unregister(String uid, String deviceId);

  /// Records [alert] for the household unless another member's app already
  /// did. Never throws: a missed household alert is not worth an error.
  Future<void> publishBudgetAlert(
    HouseholdBudgetAlert alert, {
    required String uid,
    String? userName,
  });
}

/// [NotificationCloud] backed by Cloud Firestore.
class FirestoreNotificationCloud implements NotificationCloud {
  FirestoreNotificationCloud({
    FirebaseFirestore? firestore,
    DateTime Function()? clock,
  }) : _firestoreOverride = firestore,
       _clock = clock ?? DateTime.now;

  final FirebaseFirestore? _firestoreOverride;
  final DateTime Function() _clock;

  FirebaseFirestore get _firestore =>
      _firestoreOverride ?? FirebaseFirestore.instance;

  static const _devices = 'devices';
  static const _budgetAlerts = 'budgetAlerts';
  static const _timeout = Duration(seconds: 20);

  DocumentReference<Map<String, dynamic>> _device(String uid, String id) =>
      _firestore
          .collection(CloudPaths.users)
          .doc(uid)
          .collection(_devices)
          .doc(id);

  @override
  Future<void> register(String uid, DeviceRegistration registration) =>
      _device(uid, registration.deviceId)
          .set({
            ...registration.toCloudMap(_clock().millisecondsSinceEpoch),
            'serverUpdatedAt': FieldValue.serverTimestamp(),
          })
          .timeout(_timeout);

  @override
  Future<void> unregister(String uid, String deviceId) =>
      _device(uid, deviceId).delete().timeout(_timeout);

  @override
  Future<void> publishBudgetAlert(
    HouseholdBudgetAlert alert, {
    required String uid,
    String? userName,
  }) async {
    final ref = _firestore
        .collection(CloudPaths.households)
        .doc(alert.householdId)
        .collection(_budgetAlerts)
        .doc(alert.id);
    try {
      // Rules reject a second write of the same alert (no updates), which
      // is how two members' apps agree that only one push goes out.
      await ref
          .set({
            'id': alert.id,
            'key': alert.key,
            'level': alert.level,
            'title': alert.title,
            'message': alert.message,
            'createdBy': uid,
            if (userName != null && userName.isNotEmpty)
              'createdByName': userName.length > 80
                  ? userName.substring(0, 80)
                  : userName,
            'createdAt': _clock().millisecondsSinceEpoch,
            'periodEnd': alert.periodEnd.millisecondsSinceEpoch,
            'serverCreatedAt': FieldValue.serverTimestamp(),
          })
          .timeout(_timeout);
    } on FirebaseException catch (e) {
      if (e.code != 'permission-denied') {
        debugPrint('Household budget alert not sent: ${e.code}');
      }
    } on TimeoutException {
      debugPrint('Household budget alert not sent: timed out');
    }
  }
}
