import 'dart:async';

import 'package:money_mate/core/services/household_service.dart';
import 'package:money_mate/models/household_models.dart';

/// In-memory [HouseholdService] that behaves like the Cloud Functions for
/// one signed-in user. Set [offline] to make every request fail like an
/// unreachable server.
class FakeHouseholdService implements HouseholdService {
  FakeHouseholdService({this.uid = 'uid-1'});

  final String uid;
  bool offline = false;

  /// When set, every request waits for it to complete before answering,
  /// like a slow network.
  Completer<void>? gate;

  final _memberships = StreamController<MembershipUpdate>.broadcast();
  final _households = StreamController<Household?>.broadcast();
  final _members = StreamController<List<HouseholdMember>>.broadcast();
  final _invitations = StreamController<List<HouseholdInvitation>>.broadcast();

  List<String> membershipIds = [];
  Household? household;
  List<HouseholdMember> members = [];
  List<HouseholdInvitation> invitations = [];

  /// Codes that can be accepted, with the household they lead to.
  final Map<String, Household> codes = {};
  final List<String> calls = [];

  Future<void> _check() async {
    if (gate != null) await gate!.future;
    if (offline) {
      throw const HouseholdException(
        'You are offline. Connect to the internet and try again.',
        code: 'unavailable',
      );
    }
  }

  /// Simulates the server removing this user from the household.
  void removeCurrentUser() {
    membershipIds = [];
    _memberships.add(MembershipUpdate(membershipIds));
  }

  void _publish() {
    _memberships.add(MembershipUpdate(membershipIds));
    _households.add(household);
    _members.add(members);
    _invitations.add(invitations);
  }

  HouseholdMember _me(HouseholdRole role) => HouseholdMember(
    uid: uid,
    role: role,
    status: MembershipStatus.active,
    displayName: 'Sam Lee',
    email: 'sam.lee@example.com',
  );

  @override
  Stream<MembershipUpdate> watchMemberships(String uid) async* {
    yield MembershipUpdate(membershipIds);
    yield* _memberships.stream;
  }

  @override
  Future<MembershipUpdate> fetchMemberships(String uid) async {
    await _check();
    return MembershipUpdate(membershipIds);
  }

  @override
  Stream<Household?> watchHousehold(String householdId) async* {
    yield household?.id == householdId ? household : null;
    yield* _households.stream;
  }

  @override
  Stream<List<HouseholdMember>> watchMembers(String householdId) async* {
    yield members;
    yield* _members.stream;
  }

  @override
  Stream<List<HouseholdInvitation>> watchInvitations(
    String householdId,
  ) async* {
    yield invitations;
    yield* _invitations.stream;
  }

  @override
  Future<String> createHousehold(String name) async {
    calls.add('create');
    await _check();
    if (membershipIds.isNotEmpty) {
      throw const HouseholdException('You are already in a household.');
    }
    household = Household(id: 'house-1', name: name, ownerUid: uid);
    members = [_me(HouseholdRole.owner)];
    membershipIds = ['house-1'];
    _publish();
    return 'house-1';
  }

  @override
  Future<void> renameHousehold(String householdId, String name) async {
    await _check();
    household = Household(id: householdId, name: name, ownerUid: uid);
    _publish();
  }

  @override
  Future<InvitationCode> createInvitation(
    String householdId, {
    String? email,
    int expiresInDays = 7,
  }) async {
    calls.add('invite');
    await _check();
    const code = 'K7QM2XRP9D';
    invitations = [
      HouseholdInvitation(
        id: 'inv-1',
        status: InvitationStatus.pending,
        expiresAt: DateTime.now().add(Duration(days: expiresInDays)),
        code: code,
        invitedEmail: email,
      ),
    ];
    _publish();
    return InvitationCode(
      invitationId: 'inv-1',
      code: code,
      expiresAt: DateTime.now().add(Duration(days: expiresInDays)),
    );
  }

  @override
  Future<void> revokeInvitation(String householdId, String invitationId) async {
    await _check();
    invitations = [];
    _publish();
  }

  @override
  Future<InvitationPreview> previewInvitation(String code) async {
    calls.add('preview:$code');
    await _check();
    final target = codes[code];
    if (target == null) {
      throw const HouseholdException('This invitation code is not valid.');
    }
    return InvitationPreview(
      householdName: target.name,
      invitedByName: 'Sara',
      expiresAt: DateTime.now().add(const Duration(days: 3)),
    );
  }

  @override
  Future<String> acceptInvitation(String code) async {
    calls.add('accept:$code');
    await _check();
    final target = codes.remove(code);
    if (target == null) {
      throw const HouseholdException('This invitation has already been used.');
    }
    household = target;
    members = [
      HouseholdMember(
        uid: target.ownerUid,
        role: HouseholdRole.owner,
        status: MembershipStatus.active,
        displayName: 'Sara Khan',
      ),
      _me(HouseholdRole.member),
    ];
    membershipIds = [target.id];
    _publish();
    return target.id;
  }

  @override
  Future<void> removeMember(String householdId, String memberUid) async {
    await _check();
    members = [
      for (final m in members)
        if (m.uid != memberUid) m,
    ];
    _publish();
  }

  @override
  Future<void> leaveHousehold(String householdId) async {
    calls.add('leave');
    await _check();
    membershipIds = [];
    household = null;
    _publish();
  }

  @override
  Future<void> transferOwnership(String householdId, String newOwnerUid) async {
    await _check();
    household = Household(
      id: householdId,
      name: household!.name,
      ownerUid: newOwnerUid,
    );
    _publish();
  }

  @override
  Future<void> deleteHousehold(String householdId) async {
    calls.add('delete');
    await _check();
    membershipIds = [];
    household = null;
    _publish();
  }
}
