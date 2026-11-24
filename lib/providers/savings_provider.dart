import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:money_mate/core/services/cloud_savings_store.dart';
import 'package:money_mate/core/services/cloud_transaction_store.dart';
import 'package:money_mate/core/services/savings_calculator.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/models/savings_model.dart';
import 'package:money_mate/models/scope_models.dart';
import 'package:money_mate/models/sync_models.dart';
import 'package:money_mate/repositories/savings_repository.dart';
import 'package:money_mate/providers/auth_provider.dart';
import 'package:money_mate/providers/transaction_provider.dart';

export 'package:money_mate/repositories/savings_repository.dart' show SavingsException;

/// Savings goals of all three kinds, their history and (for independent
/// shared goals) members and invitations.
///
/// * **Personal** goals belong to the signed-in user. Money put in lowers
///   their personal available balance.
/// * **Household** goals belong to the user's current household (existing
///   household membership decides access). Money put in lowers the
///   household's available balance.
/// * **Shared** goals are independent of households: the creator owns them
///   and invites other MoneyMate users. A contribution is an amount the
///   member *records* as contributed; it does not change anyone's
///   MoneyMate balance, the user's own included.
///
/// Personal and household goals work fully offline. Contributions to
/// shared goals can be recorded offline and are uploaded later. Withdrawals
/// from household and shared goals, and everything that manages a shared
/// goal (creating, editing, members, invitations), need a connection so the
/// latest balance and permissions can be checked. Security rules enforce
/// the same permissions in the cloud.
///
/// The provider reloads when transactions are reloaded after an external
/// change (cloud download, reset, restore). Without a repository the
/// feature is unavailable and hidden.
class SavingsProvider extends ChangeNotifier {
  SavingsProvider(
    this._repository, {
    CloudSavingsStore? cloud,
    Uuid? uuid,
    DateTime Function()? clock,
    Random? random,
  }) : _cloud = cloud,
       _uuid = uuid ?? const Uuid(),
       _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure();

  final SavingsRepository? _repository;
  final CloudSavingsStore? _cloud;
  final Uuid _uuid;
  final DateTime Function() _clock;
  final Random _random;

  List<SavingsGoal> _goals = const [];
  final Map<String, List<SavingsEntry>> _entries = {};
  final Map<String, List<SharedGoalMember>> _members = {};
  final Map<String, List<SharedGoalInvitation>> _sent = {};
  List<SharedGoalInvitation> _received = const [];
  bool _hasLoaded = false;
  bool _isLoading = false;
  String? _error;
  int _version = 0;
  int _localChangeVersion = 0;
  int _syncRequestVersion = 0;
  int? _seenDataVersion;
  int _loadToken = 0;
  bool _disposed = false;

  String? _uid;
  String? _userName;
  String? _email;
  String? _householdId;

  bool get isAvailable => _repository != null;
  bool get hasLoaded => _hasLoaded;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// Signed-in user (needed for household and shared goals).
  String? get uid => _uid;

  /// The user's current household, if any.
  String? get householdId => _householdId;
  bool get hasHousehold => _householdId != null;

  /// Shared goals need an account and the cloud.
  bool get canUseShared => _cloud != null && _uid != null;

  /// Increases whenever the loaded goals change.
  int get version => _version;

  /// Increases after every change made on this device, so sync can upload
  /// it.
  int get localChangeVersion => _localChangeVersion;

  /// Increases when the app should sync straight away (e.g. after joining
  /// a shared goal, to download it).
  int get syncRequestVersion => _syncRequestVersion;

  // ------------------------------------------------------------- goals

  /// Every visible goal: personal, the current household's, and shared.
  /// Household goals of a household the user left are not shown.
  List<SavingsGoal> get goals => [
    for (final g in _goals)
      if (!g.isHousehold || g.householdId == _householdId) g,
  ];

  List<SavingsGoal> goalsOf(SavingsOwnership ownership) => [
    for (final g in goals)
      if (g.ownership == ownership) g,
  ];

  SavingsGoal? goalById(String id) {
    for (final g in _goals) {
      if (g.id == id) return g;
    }
    return null;
  }

