import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/services/household_service.dart';
import 'package:money_mate/models/app_user.dart';
import 'package:money_mate/models/household_models.dart';
import 'package:money_mate/providers/auth_provider.dart';

enum HouseholdPhase {
  /// Household features are not configured in this build (tests).
  unavailable,
  signedOut,

  /// Waiting for the first answer from the server (no cached household).
  loading,

  /// Up to date with the server.
  ready,

  /// Showing the cached household; the server has not answered yet.
  cached,
}

/// Requests the household screens can start. Only one runs at a time.
enum HouseholdAction {
  create,
  rename,
  invite,
  revoke,
  join,
  removeMember,
  leave,
  transfer,
  delete;

  /// What the user sees while the request runs.
  String get progressLabel => switch (this) {
    HouseholdAction.create => 'Creating household…',
    HouseholdAction.rename => 'Renaming household…',
    HouseholdAction.invite => 'Creating invitation…',
    HouseholdAction.revoke => 'Revoking invitation…',
    HouseholdAction.join => 'Joining household…',
    HouseholdAction.removeMember => 'Removing member…',
    HouseholdAction.leave => 'Leaving household…',
    HouseholdAction.transfer => 'Transferring ownership…',
    HouseholdAction.delete => 'Deleting household…',
  };
}

/// The signed-in user's household: membership, members, invitations and
/// the owner's management actions.
///
/// The membership is cached on the device so shared transactions can be
/// recorded offline. Access is only treated as lost when the server
/// confirms it (membership gone, or reads refused and then confirmed), so a
/// flaky connection never hides or removes shared data.
class HouseholdProvider extends ChangeNotifier {
  HouseholdProvider({
    HouseholdService? service,
    required SharedPreferences preferences,
  }) : _service = service,
       _prefs = preferences {
    if (_service == null) _phase = HouseholdPhase.unavailable;
  }

  final HouseholdService? _service;
  final SharedPreferences _prefs;

  String? _uid;
  String? _userEmail;
  AppUser? _user;

  /// Profile last sent to [HouseholdService.refreshMemberProfile], so a
  /// member document that is slow to change is not refreshed repeatedly.
  String? _profileSyncKey;
  HouseholdPhase _phase = HouseholdPhase.signedOut;
  Household? _household;
  List<HouseholdMember> _members = const [];
  List<HouseholdInvitation> _invitations = const [];
  HouseholdAction? _pending;
  String? _pendingTarget;
  String? _error;
  String? _notice;
  bool _disposed = false;

  StreamSubscription<MembershipUpdate>? _membershipSub;
  StreamSubscription<Household?>? _householdSub;
  StreamSubscription<List<HouseholdMember>>? _membersSub;
  StreamSubscription<List<HouseholdInvitation>>? _invitationsSub;

  String? _releasedHouseholdId;
  int _releaseToken = 0;

  /// Household the user is leaving or deleting right now: losing access to
  /// it is expected, so no "access ended" notice is shown.
  String? _leaving;

  bool get isAvailable => _service != null;
  HouseholdPhase get phase => _phase;
  Household? get household => _household;
  String? get householdId => _household?.id;
  bool get hasHousehold => _household != null;
  String? get uid => _uid;

  /// Active members, owner first.
  List<HouseholdMember> get members =>
      _members.where((m) => m.isActive).toList()
        ..sort((a, b) => a.isOwner == b.isOwner ? 0 : (a.isOwner ? -1 : 1));

  /// Every member document, including former members.
  List<HouseholdMember> get allMembers => _members;
  List<HouseholdInvitation> get invitations => _invitations;

  HouseholdMember? get currentMember {
    for (final m in _members) {
      if (m.uid == _uid) return m;
    }
    return null;
  }

  bool get isOwner =>
      _household != null && _uid != null && _household!.ownerUid == _uid;

  HouseholdRole? get role => _household == null
      ? null
      : (isOwner ? HouseholdRole.owner : HouseholdRole.member);

  bool get isBusy => _pending != null;

  /// The request in progress, if any.
  HouseholdAction? get pendingAction => _pending;

  /// True while [action] runs (for [target], when given: the member or
  /// invitation the request is about).
  bool isRunning(HouseholdAction action, {String? target}) =>
      _pending == action && (target == null || _pendingTarget == target);

