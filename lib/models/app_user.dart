import 'dart:convert';

/// The signed-in user's profile, taken from Firebase Authentication.
class AppUser {
  const AppUser({
    required this.uid,
    this.email,
    this.displayName,
    this.photoUrl,
  });

  /// Firebase UID.
  final String uid;
  final String? email;
  final String? displayName;
  final String? photoUrl;

  bool get hasName => displayName != null && displayName!.trim().isNotEmpty;

  bool get hasPhoto => photoUrl != null && photoUrl!.trim().isNotEmpty;

  /// Name to show in the UI: the display name, else the part of the email
  /// before the @.
  String get name {
    if (hasName) return displayName!.trim();
    final local = email?.split('@').first.trim() ?? '';
    return local.isEmpty ? 'MoneyMate user' : local;
  }

  /// First name, used in greetings.
  String get firstName => name.split(RegExp(r'\s+')).first;

  /// Up to two initials for avatar placeholders.
  String get initials {
    final parts = name
        .split(RegExp(r'[\s._-]+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    String firstChar(String s) => String.fromCharCode(s.runes.first);
    final second = parts.length > 1 ? firstChar(parts[1]) : '';
    return (firstChar(parts.first) + second).toUpperCase();
  }

  /// Fills missing fields from an earlier copy of the same user's profile.
  AppUser mergeMissingFrom(AppUser? other) {
    if (other == null || other.uid != uid) return this;
    return AppUser(
      uid: uid,
      email: email ?? other.email,
      displayName: hasName ? displayName : other.displayName,
      photoUrl: hasPhoto ? photoUrl : other.photoUrl,
    );
  }

  Map<String, Object?> toMap() => {
    'uid': uid,
    'email': email,
    'displayName': displayName,
    'photoUrl': photoUrl,
  };

  String toJson() => jsonEncode(toMap());

  static AppUser? fromJson(String? source) {
    if (source == null || source.isEmpty) return null;
    try {
      final map = jsonDecode(source);
      if (map is! Map<String, dynamic> || map['uid'] is! String) return null;
      return AppUser(
        uid: map['uid'] as String,
        email: map['email'] as String?,
        displayName: map['displayName'] as String?,
        photoUrl: map['photoUrl'] as String?,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is AppUser &&
      other.uid == uid &&
      other.email == email &&
      other.displayName == displayName &&
      other.photoUrl == photoUrl;

  @override
  int get hashCode => Object.hash(uid, email, displayName, photoUrl);
}