  SavingsSummary summaryOf(SavingsOwnership ownership) =>
      SavingsCalculator.summarize(goalsOf(ownership));

  /// All visible goals together (for the overall figures only; the
  /// balances of the three kinds are never combined anywhere else).
  SavingsSummary get overallSummary => SavingsCalculator.summarize(goals);

  /// Personal goals' total, taken out of the personal available balance.
  int get personalSavedMinor =>
      summaryOf(SavingsOwnership.personal).totalSavedMinor;

  /// The current household's goals' total, taken out of the household's
  /// available balance.
  int get householdSavedMinor =>
      summaryOf(SavingsOwnership.household).totalSavedMinor;

  /// Shared goals' total (all members' recorded contributions).
  int get sharedSavedMinor =>
      summaryOf(SavingsOwnership.shared).totalSavedMinor;

  /// What the user recorded in shared goals (net of their withdrawals).
  int get mySharedContributionMinor => goalsOf(
    SavingsOwnership.shared,
  ).fold(0, (sum, g) => sum + g.myContributionMinor);

  /// Money set aside from the balance shown for [scope]: personal goals for
  /// the personal view, that household's goals for the household view.
  /// Shared goals never reduce a balance.
  int savedForScope(ScopeFilter scope) {
    if (scope.includePersonal) return personalSavedMinor;
    return _goals
        .where((g) => g.isHousehold && g.householdId == scope.householdId)
        .fold(0, (sum, g) => sum + g.savedMinor);
  }

  /// Cached history of [goalId] (null until [loadEntries] finished).
  List<SavingsEntry>? entriesFor(String goalId) => _entries[goalId];

  /// How much each person put in, largest first (from the loaded history).
  List<MemberContribution> contributionsOf(String goalId) {
    final entries = _entries[goalId] ?? const <SavingsEntry>[];
    final byUser = <String?, ({String name, int dep, int wd})>{};
    for (final e in entries) {
      final current = byUser[e.userUid];
      final name = e.userUid != null && e.userUid == _uid
          ? 'You'
          : current?.name ?? e.userName ?? _memberName(goalId, e.userUid);
      byUser[e.userUid] = (
        name: name,
        dep: (current?.dep ?? 0) + (e.isDeposit ? e.amountMinor : 0),
        wd: (current?.wd ?? 0) + (e.isDeposit ? 0 : e.amountMinor),
      );
    }
    return [
      for (final MapEntry(key: uid, value: v) in byUser.entries)
        MemberContribution(
          uid: uid,
          name: v.name,
          depositedMinor: v.dep,
          withdrawnMinor: v.wd,
        ),
    ]..sort((a, b) => b.netMinor.compareTo(a.netMinor));
  }

  String _memberName(String goalId, String? uid) {
    for (final m in _members[goalId] ?? const <SharedGoalMember>[]) {
      if (m.uid == uid) return m.name;
    }
    return uid == null ? 'Earlier entries' : 'Former member';
  }

  // ---------------------------------------------------------- permissions

  List<SharedGoalMember> membersOf(String goalId) =>
      _members[goalId] ?? const [];

  SharedGoalMember? myMembership(String goalId) {
    for (final m in membersOf(goalId)) {
      if (m.uid == _uid) return m;
    }
    return null;
  }

  bool isOwner(SavingsGoal goal) =>
      goal.isShared ? goal.ownerUid != null && goal.ownerUid == _uid : true;

  /// Personal: always. Household: any member (as with shared transactions).
  /// Shared: the owner only.
  bool canManage(SavingsGoal goal) => switch (goal.ownership) {
    SavingsOwnership.personal => true,
    SavingsOwnership.household => goal.householdId == _householdId,
    SavingsOwnership.shared => isOwner(goal),
  };

  bool canContribute(SavingsGoal goal) => switch (goal.ownership) {
    SavingsOwnership.personal => true,
    SavingsOwnership.household => goal.householdId == _householdId,
    SavingsOwnership.shared => myMembership(goal.id)?.mayContribute ?? false,
  };

  bool canWithdraw(SavingsGoal goal) => switch (goal.ownership) {
    SavingsOwnership.personal => true,
    SavingsOwnership.household => goal.householdId == _householdId,
    SavingsOwnership.shared =>
      isOwner(goal) || (myMembership(goal.id)?.mayWithdraw ?? false),
  };

