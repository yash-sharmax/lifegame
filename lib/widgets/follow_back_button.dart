// "Follow Back" button (v2.10.0).
//
// Shown next to someone who follows the user (in the Notifications
// "X started following you" rows and in the Followers list) so it is
// obvious this person followed and the user can follow them back.
// Clearly and separately visible — a real button, never hidden in a
// menu.
//
// Behaviour mirrors the app's follow button (search / profile):
// - Not following them → "Follow Back". Tap → follow().
//   A follow on a PUBLIC account lands as 'accepted' ("Following");
//   on a PRIVATE account it is a request ("Requested").
// - Already following → "Following"; a pending request → "Requested".
//   Tapping either unfollows / cancels the request (same toggle as
//   the existing follow button). Following back is what makes two
//   people mutual friends (the Friend Circle).
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import '../theme.dart';
import '../screens/auth_screen.dart';
import 'common.dart';

class FollowBackButton extends StatefulWidget {
  const FollowBackButton({
    super.key,
    required this.profile,
    required this.socialRepo,
  });

  final Profile profile;
  final SocialRepository socialRepo;

  @override
  State<FollowBackButton> createState() => _FollowBackButtonState();
}

class _FollowBackButtonState extends State<FollowBackButton> {
  /// 'none' | 'pending' | 'accepted'.
  String _status = 'none';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    try {
      final status = await widget.socialRepo.followStatus(
        widget.profile.id,
      );
      if (mounted) setState(() => _status = status);
    } catch (_) {
      if (mounted) setState(() => _status = 'none');
    }
  }

  Future<void> _toggle() async {
    if (_busy) return;
    final status = _status;
    setState(() => _busy = true);
    try {
      if (status == 'none') {
        await widget.socialRepo.follow(widget.profile.id);
      } else {
        // Unfollow, or cancel a pending request.
        await widget.socialRepo.unfollow(widget.profile.id);
      }
      if (!mounted) return;
      setState(() => _status = status == 'none' ? 'pending' : 'none');
      // Re-check: a follow on a public account lands as 'accepted',
      // on a private one as 'pending'.
      if (status == 'none') await _check();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isRequested = _status == 'pending';
    final isFollowing = _status == 'accepted';
    final label = isFollowing
        ? 'Following'
        : isRequested
        ? 'Requested'
        : 'Follow Back';
    return FilledButton(
      onPressed: _busy ? null : _toggle,
      style: FilledButton.styleFrom(
        backgroundColor: isFollowing || isRequested
            ? AppTheme.inkSoft
            : AppTheme.ember,
        foregroundColor: AppTheme.onAccent,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
      ),
      child: _busy ? const LoadingIcon(size: 16) : Text(label),
    );
  }
}
