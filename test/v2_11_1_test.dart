/// v2.11.1 tests — pure rules, no Appwrite, no network.
///
/// Covers the three fixes the user asked for on 19 Nov 2026:
/// FIX 1 — tappable Followers/Following lists on OTHER users'
/// profiles (widget test with a fake SocialRepository);
/// FIX 2 — E2EE for images (byte envelope + PNG carrier
/// round-trips, stranger/tamper cases, full pipeline);
/// FIX 3 — per-conversation epoch key rotation (HKDF, epoch
/// ciphertext format, rotation + safe-deletion policy, epoch
/// store mechanics, wrap/unwrap round-trip).
/// Plus the `messages.encryptedKeys` size cap (live attribute is
/// String 5000; code caps the payload at 4800 and fails loudly
/// instead of writing a value Appwrite would reject).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifegame/data/chat_crypto.dart';
import 'package:lifegame/data/models.dart';
import 'package:lifegame/data/png_carrier.dart';
import 'package:lifegame/data/repositories.dart';
import 'package:lifegame/screens/profile_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<int> _patternBytes(int n) =>
    List<int>.generate(n, (i) => (i * 37 + 11) % 256);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FIX 2 — PNG carrier', () {
    test('round-trip for many sizes, including block boundaries', () {
      for (final size in [0, 1, 100, 767, 768, 769, 4096, 70000, 200000]) {
        final original = _patternBytes(size);
        final png = packBytesAsPng(original);
        // A real PNG signature + 256px-wide IHDR.
        expect(png.sublist(0, 8), [
          0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        ]);
        expect(unpackBytesFromPng(png), original);
      }
    });

    test('garbage, truncation and tampering all return null', () {
      expect(unpackBytesFromPng([1, 2, 3]), isNull);
      expect(unpackBytesFromPng(utf8.encode('not a png at all')), isNull);

      final png = packBytesAsPng(_patternBytes(1000));
      expect(unpackBytesFromPng(png.sublist(0, png.length ~/ 2)), isNull);

      // Flip a byte inside the IDAT payload: the Adler-32 check
      // (or the stored-block lengths) must catch it.
      final tampered = List<int>.from(png);
      tampered[100] ^= 0xff;
      expect(unpackBytesFromPng(tampered), isNull);
    });

    test('an ordinary photo is not a carrier (unpack returns null)', () {
      // A minimal 1x1 red PNG (filter 0, compressed blocks) — a
      // real image, but not one of our carriers.
      final realPng = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      );
      expect(unpackBytesFromPng(realPng), isNull);
    });
  });

  group('FIX 2 — image byte envelope', () {
    test('round-trip: recipient reads it, a stranger cannot', () {
      // 1024-bit keys keep the test fast; the app uses 2048-bit.
      final alice = generateKeypairSync(bits: 1024);
      final bob = generateKeypairSync(bits: 1024);
      final carol = generateKeypairSync(bits: 1024);

      final original = _patternBytes(5000);
      final envelope = encryptBytesForRecipients(original, {
        'alice': alice.publicKeyJson,
        'bob': bob.publicKeyJson,
      });
      expect(envelope.ciphertextBytes.length, greaterThan(16));
      expect(envelope.encryptedKeysJson, contains('bob'));

      expect(
        decryptBytesEnvelope(
          envelope.ciphertextBytes,
          envelope.encryptedKeysJson,
          'bob',
          bob.privateKeyJson,
        ),
        original,
      );

      // Carol was never a recipient: nothing to unwrap.
      expect(
        decryptBytesEnvelope(
          envelope.ciphertextBytes,
          envelope.encryptedKeysJson,
          'carol',
          carol.privateKeyJson,
        ),
        isNull,
      );

      // Tampered ciphertext bytes do not decrypt to garbage.
      final tampered = List<int>.from(envelope.ciphertextBytes);
      tampered[20] ^= 0xff;
      expect(
        decryptBytesEnvelope(
          tampered,
          envelope.encryptedKeysJson,
          'bob',
          bob.privateKeyJson,
        ),
        isNull,
      );

      // Tampered wrapped key does not decrypt either. (Corrupt
      // BOB's wrapped key specifically — corrupting another
      // recipient's entry would leave Bob's key untouched.)
      final keysMap =
          jsonDecode(envelope.encryptedKeysJson) as Map<String, dynamic>;
      final bobWrapped = keysMap['bob'] as String;
      keysMap['bob'] = bobWrapped.replaceFirst('A', 'B');
      final badKeys = jsonEncode(keysMap);
      expect(
        decryptBytesEnvelope(
          envelope.ciphertextBytes,
          badKeys,
          'bob',
          bob.privateKeyJson,
        ),
        isNull,
      );
    });

    test('no recipient keys → StateError (caller falls back)', () {
      expect(() => encryptBytesForRecipients([1, 2, 3], {}), throwsStateError);
    });

    test('full image pipeline: encrypt → PNG → unpack → decrypt', () {
      final alice = generateKeypairSync(bits: 1024);
      final bob = generateKeypairSync(bits: 1024);

      final original = _patternBytes(20000);
      final envelope = encryptBytesForRecipients(original, {
        'alice': alice.publicKeyJson,
        'bob': bob.publicKeyJson,
      });
      final carrier = packBytesAsPng(envelope.ciphertextBytes);
      final packed = unpackBytesFromPng(carrier);
      expect(packed, isNotNull);
      expect(
        decryptBytesEnvelope(
          packed!,
          envelope.encryptedKeysJson,
          'bob',
          bob.privateKeyJson,
        ),
        original,
      );
    });
  });

  group('FIX 3 — HKDF + epoch ciphertext format', () {
    test('hkdf is deterministic, purpose-bound and sized', () {
      final a = hkdfSha256(key: [1, 2, 3], info: utf8.encode('a'));
      final b = hkdfSha256(key: [1, 2, 3], info: utf8.encode('a'));
      final c = hkdfSha256(key: [1, 2, 3], info: utf8.encode('b'));
      expect(a, b);
      expect(a, isNot(c));
      expect(a.length, 32);
      expect(hkdfSha256(key: [1, 2, 3], info: utf8.encode('a'), length: 16).length, 16);
    });

    test('epoch message keys depend on the epoch key and the nonce', () {
      final k1 = deriveEpochMessageKey(List.filled(32, 1), [1, 2, 3]);
      final k2 = deriveEpochMessageKey(List.filled(32, 1), [1, 2, 3]);
      final k3 = deriveEpochMessageKey(List.filled(32, 1), [1, 2, 4]);
      final k4 = deriveEpochMessageKey(List.filled(32, 2), [1, 2, 3]);
      expect(k1, k2);
      expect(k1, isNot(k3));
      expect(k1, isNot(k4));
    });

    test('epoch encrypt/decrypt round-trip; wrong key and tampering fail', () {
      final epochKey = List<int>.generate(32, (i) => i);
      final otherKey = List<int>.generate(32, (i) => 255 - i);
      final cipher = encryptWithEpochKey('hello epoch', epochKey, 3);
      expect(decryptWithEpochKey(cipher, epochKey), 'hello epoch');
      expect(decryptWithEpochKey(cipher, otherKey), isNull);
      expect(decryptWithEpochKey('${cipher}AAAA', epochKey), isNull);
    });

    test('epoch ciphertext format round-trips; legacy is not epoch', () {
      final built = buildEpochCiphertext(
        epoch: 2,
        nonce: [1, 2, 3],
        ivCipher: 'aGVsbG8=:d29ybGQ=',
      );
      final parsed = parseEpochCiphertext(built);
      expect(parsed?.epoch, 2);
      expect(parsed?.nonce, [1, 2, 3]);
      expect(parsed?.ivCipher, 'aGVsbG8=:d29ybGQ=');
      // Legacy v2.11.0 format has no prefix.
      expect(parseEpochCiphertext('aGVsbG8=:d29ybGQ='), isNull);
      expect(parseEpochCiphertext('v2:notanumber:AA==:x:y'), isNull);
      expect(parseEpochCiphertext('v2:1:!!!:x:y'), isNull);
      expect(parseEpochCiphertext(null), isNull);
      expect(parseEpochCiphertext(''), isNull);
    });
  });

  group('FIX 3 — rotation + safe-deletion policy', () {
    test('rotates at 100 sent messages or 7 days, not before', () {
      final now = DateTime(2026, 11, 19, 12);
      expect(
        epochNeedsRotation(
          createdAt: DateTime(2026, 11, 19, 11),
          sentCount: 99,
          now: now,
        ),
        isFalse,
      );
      expect(
        epochNeedsRotation(
          createdAt: DateTime(2026, 11, 19, 11),
          sentCount: 100,
          now: now,
        ),
        isTrue,
      );
      expect(
        epochNeedsRotation(
          createdAt: DateTime(2026, 11, 12, 11),
          sentCount: 0,
          now: now,
        ),
        isTrue,
      );
      expect(
        epochNeedsRotation(
          createdAt: DateTime(2026, 11, 12, 12, 0, 1),
          sentCount: 0,
          now: now,
        ),
        isFalse,
      );
    });

    test('an epoch key is safe to delete only after its messages expired', () {
      final now = DateTime(2026, 11, 19, 12);
      expect(
        epochKeySafeToDelete(
          lastMessageAt: DateTime(2026, 11, 19, 0, 0, 1),
          now: now,
        ),
        isFalse,
      );
      expect(
        epochKeySafeToDelete(
          lastMessageAt: DateTime(2026, 11, 19, 0),
          now: now,
        ),
        isTrue,
      );
      expect(
        epochKeySafeToDelete(
          lastMessageAt: DateTime(2026, 11, 18, 23),
          now: now,
        ),
        isTrue,
      );
    });
  });

  group('FIX 3 — epoch store + wrap/unwrap', () {
    test('save / current / delete, and expired cleanup', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = ChatEpochStore.forTest(prefs);
      const conv = 'conv-1';
      final now = DateTime(2026, 11, 19, 12);

      expect(store.currentEpoch(conv), isNull);

      final epoch1 = ChatEpoch(
        epoch: 1,
        keyBase64: base64Encode(List.filled(32, 1)),
        createdAt: DateTime(2026, 11, 18),
        sentCount: 100,
        lastMessageAt: DateTime(2026, 11, 18, 23),
      );
      await store.saveEpoch(conv, epoch1);
      expect(store.currentEpoch(conv)?.epoch, 1);

      final epoch2 = ChatEpoch(
        epoch: 2,
        keyBase64: base64Encode(List.filled(32, 2)),
        createdAt: now,
        sentCount: 0,
        lastMessageAt: now,
      );
      await store.saveEpoch(conv, epoch2);
      expect(store.currentEpoch(conv)?.epoch, 2);
      // The old epoch is still stored until cleanup (its messages
      // are over 12h old, so cleanup removes it).
      expect(store.epoch(conv, 1), isNotNull);
      final deleted = await store.deleteExpiredEpochs(conv, now);
      expect(deleted, 1);
      expect(store.epoch(conv, 1), isNull);
      // The current epoch is never deleted by cleanup.
      expect(store.epoch(conv, 2), isNotNull);

      // deleteEpoch refuses the current epoch.
      await store.deleteEpoch(conv, 2);
      expect(store.epoch(conv, 2), isNotNull);
    });

    test('epoch key wraps for the recipient, nobody else', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = ChatEpochStore.forTest(prefs);
      final alice = generateKeypairSync(bits: 1024);
      final bob = generateKeypairSync(bits: 1024);

      final epochKey = List<int>.generate(32, (i) => i * 3);
      final wrapped = store.wrapEpochKey(epochKey, {
        'bob': bob.publicKeyJson,
      });
      expect(
        store.unwrapEpochKey(wrapped, 'bob', bob.privateKeyJson),
        epochKey,
      );
      // Alice was never wrapped for: nothing to unwrap.
      expect(
        store.unwrapEpochKey(wrapped, 'alice', alice.privateKeyJson),
        isNull,
      );
      expect(
        () => store.wrapEpochKey(epochKey, {}),
        throwsStateError,
      );
    });
  });

  group('FIX 1 — follow lists on other profiles', () {
    testWidgets("another user's followers list shows THEIR followers",
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: FollowListScreen(
            followers: true,
            userId: 'user-2',
            socialRepo: _FakeSocial(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Follower One'), findsOneWidget);
      expect(find.text('My Follower'), findsNothing);
    });

    testWidgets("another user's following list shows THEIR following",
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: FollowListScreen(
            followers: false,
            userId: 'user-2',
            socialRepo: _FakeSocial(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Following One'), findsOneWidget);
      expect(find.text('My Following'), findsNothing);
    });

    testWidgets('my own list (no userId) still shows MY people',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: FollowListScreen(
            followers: false,
            socialRepo: _FakeSocial(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('My Following'), findsOneWidget);
      expect(find.text('Following One'), findsNothing);
    });
  });

  group('encryptedKeys size cap (live attribute: String 5000)', () {
    // One 1024-bit public key reused under many userIds: the
    // wrapped key is what costs characters, so the count needed
    // to exceed 4800 is larger than with real 2048-bit keys
    // (~370 chars/member → ~13 members in production).
    Map<String, String> manyRecipients(int n, String pubJson) => {
      for (var i = 0; i < n; i++) 'user-$i': pubJson,
    };

    test('text envelope: small group fits, huge group throws', () {
      final bob = generateKeypairSync(bits: 1024);
      final small = encryptForRecipients('hello', {
        'alice': bob.publicKeyJson,
        'bob': bob.publicKeyJson,
      });
      expect(small.encryptedKeysJson.length,
          lessThanOrEqualTo(kMaxEncryptedKeysLength));

      expect(
        () => encryptForRecipients(
          'hello',
          manyRecipients(32, bob.publicKeyJson),
        ),
        throwsA(isA<EncryptedKeysTooLarge>()),
      );
    });

    test('image envelope: huge group throws instead of writing', () {
      final bob = generateKeypairSync(bits: 1024);
      final small = encryptBytesForRecipients([1, 2, 3], {
        'alice': bob.publicKeyJson,
        'bob': bob.publicKeyJson,
      });
      expect(small.encryptedKeysJson.length,
          lessThanOrEqualTo(kMaxEncryptedKeysLength));

      expect(
        () => encryptBytesForRecipients(
          [1, 2, 3],
          manyRecipients(32, bob.publicKeyJson),
        ),
        throwsA(isA<EncryptedKeysTooLarge>()),
      );
    });

    test('epoch wrap: huge group throws, small group wraps + unwraps',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = ChatEpochStore.forTest(prefs);
      final bob = generateKeypairSync(bits: 1024);
      final epochKey = List<int>.generate(32, (i) => i + 1);

      final wrapped = store.wrapEpochKey(epochKey, {
        'alice': bob.publicKeyJson,
        'bob': bob.publicKeyJson,
      });
      expect(wrapped.length, lessThanOrEqualTo(kMaxEncryptedKeysLength));
      expect(
        store.unwrapEpochKey(wrapped, 'bob', bob.privateKeyJson),
        epochKey,
      );

      expect(
        () => store.wrapEpochKey(
          epochKey,
          manyRecipients(32, bob.publicKeyJson),
        ),
        throwsA(isA<EncryptedKeysTooLarge>()),
      );
    });

    test('the error names the member count and says what to do', () {
      const error = EncryptedKeysTooLarge(32);
      expect(error.memberCount, 32);
      expect(error.toString(), contains('32'));
      expect(error.toString(), contains('smaller group'));
      expect(kMaxEncryptedKeysLength, 4800);
    });
  });
}

/// Fake SocialRepository: returns different people depending on
/// whose list was asked for, so the test proves the userId actually
/// reaches the repository instead of always loading MY lists.
class _FakeSocial extends SocialRepository {
  _FakeSocial() : super();

  @override
  Future<List<Profile>> followProfiles({
    required bool followers,
    String? userId,
  }) async {
    if (userId == 'user-2') {
      return followers
          ? [
              const Profile(
                id: 'f1',
                username: 'followerone',
                displayName: 'Follower One',
              ),
            ]
          : [
              const Profile(
                id: 'f2',
                username: 'followingone',
                displayName: 'Following One',
              ),
            ];
    }
    return followers
        ? [
            const Profile(
              id: 'mf',
              username: 'myfollower',
              displayName: 'My Follower',
            ),
          ]
        : [
            const Profile(
              id: 'mg',
              username: 'myfollowing',
              displayName: 'My Following',
            ),
          ];
  }
}