  // ---------------------------------------------------------- invitations

  /// Invitations the owner sent for [goalId] (as last loaded).
  List<SharedGoalInvitation> sentInvitationsOf(String goalId) =>
      _sent[goalId] ?? const [];

  /// Open invitations addressed to the user's email.
  List<SharedGoalInvitation> get receivedInvitations => [
    for (final i in _received)
      if (i.isOpenAt(_clock()) && i.invitedBy != _uid) i,
  ];

  // ------------------------------------------------------------ lifecycle

  /// Called by the ProxyProvider whenever sign-in or transactions change.
  void attach(AuthProvider auth, TransactionProvider transactions) {
    final user = auth.isAuthenticated ? auth.user : null;
    _setContext(
      uid: user?.uid,
      name: user?.name,
      email: user?.email,
      householdId: transactions.householdId,
      dataVersion: transactions.dataVersion,
    );
  }

  /// Sets the signed-in user and household directly (tests).
  @visibleForTesting
  Future<void> setContextForTesting({
    String? uid,
    String? name,
    String? email,
    String? householdId,
  }) async {
    _setContext(
      uid: uid,
      name: name,
      email: email,
      householdId: householdId,
      dataVersion: _seenDataVersion,
    );
    await load();
  }

  void _setContext({
    required String? uid,
    required String? name,
    required String? email,
    required String? householdId,
    required int? dataVersion,
  }) {
    if (!isAvailable) return;
    final uidChanged = uid != _uid;
    final householdChanged = householdId != _householdId;
    _uid = uid;
    _userName = name;
    _email = email?.trim().toLowerCase();
    _householdId = householdId;
    if (uidChanged || householdChanged) {
      _version++;
      Future.microtask(_notify);
    }
    if (dataVersion == _seenDataVersion && !uidChanged) return;
    _seenDataVersion = dataVersion;
    // Deferred: this runs while the provider tree is building.
    Future.microtask(load);
  }

  Future<void> load() async {
    final repository = _repository;
    if (repository == null) return;
    final token = ++_loadToken;
    _isLoading = true;
    _notify();
    try {
      final goals = await repository.getGoals(uid: _uid);
      final members = <String, List<SharedGoalMember>>{};
      for (final g in goals.where((g) => g.isShared)) {
        members[g.id] = await repository.getMembers(g.id);
      }
      final received = await repository.getInvitations();
      if (token != _loadToken) return;
      _goals = List.unmodifiable(goals);
      _members
        ..clear()
        ..addAll(members);
      _received = received;
      _version++;
      _error = null;
      // Histories may have changed too (e.g. downloaded from the cloud).
      for (final id in _entries.keys.toList()) {
        if (goalById(id) == null) {
          _entries.remove(id);
        } else {
          _entries[id] = List.unmodifiable(await repository.getEntries(id));
        }
      }
    } catch (e) {
      if (token != _loadToken) return;
      _error = 'Could not load your savings goals.';
      debugPrint('SavingsProvider.load failed: $e');
    } finally {
      if (token == _loadToken) {
        _isLoading = false;
        _hasLoaded = true;
        _notify();
      }
    }
  }

  /// Loads [goalId]'s contribution / withdrawal history.
  Future<void> loadEntries(String goalId) async {
    final repository = _repository;
    if (repository == null) return;
    _entries[goalId] = List.unmodifiable(await repository.getEntries(goalId));
    _notify();
  }

  // ----------------------------------------------------------------- goals

