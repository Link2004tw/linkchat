import 'package:flutter/material.dart';

import '../models/user.dart';

/// Circular avatar with the user's image (when available) or initial, and an
/// optional online/offline status dot.
class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.user,
    this.radius = 20,
    this.showStatusDot = false,
    this.isOnline = false,
    this.onTap,
  });

  final ChatUser user;

  /// CircleAvatar radius (the status dot scales with it).
  final double radius;

  final bool showStatusDot;

  /// Whether the online dot is filled (green) or hollow (gray). Only
  /// meaningful when [showStatusDot] is true.
  final bool isOnline;

  /// When set, tapping the avatar triggers it (e.g. open the user's
  /// profile sheet).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final imageUrl = user.profileImageUrl;
    final hasImage = imageUrl != null && imageUrl.isNotEmpty;
    final initial =
        user.displayName.isNotEmpty ? user.displayName[0].toUpperCase() : '?';

    final avatar = CircleAvatar(
      radius: radius,
      backgroundColor: theme.colorScheme.primaryContainer,
      foregroundImage: hasImage ? NetworkImage(imageUrl) : null,
      child: hasImage ? null : Text(initial),
    );

    final wrapped =
        onTap == null ? avatar : InkWell(customBorder: const CircleBorder(), onTap: onTap, child: avatar);

    if (!showStatusDot) return wrapped;

    final dotRadius = radius * 0.3;
    final dotColor = isOnline ? Colors.green : theme.colorScheme.outline;
    final borderColor = theme.colorScheme.surface;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        wrapped,
        Positioned(
          right: -dotRadius * 0.4,
          bottom: -dotRadius * 0.4,
          child: Container(
            width: dotRadius * 2,
            height: dotRadius * 2,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
              border: Border.all(color: borderColor, width: 2),
            ),
          ),
        ),
      ],
    );
  }
}
