import 'package:flutter/material.dart';

import 'package:money_mate/models/app_user.dart';

/// Circular avatar showing the user's profile photo, or their initials when
/// there is no photo or it cannot be loaded (for example while offline).
class UserAvatar extends StatelessWidget {
  const UserAvatar({super.key, required this.user, this.radius = 20});

  final AppUser? user;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = radius * 2;
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      color: scheme.primaryContainer,
      child: user == null
          ? Icon(
              Icons.person_rounded,
              size: radius,
              color: scheme.onPrimaryContainer,
            )
          : Text(
              user!.initials,
              style: TextStyle(
                fontSize: radius * 0.8,
                fontWeight: FontWeight.w700,
                color: scheme.onPrimaryContainer,
              ),
            ),
    );

    return Semantics(
      label: user == null ? 'Profile' : '${user!.name} profile photo',
      image: true,
      child: ClipOval(
        child: user != null && user!.hasPhoto
            ? Image.network(
                user!.photoUrl!,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback,
                loadingBuilder: (_, child, progress) =>
                    progress == null ? child : fallback,
              )
            : fallback,
      ),
    );
  }
}