  /// Message from the last failed request.
  String? get error => _error;

  /// One-off information for the user (e.g. access ended); see
  /// [takeNotice].
  String? get notice => _notice;

  /// Household whose cached data should be released, and a counter that
  /// changes every time one is (read by the sync provider).
  String? get releasedHouseholdId => _releasedHouseholdId;
  int get releaseToken => _releaseToken;

  /// Display name of household member [uid], if known.
  String? memberName(String? uid) {
    if (uid == null) return null;
    for (final m in _members) {
      if (m.uid == uid) return m.name;
    }
    return null;
  }

  String? takeNotice() {
    final n = _notice;
    _notice = null;
    return n;
  }

  // ------------------------------------------------------------ auth wiring

  void updateAuth(AuthProvider auth) {
    final user = auth.isAuthenticated ? auth.user : null;
    _userEmail = user?.email;
    _user = user;
    final uid = user?.uid;
    if (uid == _uid) {
      _syncMemberProfile();
      return;
    }
    _profileSyncKey = null;
    _uid = uid;
    _cancelAll();
    _household = null;
    _members = const [];
    _invitations = const [];
    _error = null;
    if (_service == null) return;
    if (uid == null) {
      _phase = HouseholdPhase.signedOut;
      _notifyLater();
      return;
    }
    final cached = HouseholdCache.fromJson(_prefs.getString(_cacheKey(uid)));
    if (cached != null) {
      _household = cached.household;
      _members = cached.members;
      _phase = HouseholdPhase.cached;
    } else {
      _phase = HouseholdPhase.loading;
    }
    _membershipSub = _service
        .watchMemberships(uid)
        .listen(
          _onMemberships,
          onError: (Object e) => debugPrint('Membership stream: $e'),
        );
    if (_household != null) _watchHousehold(_household!.id);
    _notifyLater();
  }

  static String _cacheKey(String uid) => '${PrefKeys.householdCachePrefix}$uid';

  void _onMemberships(MembershipUpdate update) {
    final current = _household?.id;
    if (current != null && update.householdIds.contains(current)) {
      if (_phase != HouseholdPhase.ready) {
        _phase = HouseholdPhase.ready;
        _notify();
      }
      return;
    }
    if (current != null) {
      // The server no longer lists this membership.
      _accessLost(current);
    }
    if (update.householdIds.isEmpty) {
      _phase = HouseholdPhase.ready;
      _notify();
      return;
    }
    _select(update.householdIds.first);
  }

  void _select(String householdId) {
    _household = Household(id: householdId, name: '', ownerUid: '');
    _phase = HouseholdPhase.ready;
    _watchHousehold(householdId);
    _notify();
  }

  void _watchHousehold(String id) {
    final service = _service!;
    _householdSub?.cancel();
    _membersSub?.cancel();
    _invitationsSub?.cancel();
    _invitationsSub = null;
    _householdSub = service
        .watchHousehold(id)
        .listen(
          (h) {
            if (h == null) {
              // Deleted, or no longer readable: confirm before releasing.
              unawaited(confirmAccess(id));
              return;
            }
            if (_household?.id != id) return;
            _household = h;
            _syncInvitationListener();
            _saveCache();
            _notify();
          },
          onError: (Object e) {
            debugPrint('Household stream: $e');
            unawaited(confirmAccess(id));
          },
        );
    _membersSub = service.watchMembers(id).listen((list) {
      if (_household?.id != id) return;
      _members = list;
      _saveCache();
      _notify();
      _syncMemberProfile();
    }, onError: (Object e) => debugPrint('Members stream: $e'));
  }

