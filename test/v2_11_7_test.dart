/// v2.11.7 tests — the undecryptable-image placeholder must not
/// carry a padlock.
///
/// Live retest (19 Nov ~13:47 UTC, app on v2.11.6): text bubbles
/// carry NO lock icon (correct, v2.11.2 rule), BUT three photo
/// bubbles from the other user rendered as dark tiles with a LARGE
/// CENTERED PADLOCK — photos this device cannot decrypt (per-device
/// E2EE keys; they display fine on the sender's phone). The
/// placeholder in `_photoImage` used `Icons.lock_outline`.
///
/// The fix renders undecryptable images the same honest way text
/// bubbles do: a tile with plain text ("Encrypted photo — this
/// device cannot decrypt it"), no lock icon anywhere on the bubble.
/// Decryptable images and the encryption itself are untouched.
///
/// No Appwrite, no network. The ChatScreen is pumped with a cached
/// encrypted image message (decrypted bytes null) and a hanging
/// service, exactly like the v2.11.6 render test.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifegame/data/local_store.dart';
import 'package:lifegame/data/messaging_models.dart';
import 'package:lifegame/data/messaging_service.dart';
import 'package:lifegame/data/repositories.dart';
import 'package:lifegame/screens/chat_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A [MessagingService] whose network calls never complete, so the
/// test proves what the cached render shows on its own.
class _HangingMessagingService extends MessagingService {
  @override
  Future<void> markRead(String conversationId) =>
      Completer<void>().future;

  @override
  Future<ChatSettings> settingsFor(String conversationId) =>
      Completer<ChatSettings>().future;

  @override
  Future<List<ConversationMember>> memberRows(String conversationId) =>
      Completer<List<ConversationMember>>().future;

  @override
  Future<List<DmMessage>> listMessages(
    String conversationId, {
    int limit = 200,
  }) => Completer<List<DmMessage>>().future;
}

void main() {
  SharedPreferences.setMockInitialValues({});

  void asUser(String uid) {
    AuthRepository.debugSetCachedUserForTest(
      AppAuthUser(uid: uid, email: '$uid@example.com'),
    );
  }

  group('v2.11.7: undecryptable image placeholder has no padlock', () {
    testWidgets('encrypted photo I cannot decrypt shows honest text, '
        'no lock icon', (tester) async {
      asUser('user-1');
      // Seed the real offline cache with an encrypted photo from
      // the other user that this device cannot decrypt: no
      // decrypted bytes, encrypted flag set.
      final store = await LocalStore.getInstance();
      final photo = DmMessage(
        id: 'm-photo',
        conversationId: 'c1',
        senderId: 'user-2',
        createdAt: DateTime.utc(2026, 11, 19, 12, 0),
        expiresAt: DateTime.utc(2026, 11, 20, 0, 0),
        type: 'image',
        imageUrl: 'https://i.ibb.co/test/photo.png',
        encrypted: true,
        ciphertext: 'v2:1:AAAA:BBBB',
        encryptedKeys: '{"user-1":"AAAA"}',
      );
      await store.saveCachedChatMessages('user-1', 'c1', [
        photo.toCacheJson(),
      ]);

      final conversation = Conversation(
        id: 'c1',
        type: 'dm',
        createdBy: 'user-1',
        createdAt: DateTime.utc(2026, 11, 19, 11, 0),
        status: 'requested',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(
            conversation: conversation,
            service: _HangingMessagingService(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      // The honest text treatment, like undecryptable text bubbles.
      expect(
        find.text('Encrypted photo — this device cannot decrypt it'),
        findsOneWidget,
      );
      // No padlock anywhere on the bubble.
      expect(find.byIcon(Icons.lock), findsNothing);
      expect(find.byIcon(Icons.lock_outline), findsNothing);
    });
  });
}