  /// Creates an active goal of [ownership]. Personal and household goals
  /// are saved on the device (and synced later); a shared goal is created
  /// in the cloud straight away, with the user as its owner. Throws
  /// [SavingsException] for invalid input or missing access.
  Future<SavingsGoal> createGoal({
    SavingsOwnership ownership = SavingsOwnership.personal,
    required String name,
    required SavingsPurpose purpose,
    String customPurpose = '',
    required int targetMinor,
    DateTime? targetDate,
    String notes = '',
  }) async {
    final repository = _requireRepository();
    final now = _clock();
    _validateGoal(name: name, targetMinor: targetMinor);
    _validateTargetDate(targetDate, now);
    if (ownership == SavingsOwnership.household && _householdId == null) {
      throw const SavingsException(
        'Join or create a household to add household goals.',
      );
    }
    if (ownership != SavingsOwnership.personal && _uid == null) {
      throw const SavingsException('Sign in to create shared goals.');
    }
    final goal = SavingsGoal(
      id: _uuid.v4(),
      name: name.trim(),
      purpose: purpose,
      customPurpose: purpose == SavingsPurpose.other
          ? customPurpose.trim()
          : '',
      targetMinor: targetMinor,
      targetDate: targetDate == null ? null : PeriodUtils.dateOnly(targetDate),
      notes: notes.trim(),
      createdAt: now,
      updatedAt: now,
      ownership: ownership,
      householdId: ownership == SavingsOwnership.household
          ? _householdId
          : null,
      ownerUid: _uid,
      createdBy: _uid,
      createdByName: _userName,
      updatedBy: _uid,
    );
    if (ownership == SavingsOwnership.shared) {
      final owner = SharedGoalMember(
        goalId: goal.id,
        uid: _uid!,
        role: SharedGoalRole.owner,
        canWithdraw: true,
        displayName: _userName,
        email: _email,
        joinedAt: now,
      );
      await _online(() => _requireCloud().createSharedGoal(goal, owner));
      await repository.insertGoal(goal, synced: true);
      await repository.replaceMembers(goal.id, [owner]);
      await _afterLocalChange();
    } else {
      await repository.insertGoal(goal);
      await _afterLocalChange(upload: true);
    }
    return goalById(goal.id) ?? goal;
  }

  /// Saves edited details of [goal]. A target date may stay in the past
  /// only if it was not changed.
  Future<void> updateGoal(
    SavingsGoal goal, {
    required String name,
    required SavingsPurpose purpose,
    String customPurpose = '',
    required int targetMinor,
    DateTime? targetDate,
    String notes = '',
  }) async {
    final now = _clock();
    _validateGoal(name: name, targetMinor: targetMinor);
    final date = targetDate == null ? null : PeriodUtils.dateOnly(targetDate);
    if (date != goal.targetDate) _validateTargetDate(date, now);
    await _saveGoal(
      goal.copyWith(
        name: name.trim(),
        purpose: purpose,
        customPurpose: purpose == SavingsPurpose.other
            ? customPurpose.trim()
            : '',
        targetMinor: targetMinor,
        targetDate: () => date,
        notes: notes.trim(),
        updatedAt: _stamp(goal, now),
        updatedBy: _uid,
      ),
    );
  }

  Future<void> pauseGoal(SavingsGoal goal) =>
      _setStatus(goal, SavingsGoalStatus.paused);

  /// Makes a paused or completed goal active again.
  Future<void> resumeGoal(SavingsGoal goal) =>
      _setStatus(goal, SavingsGoalStatus.active);

  Future<void> completeGoal(SavingsGoal goal) =>
      _setStatus(goal, SavingsGoalStatus.completed);

  Future<void> _setStatus(SavingsGoal goal, SavingsGoalStatus status) async {
    if (goal.status == status) return;
    final now = _clock();
    await _saveGoal(
      goal.copyWith(
        status: status,
        completedAt: () => status == SavingsGoalStatus.completed ? now : null,
        updatedAt: _stamp(goal, now),
        updatedBy: _uid,
      ),
    );
  }

  Future<void> _saveGoal(SavingsGoal updated) async {
    final repository = _requireRepository();
    _checkManage(updated);
    if (updated.isShared) {
      await _online(
        () => _requireCloud()
            .upsertGoals(SavingsPartition.shared(_uid!, updated.id), [
              CloudRecord(
                id: updated.id,
                data: updated.toCloudMap(),
                updatedAtMs: updated.updatedAt.millisecondsSinceEpoch,
              ),
            ]),
      );
      await repository.updateGoal(updated, synced: true);
      await _afterLocalChange();
    } else {
      await repository.updateGoal(updated);
      await _afterLocalChange(upload: true);
    }
  }

