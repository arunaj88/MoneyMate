import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/core/services/photo_picker.dart';
import 'package:money_mate/core/services/profile_photo_service.dart';
import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/providers/auth_provider.dart';
import 'package:money_mate/shared/widgets/dialogs.dart';
import 'package:money_mate/shared/widgets/user_avatar.dart';

enum _PhotoChoice { gallery, camera, remove }

/// Lets the signed-in user choose a new profile photo (gallery or camera),
/// preview it, and upload it; or remove the current photo. Progress shows
/// on [AccountAvatar]; the result is reported in a snack bar.
Future<void> changeProfilePhoto(BuildContext context) async {
  final auth = context.read<AuthProvider>();
  final picker = context.read<PhotoPicker?>();
  if (picker == null || !auth.canChangePhoto || auth.isBusy) return;

  final hasPhoto = auth.user?.hasPhoto ?? false;
  final choice = await showModalBottomSheet<_PhotoChoice>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      final scheme = Theme.of(sheetContext).colorScheme;
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
                child: Text(
                  'Profile photo',
                  style: Theme.of(sheetContext).textTheme.titleLarge,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  'Shown on your devices and to your household.',
                  style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              ListTile(
                key: const Key('photoFromGallery'),
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Choose from gallery'),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_PhotoChoice.gallery),
              ),
              if (picker.supports(PhotoSource.camera))
                ListTile(
                  key: const Key('photoFromCamera'),
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: const Text('Take a photo'),
                  onTap: () =>
                      Navigator.of(sheetContext).pop(_PhotoChoice.camera),
                ),
              if (hasPhoto)
                ListTile(
                  key: const Key('removePhoto'),
                  leading: Icon(
                    Icons.delete_outline_rounded,
                    color: scheme.error,
                  ),
                  title: Text(
                    'Remove photo',
                    style: TextStyle(color: scheme.error),
                  ),
                  onTap: () =>
                      Navigator.of(sheetContext).pop(_PhotoChoice.remove),
                ),
              const SizedBox(height: Spacing.sm),
            ],
          ),
        ),
      );
    },
  );
  if (choice == null || !context.mounted) return;

  if (choice == _PhotoChoice.remove) {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove profile photo?',
      message:
          'Your initials will be shown instead, on all your devices and to '
          'your household.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    final ok = await auth.removePhoto();
    if (context.mounted) _report(context, auth, ok, 'Profile photo removed');
    return;
  }

  final source = choice == _PhotoChoice.camera
      ? PhotoSource.camera
      : PhotoSource.gallery;
  if (!await _ensureAccess(context, picker, source) || !context.mounted) {
    return;
  }

  final Uint8List? picked;
  try {
    picked = await picker.pick(source);
  } on ProfilePhotoException catch (e) {
    if (context.mounted) showAppSnackBar(context, e.message, isError: true);
    return;
  } catch (e) {
    debugPrint('Picking a profile photo failed: $e');
    if (context.mounted) {
      showAppSnackBar(
        context,
        'The photo could not be opened. Please try again.',
        isError: true,
      );
    }
    return;
  }
  if (picked == null || !context.mounted) return;

  final prepared = await showDialog<Uint8List>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PhotoPreviewDialog(prepare: () => picker.prepare(picked!)),
  );
  if (prepared == null || !context.mounted) return;
  final ok = await auth.updatePhoto(prepared);
  if (context.mounted) _report(context, auth, ok, 'Profile photo updated');
}

/// Makes sure MoneyMate may open the gallery or camera, asking the user
/// first: MoneyMate explains why it needs access, then the system prompt
/// asks. When access was turned off for good, offers the device settings.
/// Returns true when [source] can be opened.
Future<bool> _ensureAccess(
  BuildContext context,
  PhotoPicker picker,
  PhotoSource source,
) async {
  final camera = source == PhotoSource.camera;
  final thing = camera ? 'the camera' : 'your photos';
  try {
    final access = await picker.checkAccess(source);
    if (access == PhotoAccess.granted) return true;
    if (!context.mounted) return false;

    if (access == PhotoAccess.denied) {
      final proceed = await showConfirmDialog(
        context,
        title: camera ? 'Allow camera access?' : 'Allow access to your photos?',
        message: camera
            ? 'MoneyMate uses the camera only to take your profile photo. '
                  'Nothing is uploaded until you choose "Use photo".'
            : 'MoneyMate needs access to your gallery so you can choose a '
                  'profile photo. Only the photo you pick is uploaded.',
        confirmLabel: 'Continue',
      );
      if (!proceed || !context.mounted) return false;
      final result = await picker.requestAccess(source);
      if (result == PhotoAccess.granted) return true;
      if (context.mounted) {
        showAppSnackBar(
          context,
          'MoneyMate was not allowed to use $thing, so no photo was chosen.',
          isError: true,
        );
      }
      return false;
    }

    // Turned off earlier: only the device settings can allow it again.
    final open = await showConfirmDialog(
      context,
      title: camera ? 'Camera access is off' : 'Photo access is off',
      message:
          'To ${camera ? 'take' : 'choose'} a profile photo, allow MoneyMate '
          'to use $thing in your device settings, then try again.',
      confirmLabel: 'Open settings',
    );
    if (open && !await picker.openSettings() && context.mounted) {
      showAppSnackBar(
        context,
        'Open your device settings and allow MoneyMate to use $thing.',
        isError: true,
      );
    }
    return false;
  } catch (e) {
    debugPrint('Checking photo permission failed: $e');
    if (context.mounted) {
      showAppSnackBar(
        context,
        'MoneyMate could not check access to $thing. Please try again.',
        isError: true,
      );
    }
    return false;
  }
}