  /// Asks the server to copy the user's current name and photo to their
  /// member document when it is out of date (e.g. after a photo change), so
  /// the other members see it. Member documents are written by Cloud
  /// Functions only. Best effort: a failure is retried on the next change.
  void _syncMemberProfile() {
    final service = _service;
    final householdId = _household?.id;
    final user = _user;
    final me = currentMember;
    if (service == null ||
        householdId == null ||
        user == null ||
        me == null ||
        !me.isActive ||
        me.uid != user.uid) {
      return;
    }
    final photoChanged = (me.photoUrl ?? '') != (user.photoUrl ?? '');
    final nameChanged =
        user.hasName && user.displayName!.trim() != (me.displayName ?? '');
    if (!photoChanged && !nameChanged) return;
    final key = '$householdId|${user.displayName}|${user.photoUrl}';
    if (_profileSyncKey == key) return;
    _profileSyncKey = key;
    unawaited(
      service.refreshMemberProfile(householdId).catchError((Object e) {
        debugPrint('Refreshing the member profile failed: $e');
        if (_profileSyncKey == key) _profileSyncKey = null;
      }),
    );
  }

  /// Only the owner may read invitations.
  void _syncInvitationListener() {
    final id = _household?.id;
    if (id == null || !isOwner) {
      _invitationsSub?.cancel();
      _invitationsSub = null;
      _invitations = const [];
      return;
    }
    _invitationsSub ??= _service!.watchInvitations(id).listen((list) {
      _invitations = list;
      _notify();
    }, onError: (Object e) => debugPrint('Invitations stream: $e'));
  }

  void _saveCache() {
    final uid = _uid;
    final household = _household;
    if (uid == null || household == null || household.ownerUid.isEmpty) {
      return;
    }
    unawaited(
      _prefs.setString(
        _cacheKey(uid),
        HouseholdCache(household: household, members: _members).toJson(),
      ),
    );
  }

  /// Reset App: forgets the household details cached on this device. The
  /// membership itself lives on the server and is untouched; while the
  /// household is being watched its details are cached again from there.
  Future<void> clearDeviceCache() async {
    final uid = _uid;
    if (uid != null) await _prefs.remove(_cacheKey(uid));
  }

  /// Asks the server whether the user is still a member of [householdId]
  /// (e.g. after a refused sync). Releases it only when confirmed.
  Future<void> confirmAccess(String householdId) async {
    final service = _service;
    final uid = _uid;
    if (service == null || uid == null || _household?.id != householdId) {
      return;
    }
    try {
      final update = await service.fetchMemberships(uid);
      if (!update.householdIds.contains(householdId) &&
          _household?.id == householdId) {
        _accessLost(householdId);
        if (update.householdIds.isNotEmpty) {
          _select(update.householdIds.first);
        }
      }
    } on HouseholdException catch (e) {
      // Offline or unknown: keep everything as it is and try again later.
      debugPrint('Could not confirm household access: $e');
    }
  }

  void _accessLost(String householdId, {bool voluntary = false}) {
    voluntary = voluntary || householdId == _leaving;
    final name = _household?.name;
    _invitationsSub?.cancel();
    _householdSub?.cancel();
    _membersSub?.cancel();
    _invitationsSub = _householdSub = _membersSub = null;
    _household = null;
    _members = const [];
    _invitations = const [];
    if (_uid != null) unawaited(_prefs.remove(_cacheKey(_uid!)));
    _releasedHouseholdId = householdId;
    _releaseToken++;
    if (!voluntary) {
      _notice =
          'You no longer have access to '
          '${name == null || name.isEmpty ? 'the household' : '"$name"'}. '
          'Its shared transactions were removed from this device; your '
          'personal data is unchanged.';
    }
    _notify();
  }

  // ---------------------------------------------------------------- actions

  Future<bool> createHousehold(String name) =>
      _run(HouseholdAction.create, () async {
        final id = await _service!.createHousehold(_validName(name));
        if (_household?.id != id) _select(id);
      });

  Future<bool> renameHousehold(String name) => _run(
    HouseholdAction.rename,
    () => _service!.renameHousehold(_requireHousehold(), _validName(name)),
  );

  /// Creates an invitation and returns its code, or null on failure.
  Future<InvitationCode?> createInvitation({String? email}) async {
    InvitationCode? code;
    final ok = await _run(HouseholdAction.invite, () async {
      final trimmed = email?.trim();
      if (trimmed != null &&
          trimmed.isNotEmpty &&
          !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(trimmed)) {
        throw const HouseholdException('Enter a valid email address.');
      }
      code = await _service!.createInvitation(
        _requireHousehold(),
        email: trimmed,
      );
    });
    return ok ? code : null;
  }