  /// Deletes [goal] and its history. Money in a personal or household goal
  /// returns to that available balance. A shared goal is deleted for every
  /// member (owner only).
  Future<void> deleteGoal(SavingsGoal goal) async {
    final repository = _requireRepository();
    _checkManage(goal);
    final now = _clock();
    if (goal.isShared) {
      final at = _stamp(goal, now).millisecondsSinceEpoch;
      await _online(
        () => _requireCloud().upsertGoals(
          SavingsPartition.shared(_uid!, goal.id),
          [CloudRecord.deletion(goal.id, at)],
        ),
      );
      await repository.releaseSharedGoal(goal.id);
      try {
        await _cloud!.forgetSharedGoal(_uid!, goal.id);
      } catch (_) {
        // Tidied up by the next sync.
      }
      _entries.remove(goal.id);
      await _afterLocalChange();
      return;
    }
    await repository.deleteGoal(goal.id, now);
    _entries.remove(goal.id);
    await _afterLocalChange(upload: true);
  }

  // --------------------------------------------------------------- entries

  /// Puts [amountMinor] into [goal]. Only active goals accept money. For a
  /// shared goal this records the user's contribution; it is queued when
  /// offline.
  Future<void> addMoney(
    SavingsGoal goal, {
    required int amountMinor,
    required DateTime date,
    String note = '',
  }) async {
    if (!goal.isActive) {
      throw SavingsException(
        goal.isPaused
            ? 'Resume this goal to add money to it.'
            : 'This goal is completed. Reopen it to add more money.',
      );
    }
    if (!canContribute(goal)) {
      throw const SavingsException(
        'You do not have permission to contribute to this goal.',
      );
    }
    final entry = _newEntry(
      goal,
      SavingsEntryType.deposit,
      amountMinor,
      date,
      note,
    );
    await _requireRepository().addEntry(entry);
    await _afterLocalChange(goalId: goal.id, upload: true);
  }

  /// Takes [amountMinor] out of [goal] (back to available money for
  /// personal and household goals; it is not income). For household and
  /// shared goals the latest balance and permission are checked in the
  /// cloud first, so this needs a connection.
  Future<void> withdrawMoney(
    SavingsGoal goal, {
    required int amountMinor,
    required DateTime date,
    String note = '',
  }) async {
    if (!canWithdraw(goal)) {
      throw const SavingsException(
        'Only the owner, or members the owner allowed, can withdraw from '
        'this goal.',
      );
    }
    if (amountMinor > goal.savedMinor) {
      throw const SavingsException(
        'You cannot withdraw more than is saved in this goal.',
      );
    }
    final entry = _newEntry(
      goal,
      SavingsEntryType.withdrawal,
      amountMinor,
      date,
      note,
    );
    final repository = _requireRepository();
    if (goal.isPersonal) {
      await repository.addEntry(entry);
      await _afterLocalChange(goalId: goal.id, upload: true);
      return;
    }
    final outcome = await _online(
      () => _requireCloud().recordEntry(_partitionOf(goal), entry),
      offlineMessage:
          'Withdrawals from household and shared goals need an internet '
          'connection, so the latest balance can be checked.',
    );
    if (outcome == EntryWriteOutcome.goalMissing) {
      throw const SavingsException('This goal was deleted.');
    }
    await repository.addEntry(entry, synced: true);
    await _afterLocalChange(goalId: goal.id);
  }

  SavingsEntry _newEntry(
    SavingsGoal goal,
    SavingsEntryType type,
    int amountMinor,
    DateTime date,
    String note,
  ) {
    _validateAmount(amountMinor);
    final now = _clock();
    if (PeriodUtils.dateOnly(date).isAfter(PeriodUtils.dateOnly(now))) {
      throw const SavingsException('The date cannot be in the future.');
    }
    if (note.trim().length > SavingsLimits.entryNoteMaxLength) {
      throw const SavingsException('The note is too long.');
    }
    // Today's entries keep the current time so they sort in the order made.
    final when = PeriodUtils.isSameDay(date, now)
        ? now
        : DateTime(date.year, date.month, date.day, 12);
    return SavingsEntry(
      id: _uuid.v4(),
      goalId: goal.id,
      type: type,
      amountMinor: amountMinor,
      date: when,
      note: note.trim(),
      createdAt: now,
      updatedAt: now,
      userUid: _uid,
      userName: _userName,
    );
  }