void _report(BuildContext context, AuthProvider auth, bool ok, String done) {
  if (ok) {
    showAppSnackBar(context, done);
  } else if (auth.error != null) {
    showAppSnackBar(context, auth.error!, isError: true);
    auth.clearError();
  }
}

/// Prepares the picked photo (square crop, downscale, compression) and
/// shows it as it will appear. Pops the prepared JPEG on "Use photo".
class PhotoPreviewDialog extends StatefulWidget {
  const PhotoPreviewDialog({super.key, required this.prepare});

  final Future<Uint8List> Function() prepare;

  @override
  State<PhotoPreviewDialog> createState() => _PhotoPreviewDialogState();
}

class _PhotoPreviewDialogState extends State<PhotoPreviewDialog> {
  late final Future<Uint8List> _prepared = widget.prepare();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<Uint8List>(
      future: _prepared,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        final Widget content;
        if (snapshot.hasError) {
          final error = snapshot.error;
          content = Text(
            error is ProfilePhotoException
                ? error.message
                : 'That photo could not be used. Try a different one.',
            key: const Key('photoPreviewError'),
            style: TextStyle(color: theme.colorScheme.error),
          );
        } else if (bytes == null) {
          content = const SizedBox(
            height: 160,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: Spacing.md),
                  Text('Preparing photo…'),
                ],
              ),
            ),
          );
        } else {
          content = Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipOval(
                child: Image.memory(
                  bytes,
                  key: const Key('photoPreview'),
                  width: 160,
                  height: 160,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  semanticLabel: 'New profile photo preview',
                ),
              ),
              const SizedBox(height: Spacing.md),
              Text(
                'Cropped to a square and resized for upload.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          );
        }
        return AlertDialog(
          scrollable: true,
          title: const Text('New profile photo'),
          content: Center(child: content),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(snapshot.hasError ? 'Close' : 'Cancel'),
            ),
            if (!snapshot.hasError)
              FilledButton(
                key: const Key('usePhotoButton'),
                style: FilledButton.styleFrom(minimumSize: const Size(64, 40)),
                onPressed: bytes == null
                    ? null
                    : () => Navigator.of(context).pop(bytes),
                child: const Text('Use photo'),
              ),
          ],
        );
      },
    );
  }
}

/// The account avatar in Settings: a camera badge when the photo can be
/// changed, and upload progress while a change is saved.
class AccountAvatar extends StatelessWidget {
  const AccountAvatar({super.key, this.radius = 24});

  final double radius;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final scheme = Theme.of(context).colorScheme;
    final saving =
        auth.isRunning(AuthAction.updatePhoto) ||
        auth.isRunning(AuthAction.removePhoto);
    final canEdit = auth.canChangePhoto && context.read<PhotoPicker?>() != null;
    final size = radius * 2;
    final badge = radius * 0.8;

    return SizedBox.square(
      dimension: size + 4,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          UserAvatar(user: auth.user, radius: radius),
          if (saving) ...[
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.surface.withValues(alpha: 0.6),
              ),
            ),
            SizedBox.square(
              key: const Key('photoProgress'),
              dimension: size + 4,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                value: auth.isRunning(AuthAction.updatePhoto)
                    ? auth.photoProgress
                    : null,
                semanticsLabel: 'Saving profile photo',
              ),
            ),
          ] else if (canEdit)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                width: badge,
                height: badge,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.surface, width: 2),
                ),
                child: Icon(
                  Icons.photo_camera_rounded,
                  size: badge * 0.55,
                  color: scheme.onPrimary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