  Future<bool> revokeInvitation(String invitationId) => _run(
    HouseholdAction.revoke,
    () => _service!.revokeInvitation(_requireHousehold(), invitationId),
    target: invitationId,
  );

  /// Validates [code] and returns what it leads to, or null (see [error]).
  Future<InvitationPreview?> previewInvitation(String code) async {
    InvitationPreview? preview;
    final ok = await _run(HouseholdAction.join, () async {
      preview = await _service!.previewInvitation(_checkedCode(code));
    });
    return ok ? preview : null;
  }

  static String _checkedCode(String code) {
    final clean = normalizeInvitationCode(code);
    if (clean.length < 8) {
      throw const HouseholdException(
        'Enter the full invitation code you received.',
      );
    }
    return clean;
  }

  Future<bool> acceptInvitation(String code) =>
      _run(HouseholdAction.join, () async {
        final id = await _service!.acceptInvitation(_checkedCode(code));
        if (_household?.id != id) _select(id);
      });

  Future<bool> removeMember(String memberUid) => _run(
    HouseholdAction.removeMember,
    () => _service!.removeMember(_requireHousehold(), memberUid),
    target: memberUid,
  );

  Future<bool> transferOwnership(String newOwnerUid) => _run(
    HouseholdAction.transfer,
    () => _service!.transferOwnership(_requireHousehold(), newOwnerUid),
    target: newOwnerUid,
  );

  /// Leaves the household.
  ///
  /// [prepare] runs first, as part of the same request (so the screen shows
  /// one continuous loading state): callers use it to upload pending shared
  /// changes, and throw a [HouseholdException] to stop before leaving.
  Future<bool> leaveHousehold({Future<void> Function()? prepare}) => _run(
    HouseholdAction.leave,
    () async {
      final id = _requireHousehold();
      if (prepare != null) await prepare();
      // The membership listener may report the change before the call returns.
      _leaving = id;
      try {
        await _service!.leaveHousehold(id);
        if (_household?.id == id) _accessLost(id, voluntary: true);
      } finally {
        _leaving = null;
      }
    },
  );

  Future<bool> deleteHousehold() => _run(HouseholdAction.delete, () async {
    final id = _requireHousehold();
    _leaving = id;
    try {
      await _service!.deleteHousehold(id);
      if (_household?.id == id) _accessLost(id, voluntary: true);
    } finally {
      _leaving = null;
    }
  });

  String _requireHousehold() {
    final id = _household?.id;
    if (id == null) {
      throw const HouseholdException('You are not in a household.');
    }
    return id;
  }

  static String _validName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const HouseholdException('Enter a household name.');
    }
    if (trimmed.length > 40) {
      throw const HouseholdException('Use 40 characters or fewer.');
    }
    return trimmed;
  }

  /// Email of the signed-in user (used to explain email-bound invites).
  String? get userEmail => _userEmail;

  void clearError() {
    if (_error == null) return;
    _error = null;
    _notify();
  }

  /// Runs one request at a time: while one is in flight, further calls
  /// (e.g. repeated taps) return false without reaching the server. The
  /// busy state is always cleared, whether the request succeeds or fails.
  Future<bool> _run(
    HouseholdAction action,
    Future<void> Function() fn, {
    String? target,
  }) async {
    if (_pending != null || _service == null) return false;
    _pending = action;
    _pendingTarget = target;
    _error = null;
    _notify();
    try {
      await fn();
      return true;
    } on HouseholdException catch (e) {
      _error = e.message;
      return false;
    } catch (e, stack) {
      debugPrint('Household action $action failed: $e\n$stack');
      _error = 'Something went wrong. Please try again.';
      return false;
    } finally {
      _pending = null;
      _pendingTarget = null;
      _notify();
    }
  }

  void _cancelAll() {
    _membershipSub?.cancel();
    _householdSub?.cancel();
    _membersSub?.cancel();
    _invitationsSub?.cancel();
    _membershipSub = null;
    _householdSub = null;
    _membersSub = null;
    _invitationsSub = null;
  }

  /// Used from provider updates, which run during a build.
  void _notifyLater() => Future.microtask(_notify);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelAll();
    super.dispose();
  }
}
