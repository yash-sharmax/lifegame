/// v2.11.0 messaging tests — pure rules, no Appwrite, no network.
///
/// Covers the rules the user set on 18 Nov 2026: 12-hour auto-delete
/// + 150-message rolling cap, the 50-save free-tier cap, the DM
/// request flow, per-chat PIN locks, the hidden-chat keyword, link
/// detection + Open Graph parsing, Private Chat rules, and the
/// end-to-end encryption round-trip.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lifegame/data/chat_crypto.dart';
import 'package:lifegame/data/messaging_models.dart';

DmMessage _msg(String id, DateTime at) => DmMessage(
  id: id,
  conversationId: 'c1',
  senderId: 'u1',
  createdAt: at,
  expiresAt: messageExpiresAt(at),
);

void main() {
  group('auto-delete (12h) + 150-message cap', () {
    test('a message expires exactly 12 hours after it was sent', () {
      final created = DateTime(2026, 11, 19, 10, 30);
      expect(messageExpiresAt(created), DateTime(2026, 11, 19, 22, 30));
    });

    test('isMessageExpired flips only after the expiry time', () {
      final created = DateTime(2026, 11, 19, 10, 0);
      final expires = messageExpiresAt(created);
      expect(isMessageExpired(expires, DateTime(2026, 11, 19, 21, 59)), isFalse);
      expect(isMessageExpired(expires, DateTime(2026, 11, 19, 22, 0, 1)), isTrue);
    });

    test('over the cap, the oldest NON-starred messages go first', () {
      final base = DateTime(2026, 11, 19);
      final messages = List.generate(
        155,
        (i) => _msg('m$i', base.add(Duration(minutes: i))),
      );
      // Star 5 of the oldest — they must survive.
      final starred = {'m0', 'm1', 'm2', 'm3', 'm4'};
      final doomed = messagesToDeleteForCap(messages, starredIds: starred);
      // 155 total, 5 starred → 150 non-starred is exactly the cap,
      // so nothing deletes yet.
      expect(doomed, isEmpty);

      final more = List.generate(
        160,
        (i) => _msg('m$i', base.add(Duration(minutes: i))),
      );
      final doomed2 = messagesToDeleteForCap(more, starredIds: starred);
      // 155 non-starred, cap 150 → 5 oldest non-starred go.
      expect(doomed2.map((m) => m.id).toList(), [
        'm5',
        'm6',
        'm7',
        'm8',
        'm9',
      ]);
      expect(doomed2.any((m) => starred.contains(m.id)), isFalse);
    });

    test('within the cap nothing is deleted', () {
      final base = DateTime(2026, 11, 19);
      final messages = List.generate(
        100,
        (i) => _msg('m$i', base.add(Duration(minutes: i))),
      );
      expect(
        messagesToDeleteForCap(messages, starredIds: {}),
        isEmpty,
      );
    });
  });

  group('save cap (50)', () {
    test('49 saved → one more allowed; 50 → blocked', () {
      expect(canSaveMore(49), isTrue);
      expect(canSaveMore(50), isFalse);
      expect(canSaveMore(51), isFalse);
    });
  });

  group('DM request flow', () {
    test('mutual follows chat directly; one-sided starts as a request', () {
      expect(dmStatus(mutual: true), 'active');
      expect(dmStatus(mutual: false), 'requested');
    });

    test('following them is required to message them', () {
      expect(canMessage(iFollowThem: true), isTrue);
      expect(canMessage(iFollowThem: false), isFalse);
    });
  });

  group('chat lock PIN', () {
    test('the right PIN verifies, the wrong one does not', () {
      const pin = '2468';
      final hash = hashChatPin(pin, 'conv-1');
      expect(verifyChatPin('2468', 'conv-1', hash), isTrue);
      expect(verifyChatPin('2469', 'conv-1', hash), isFalse);
      expect(verifyChatPin('2468', 'conv-2', hash), isFalse);
    });

    test('the hash never contains the PIN itself', () {
      final hash = hashChatPin('2468', 'conv-1');
      expect(hash.contains('2468'), isFalse);
      expect(hash.length, 64); // SHA-256 hex
    });
  });

  group('hidden chats', () {
    test('only the exact keyword reveals a hidden chat', () {
      expect(matchesHiddenKeyword('mango', 'mango'), isTrue);
      expect(matchesHiddenKeyword('  Mango  ', 'mango'), isTrue);
      expect(matchesHiddenKeyword('mang', 'mango'), isFalse);
      expect(matchesHiddenKeyword('mango chat', 'mango'), isFalse);
      expect(matchesHiddenKeyword('', 'mango'), isFalse);
      expect(matchesHiddenKeyword('mango', ''), isFalse);
    });
  });

  group('links', () {
    test('extractUrls finds http(s) and www links, strips punctuation', () {
      expect(
        extractUrls('see https://yashx.xyz/lifegame. and www.google.com!'),
        ['https://yashx.xyz/lifegame', 'www.google.com'],
      );
      expect(extractUrls('no links here'), isEmpty);
      expect(
        extractUrls('(check https://example.com/a_(b)) done'),
        ['https://example.com/a_(b'],
      );
    });

    test('parseOpenGraph reads og tags, falls back to <title>', () {
      const html = '''
<html><head>
<meta property="og:title" content="Life Game">
<meta property="og:description" content="Small steps, every day.">
<meta property="og:image" content="https://example.com/cover.png">
<title>Fallback title</title>
</head></html>''';
      final preview = parseOpenGraph(html);
      expect(preview.title, 'Life Game');
      expect(preview.description, 'Small steps, every day.');
      expect(preview.imageUrl, 'https://example.com/cover.png');

      const noOg =
          '<html><head><title>Only a title</title></head></html>';
      expect(parseOpenGraph(noOg).title, 'Only a title');
      expect(parseOpenGraph('<html></html>').isEmpty, isTrue);
    });
  });

  group('private chat', () {
    test('nothing can be starred while Private Chat is off', () {
      expect(canStarInChat(privateChatOn: true), isTrue);
      expect(canStarInChat(privateChatOn: false), isFalse);
    });

    test('Private Chat off purges the session history on leaving', () {
      expect(shouldPurgeHistoryOnLeave(privateChatOn: true), isFalse);
      expect(shouldPurgeHistoryOnLeave(privateChatOn: false), isTrue);
    });
  });

  group('message display', () {
    test('deleted messages show a tombstone, never the old body', () {
      final deleted = DmMessage(
        id: 'm1',
        conversationId: 'c1',
        senderId: 'u1',
        createdAt: DateTime(2026, 11, 19),
        expiresAt: DateTime(2026, 11, 19, 12),
        text: 'secret',
        deletedForAll: true,
      );
      expect(deleted.displayText, 'This message was deleted');
    });

    test('an encrypted message I cannot decrypt says so honestly', () {
      final locked = DmMessage(
        id: 'm1',
        conversationId: 'c1',
        senderId: 'u1',
        createdAt: DateTime(2026, 11, 19),
        expiresAt: DateTime(2026, 11, 19, 12),
        encrypted: true,
        ciphertext: 'iv:cipher',
        encryptedKeys: '{}',
      );
      expect(locked.displayText, contains('cannot decrypt'));
    });
  });

  group('end-to-end encryption', () {
    test('round-trip: recipient reads it, a stranger cannot', () {
      // 1024-bit keys keep the test fast; the app uses 2048-bit.
      final alice = generateKeypairSync(bits: 1024);
      final bob = generateKeypairSync(bits: 1024);
      final carol = generateKeypairSync(bits: 1024);

      final envelope = encryptForRecipients('meet at 6pm', {
        'alice': alice.publicKeyJson,
        'bob': bob.publicKeyJson,
      });
      expect(envelope.ciphertext, isNotEmpty);
      expect(envelope.encryptedKeysJson, contains('bob'));

      final forBob = decryptEnvelope(
        envelope.ciphertext,
        envelope.encryptedKeysJson,
        'bob',
        bob.privateKeyJson,
      );
      expect(forBob, 'meet at 6pm');

      // Carol was never a recipient: nothing to unwrap.
      final forCarol = decryptEnvelope(
        envelope.ciphertext,
        envelope.encryptedKeysJson,
        'carol',
        carol.privateKeyJson,
      );
      expect(forCarol, isNull);

      // Tampered ciphertext does not decrypt to garbage — it fails.
      final tampered = decryptEnvelope(
        '${envelope.ciphertext}AAAA',
        envelope.encryptedKeysJson,
        'bob',
        bob.privateKeyJson,
      );
      expect(tampered, isNull);
    });

    test('no recipient keys → StateError (caller falls back to plaintext)', () {
      expect(
        () => encryptForRecipients('hi', {}),
        throwsStateError,
      );
    });
  });
}