  /// Removes one entry of a personal goal. Throws [SavingsException] when
  /// removing a contribution would leave less in the goal than was
  /// withdrawn.
  Future<void> deleteEntry(SavingsEntry entry) async {
    final repository = _requireRepository();
    await repository.deleteEntry(entry.id, _clock());
    await _afterLocalChange(goalId: entry.goalId, upload: true);
  }

  // ---------------------------------------------- shared members & invites

  /// Re-reads [goal]'s members (and, for the owner, sent invitations) from
  /// the cloud. Keeps the cached copy when offline.
  Future<void> refreshShared(SavingsGoal goal) async {
    final cloud = _cloud;
    final uid = _uid;
    final repository = _repository;
    if (cloud == null || uid == null || repository == null || !goal.isShared) {
      return;
    }
    try {
      final members = await cloud.fetchSharedMembers(uid, goal.id);
      await repository.replaceMembers(goal.id, members);
      _members[goal.id] = members;
      if (isOwner(goal)) {
        final sent = await cloud.fetchSentInvitations(uid, goal.id);
        await repository.replaceInvitations(sent, goalId: goal.id);
        _sent[goal.id] = sent;
      }
      await _reloadGoals();
      _notify();
    } on CloudUnavailableException {
      _sent[goal.id] ??= await repository.getInvitations(goalId: goal.id);
      _notify();
    } on CloudAccessDeniedException {
      // Removed meanwhile: the next sync removes the goal from this device.
      _requestSync();
    }
  }

  /// Re-reads invitations addressed to the user's email.
  Future<void> refreshReceivedInvitations() async {
    final cloud = _cloud;
    final uid = _uid;
    final email = _email;
    final repository = _repository;
    if (cloud == null || uid == null || email == null || repository == null) {
      return;
    }
    try {
      final received = await cloud.fetchReceivedInvitations(uid, email);
      await repository.replaceInvitations(received);
      _received = received;
      _notify();
    } on CloudUnavailableException {
      // The cached list stays.
    } on CloudAccessDeniedException {
      // Rules not deployed yet: nothing to show.
    }
  }

  /// Invites [email] to [goal] (owner only). The invitee sees it in the
  /// app when signed in with that email, or can use the invitation's code.
  Future<SharedGoalInvitation> inviteByEmail(
    SavingsGoal goal,
    String email,
  ) async {
    final normalized = email.trim().toLowerCase();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(normalized)) {
      throw const SavingsException('Enter a valid email address.');
    }
    if (normalized == _email) {
      throw const SavingsException('You are already in this goal.');
    }
    if (membersOf(
      goal.id,
    ).any((m) => m.isActive && m.email?.toLowerCase() == normalized)) {
      throw const SavingsException('This person is already a member.');
    }
    return _createInvitation(goal, normalized);
  }

  /// Creates a one-time invitation code for [goal] (owner only) that any
  /// signed-in MoneyMate user can use once.
  Future<SharedGoalInvitation> createInviteCode(SavingsGoal goal) =>
      _createInvitation(goal, null);

  Future<SharedGoalInvitation> _createInvitation(
    SavingsGoal goal,
    String? email,
  ) async {
    _checkManage(goal);
    final now = _clock();
    final invitation = SharedGoalInvitation(
      code: _newCode(),
      goalId: goal.id,
      goalName: goal.name,
      invitedEmail: email,
      invitedBy: _uid!,
      invitedByName: _userName,
      createdAt: now,
      expiresAt: now.add(const Duration(days: SavingsLimits.invitationDays)),
    );
    await _online(() => _requireCloud().createInvitation(invitation));
    _sent[goal.id] = [invitation, ...sentInvitationsOf(goal.id)];
    await _repository!.replaceInvitations(_sent[goal.id]!, goalId: goal.id);
    _notify();
    return invitation;
  }

  String _newCode() => String.fromCharCodes(
    List.generate(
      sharedGoalCodeLength,
      (_) => sharedGoalCodeAlphabet.codeUnitAt(
        _random.nextInt(sharedGoalCodeAlphabet.length),
      ),
    ),
  );

  /// Revokes a pending invitation (owner).
  Future<void> revokeInvitation(
    SavingsGoal goal,
    SharedGoalInvitation invitation,
  ) async {
    _checkManage(goal);
    await _online(
      () => _requireCloud().setInvitationStatus(
        _uid!,
        invitation.code,
        SharedInvitationStatus.revoked,
      ),
    );
    await refreshShared(goal);
  }

  /// Looks up the invitation behind a typed [code] and checks the user can
  /// accept it.
  Future<SharedGoalInvitation> previewCode(String code) async {
    final clean = normalizeSharedGoalCode(code);
    if (!isWellFormedSharedGoalCode(clean)) {
      throw const SavingsException('This invitation code is not valid.');
    }
    final invitation = await _online(
      () => _requireCloud().fetchInvitation(_requireUid(), clean),
    );
    if (invitation == null) {
      throw const SavingsException('This invitation code is not valid.');
    }
    _checkUsable(invitation);
    return invitation;
  }

  void _checkUsable(SharedGoalInvitation invitation) {
    switch (invitation.statusAt(_clock())) {
      case SharedInvitationStatus.pending:
        break;
      case SharedInvitationStatus.expired:
        throw const SavingsException(
          'This invitation has expired. Ask for a new one.',
        );
      case SharedInvitationStatus.revoked:
        throw const SavingsException('This invitation was revoked.');
      case SharedInvitationStatus.accepted:
      case SharedInvitationStatus.rejected:
        throw const SavingsException('This invitation was already used.');
    }
    final email = invitation.invitedEmail;
    if (email != null && email != _email) {
      throw const SavingsException(
        'This invitation is for a different email address. Sign in with '
        'that account to accept it.',
      );
    }
    if (invitation.invitedBy == _uid || goalById(invitation.goalId) != null) {
      throw const SavingsException('You are already in this goal.');
    }
  }

  /// Joins the goal of [invitation].
  Future<void> acceptInvitation(SharedGoalInvitation invitation) async {
    _checkUsable(invitation);
    final me = SharedGoalMember(
      goalId: invitation.goalId,
      uid: _requireUid(),
      role: SharedGoalRole.member,
      displayName: _userName,
      email: _email,
      joinedAt: _clock(),
    );
    await _online(() => _requireCloud().acceptInvitation(invitation, me));
    await _dropReceived(invitation);
    _requestSync();
  }

  /// Declines an invitation addressed to the user.
  Future<void> rejectInvitation(SharedGoalInvitation invitation) async {
    await _online(
      () => _requireCloud().setInvitationStatus(
        _requireUid(),
        invitation.code,
        SharedInvitationStatus.rejected,
      ),
    );
    await _dropReceived(invitation);
  }

  Future<void> _dropReceived(SharedGoalInvitation invitation) async {
    _received = [
      for (final i in _received)
        if (i.code != invitation.code) i,
    ];
    await _repository!.replaceInvitations(_received);
    _notify();
  }

  /// Removes [member] from [goal] (owner). They lose access straight away.
  Future<void> removeMember(SavingsGoal goal, SharedGoalMember member) async {
    _checkManage(goal);
    if (member.isOwner) {
      throw const SavingsException('The owner cannot be removed.');
    }
    await _online(
      () => _requireCloud().updateMember(
        _uid!,
        member.copyWith(status: SharedMemberStatus.removed),
      ),
    );
    await refreshShared(goal);
  }

  /// Lets [member] withdraw from [goal], or not (owner).
  Future<void> setCanWithdraw(
    SavingsGoal goal,
    SharedGoalMember member,
    bool allowed,
  ) async {
    _checkManage(goal);
    if (member.isOwner) return;
    await _online(
      () => _requireCloud().updateMember(
        _uid!,
        member.copyWith(canWithdraw: allowed),
      ),
    );
    await refreshShared(goal);
  }

  /// Leaves a shared goal the user does not own. Their past contributions
  /// stay in the goal's history.
  Future<void> leaveGoal(SavingsGoal goal) async {
    final me = myMembership(goal.id);
    if (isOwner(goal) || me == null) {
      throw const SavingsException(
        'The owner cannot leave. Delete the goal instead.',
      );
    }
    await _online(
      () => _requireCloud().updateMember(
        _uid!,
        me.copyWith(status: SharedMemberStatus.left),
      ),
    );
    await _repository!.releaseSharedGoal(goal.id);
    try {
      await _cloud!.forgetSharedGoal(_uid!, goal.id);
    } catch (_) {
      // Tidied up by the next sync.
    }
    _entries.remove(goal.id);
    await _afterLocalChange();
  }

  // ---------------------------------------------------------------- helpers

  SavingsPartition _partitionOf(SavingsGoal goal) => switch (goal.ownership) {
    SavingsOwnership.personal => SavingsPartition.personal(_uid ?? ''),
    SavingsOwnership.household => SavingsPartition.household(
      _requireUid(),
      goal.householdId!,
    ),
    SavingsOwnership.shared => SavingsPartition.shared(_requireUid(), goal.id),
  };

  /// Runs a cloud call, turning connection and permission errors into
  /// messages for the user.
  Future<T> _online<T>(
    Future<T> Function() action, {
    String offlineMessage =
        'This needs an internet connection. Please try again when online.',
  }) async {
    try {
      return await action();
    } on CloudUnavailableException {
      throw SavingsException(offlineMessage);
    } on CloudAccessDeniedException {
      throw const SavingsException(
        'You do not have permission to do this (any more).',
      );
    }
  }

  void _checkManage(SavingsGoal goal) {
    if (!canManage(goal)) {
      throw const SavingsException(
        'Only the owner of this goal can change it.',
      );
    }
    if (goal.isShared) _requireCloud();
  }

  SavingsRepository _requireRepository() {
    final repository = _repository;
    if (repository == null) {
      throw const SavingsException('Savings goals are not available.');
    }
    return repository;
  }

  CloudSavingsStore _requireCloud() {
    final cloud = _cloud;
    if (cloud == null || _uid == null) {
      throw const SavingsException('Sign in to use shared goals.');
    }
    return cloud;
  }

  String _requireUid() {
    final uid = _uid;
    if (uid == null) throw const SavingsException('Please sign in first.');
    return uid;
  }

  static void _validateGoal({required String name, required int targetMinor}) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const SavingsException('Please enter a goal name.');
    }
    if (trimmed.length > SavingsLimits.nameMaxLength) {
      throw const SavingsException('The goal name is too long.');
    }
    if (targetMinor <= 0) {
      throw const SavingsException('The target must be greater than zero.');
    }
    if (targetMinor > Money.maxMinor) {
      throw const SavingsException('The target is too large.');
    }
  }

  static void _validateTargetDate(DateTime? date, DateTime now) {
    if (date == null) return;
    if (PeriodUtils.dateOnly(date).isBefore(PeriodUtils.dateOnly(now))) {
      throw const SavingsException('The target date cannot be in the past.');
    }
  }

  static void _validateAmount(int amountMinor) {
    if (amountMinor <= 0) {
      throw const SavingsException('Amount must be greater than zero.');
    }
    if (amountMinor > Money.maxMinor) {
      throw const SavingsException('Amount is too large.');
    }
  }

  /// A change time strictly after [goal]'s last one, so the newest edit
  /// always wins the last-writer-wins merge, even with clock skew.
  static DateTime _stamp(SavingsGoal goal, DateTime now) =>
      now.isAfter(goal.updatedAt)
      ? now
      : goal.updatedAt.add(const Duration(milliseconds: 1));

  Future<void> _reloadGoals() async {
    _goals = List.unmodifiable(await _repository!.getGoals(uid: _uid));
    _version++;
  }

  Future<void> _afterLocalChange({String? goalId, bool upload = false}) async {
    final repository = _repository!;
    await _reloadGoals();
    for (final g in _goals.where((g) => g.isShared)) {
      _members[g.id] = await repository.getMembers(g.id);
    }
    if (goalId != null) {
      _entries[goalId] = List.unmodifiable(await repository.getEntries(goalId));
    }
    _hasLoaded = true;
    _error = null;
    if (upload) _localChangeVersion++;
    _notify();
  }

  void _requestSync() {
    _syncRequestVersion++;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
