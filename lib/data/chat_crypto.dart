/// End-to-end encryption for messages (v2.11.0, point 16).
///
/// How it works (hybrid encryption, the same shape WhatsApp uses):
///
/// 1. Every user generates ONE RSA-2048 keypair on their device, the
///    first time they open Chats. The PUBLIC key is uploaded to the
///    `users.publicKey` attribute (anyone can see it — that is the
///    point of a public key). The PRIVATE key never leaves the device
///    (SharedPreferences).
/// 2. Every message gets a fresh random AES-256 key. The text is
///    encrypted with it (AES-CBC). The AES key itself is then
///    encrypted with EACH recipient's RSA public key (OAEP-SHA256),
///    so only the people in the chat can unwrap it.
/// 3. The server (and anyone reading the rows directly) sees only
///    ciphertext. HTTPS still protects the traffic and Appwrite
///    still encrypts data at rest — this layer is on top of both.
///
/// What it is NOT: there is no forward secrecy and no key
/// verification UI (no safety numbers). If a device loses its
/// private key, its old encrypted messages cannot be read on a new
/// device. Messages to someone who has never opened Chats (so has
/// no public key yet) are stored UNENCRYPTED and the bubble says so
/// honestly — they are still protected by HTTPS + Appwrite at-rest
/// encryption, just not end-to-end. Do NOT claim those are E2EE.
///
/// v2.11.1 — per-conversation epoch rotation (a step TOWARD forward
/// secrecy, not full forward secrecy; see [ChatEpochStore] and
/// [epochNeedsRotation]): message keys are derived from a
/// per-conversation epoch key instead of being RSA-wrapped one by
/// one. When an epoch rotates, the old epoch key is deleted from
/// this device once its messages have expired, so a later
/// compromise of the device's current state cannot decrypt the
/// old epoch. The honest limit: epoch keys are themselves
/// RSA-wrapped in the stored establishment messages, so anyone
/// holding the RSA private key can still unwrap any epoch. Full
/// forward secrecy needs ephemeral one-time-prekey exchange
/// (X3DH) — that is the documented next step, not this build.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' hide SecureRandom;
import 'package:flutter/foundation.dart' hide Key;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/key_generators/api.dart';
import 'package:pointycastle/key_generators/rsa_key_generator.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kPublicKeyPref = 'chat_public_key_json';
const String _kPrivateKeyPref = 'chat_private_key_json';

/// One user's keypair, as JSON strings (decimal BigInts).
class ChatKeypair {
  const ChatKeypair({required this.publicKeyJson, required this.privateKeyJson});

  final String publicKeyJson;
  final String privateKeyJson;
}

String _publicKeyToJson(RSAPublicKey key) => jsonEncode({
  'n': key.modulus.toString(),
  'e': key.exponent.toString(),
});

String _privateKeyToJson(RSAPrivateKey key) => jsonEncode({
  'n': key.modulus.toString(),
  'd': key.privateExponent.toString(),
  'p': key.p?.toString(),
  'q': key.q?.toString(),
});

RSAPublicKey _publicKeyFromJson(String json) {
  final map = jsonDecode(json) as Map<String, dynamic>;
  return RSAPublicKey(
    BigInt.parse(map['n'] as String),
    BigInt.parse(map['e'] as String),
  );
}

RSAPrivateKey _privateKeyFromJson(String json) {
  final map = jsonDecode(json) as Map<String, dynamic>;
  return RSAPrivateKey(
    BigInt.parse(map['n'] as String),
    BigInt.parse(map['d'] as String),
    map['p'] == null ? null : BigInt.parse(map['p'] as String),
    map['q'] == null ? null : BigInt.parse(map['q'] as String),
  );
}

/// Generates a fresh RSA keypair synchronously. 2048-bit generation
/// in pure Dart takes a few seconds — the app calls the [compute]
/// wrapper [generateChatKeypair] instead; tests use this directly
/// with a smaller [bits] so they stay fast.
ChatKeypair generateKeypairSync({int bits = 2048}) {
  final random = SecureRandom('Fortuna')
    ..seed(KeyParameter(Key.fromSecureRandom(32).bytes));
  final generator = RSAKeyGenerator()
    ..init(
      ParametersWithRandom(
        RSAKeyGeneratorParameters(BigInt.parse('65537'), bits, 64),
        random,
      ),
    );
  final pair = generator.generateKeyPair();
  final publicKey = pair.publicKey as RSAPublicKey;
  final privateKey = pair.privateKey as RSAPrivateKey;
  return ChatKeypair(
    publicKeyJson: _publicKeyToJson(publicKey),
    privateKeyJson: _privateKeyToJson(privateKey),
  );
}

ChatKeypair _generateInIsolate(int bits) => generateKeypairSync(bits: bits);

/// Generates a keypair off the UI thread (RSA-2048 keygen blocks
/// for a few seconds in pure Dart).
Future<ChatKeypair> generateChatKeypair() => compute(_generateInIsolate, 2048);

/// The on-device key store. The private key NEVER leaves the device.
class ChatCryptoStore {
  ChatCryptoStore._(this._prefs);

  static ChatCryptoStore? _instance;

  static Future<ChatCryptoStore> instance() async {
    final existing = _instance;
    if (existing != null) return existing;
    final prefs = await SharedPreferences.getInstance();
    return _instance = ChatCryptoStore._(prefs);
  }

  /// Test seam.
  ChatCryptoStore.forTest(this._prefs);

  final SharedPreferences _prefs;

  String? get publicKeyJson => _prefs.getString(_kPublicKeyPref);
  String? get privateKeyJson => _prefs.getString(_kPrivateKeyPref);
  bool get hasKeypair => publicKeyJson != null && privateKeyJson != null;

  /// Loads the keypair, generating + saving one when missing.
  /// Returns null when generation fails — the caller then sends
  /// unencrypted (with an honest UI note), never crashes.
  Future<ChatKeypair?> ensureKeypair() async {
    final pub = publicKeyJson;
    final priv = privateKeyJson;
    if (pub != null && priv != null) {
      return ChatKeypair(publicKeyJson: pub, privateKeyJson: priv);
    }
    try {
      final pair = await generateChatKeypair();
      await _prefs.setString(_kPublicKeyPref, pair.publicKeyJson);
      await _prefs.setString(_kPrivateKeyPref, pair.privateKeyJson);
      return pair;
    } catch (_) {
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// `messages.encryptedKeys` size cap.
//
// The live Appwrite project stores `encryptedKeys` as a String of
// size 5000 (the 8000 originally planned exceeded Appwrite's
// 65535-byte document limit). Every producer below caps its JSON
// payload at 4800 characters, leaving ~200 characters of headroom
// for the attribute itself. Each member's RSA-wrapped key costs
// roughly 370 characters with real RSA-2048 keys, so the cap only
// bites in very large groups (about 13 members). When it bites,
// the call throws [EncryptedKeysTooLarge] and the message is NOT
// sent — and NOT silently downgraded to plaintext — so the UI can
// tell the user why.
// ---------------------------------------------------------------------------

/// Hard cap on the JSON stored in `messages.encryptedKeys`.
const int kMaxEncryptedKeysLength = 4800;

/// Thrown when the RSA-wrapped keys for a message would not fit in
/// the `messages.encryptedKeys` attribute (live size 5000; code cap
/// 4800). Only possible in a very large group — each member's
/// wrapped key costs ~370 characters. The message is not sent;
/// the UI shows [toString] so the user knows why.
class EncryptedKeysTooLarge implements Exception {
  const EncryptedKeysTooLarge(this.memberCount);

  /// How many members the wrapped-keys map was built for.
  final int memberCount;

  @override
  String toString() =>
      'This chat has too many members for an encrypted message '
      '($memberCount people — the encrypted key data would not fit). '
      'Try a smaller group.';
}

/// One encrypted message body: the AES ciphertext plus, per
/// recipient, the RSA-wrapped AES key.
class EncryptedEnvelope {
  const EncryptedEnvelope({
    required this.ciphertext,
    required this.encryptedKeysJson,
  });

  /// "ivBase64:cipherBase64".
  final String ciphertext;

  /// JSON map: userId → base64 RSA-wrapped AES key.
  final String encryptedKeysJson;
}

/// Encrypts [plaintext] for [recipientPublicKeys] (userId →
/// public-key JSON). One fresh AES-256 key per message; the key is
/// wrapped with each recipient's RSA public key (OAEP-SHA256).
/// Recipients whose key is missing or unparsable are skipped;
/// throws [StateError] when NO recipient could be encrypted for —
/// the caller then falls back to storing plaintext with
/// encrypted=false (and the UI says so).
EncryptedEnvelope encryptForRecipients(
  String plaintext,
  Map<String, String> recipientPublicKeys,
) {
  final aesKey = Key.fromSecureRandom(32);
  final iv = IV.fromSecureRandom(16);
  final aes = Encrypter(AES(aesKey));
  final cipher = aes.encrypt(plaintext, iv: iv);
  final ciphertext = '${iv.base64}:${cipher.base64}';

  final wrapped = <String, String>{};
  for (final entry in recipientPublicKeys.entries) {
    try {
      final publicKey = _publicKeyFromJson(entry.value);
      final rsa = Encrypter(
        RSA(
          publicKey: publicKey,
          encoding: RSAEncoding.OAEP,
          digest: RSADigest.SHA256,
        ),
      );
      final wrappedKey = rsa.encryptBytes(aesKey.bytes);
      wrapped[entry.key] = wrappedKey.base64;
    } catch (_) {
      // Skip a bad key — that recipient simply cannot decrypt.
    }
  }
  if (wrapped.isEmpty) {
    throw StateError('No recipient public key available');
  }
  final encryptedKeysJson = jsonEncode(wrapped);
  if (encryptedKeysJson.length > kMaxEncryptedKeysLength) {
    throw EncryptedKeysTooLarge(wrapped.length);
  }
  return EncryptedEnvelope(
    ciphertext: ciphertext,
    encryptedKeysJson: encryptedKeysJson,
  );
}

/// Decrypts one envelope for [myUserId] using [myPrivateKeyJson].
/// Returns the plaintext, or null when this device cannot decrypt
/// it (wrong key, corrupt data, key lost).
String? decryptEnvelope(
  String ciphertext,
  String encryptedKeysJson,
  String myUserId,
  String myPrivateKeyJson,
) {
  try {
    final wrapped = jsonDecode(encryptedKeysJson) as Map<String, dynamic>;
    final myWrapped = wrapped[myUserId] as String?;
    if (myWrapped == null) return null;
    final privateKey = _privateKeyFromJson(myPrivateKeyJson);
    final rsa = Encrypter(
      RSA(
        privateKey: privateKey,
        encoding: RSAEncoding.OAEP,
        digest: RSADigest.SHA256,
      ),
    );
    final aesKeyBytes = rsa.decryptBytes(Encrypted.fromBase64(myWrapped));
    final parts = ciphertext.split(':');
    if (parts.length != 2) return null;
    final iv = IV.fromBase64(parts[0]);
    final aes = Encrypter(AES(Key(Uint8List.fromList(aesKeyBytes))));
    return aes.decrypt64(parts[1], iv: iv);
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Byte envelopes — image E2EE (v2.11.1, FIX 2).
//
// Same hybrid scheme as text, but over raw bytes: one fresh random
// AES-256 key per image, wrapped per recipient with RSA-OAEP-SHA256.
// The ciphertext layout is 16 IV bytes, then the AES-CBC output,
// then a 32-byte HMAC-SHA256 tag over (IV || cipher) keyed by the
// AES key — the tag is what makes tampering detectable (CBC alone
// is malleable). The caller wraps these bytes for transport — for
// imgbb uploads they ride inside a PNG carrier (see
// png_carrier.dart), because imgbb only accepts real image files.
// ---------------------------------------------------------------------------

/// One encrypted byte payload: the AES ciphertext bytes plus, per
/// recipient, the RSA-wrapped AES key.
class EncryptedBytesEnvelope {
  const EncryptedBytesEnvelope({
    required this.ciphertextBytes,
    required this.encryptedKeysJson,
  });

  /// IV (first 16 bytes) + AES-CBC ciphertext + HMAC tag (last 32).
  final List<int> ciphertextBytes;

  /// JSON map: userId → base64 RSA-wrapped AES key.
  final String encryptedKeysJson;
}

/// Encrypts [plaintextBytes] for [recipientPublicKeys] (userId →
/// public-key JSON). Throws [StateError] when NO recipient could be
/// encrypted for — the caller then falls back to storing the image
/// unencrypted (with an honest UI note), never silently.
EncryptedBytesEnvelope encryptBytesForRecipients(
  List<int> plaintextBytes,
  Map<String, String> recipientPublicKeys,
) {
  final aesKey = Key.fromSecureRandom(32);
  final iv = IV.fromSecureRandom(16);
  final aes = Encrypter(AES(aesKey));
  final cipher = aes.encryptBytes(
    Uint8List.fromList(plaintextBytes),
    iv: iv,
  );
  final tag = Hmac(sha256, aesKey.bytes)
      .convert([...iv.bytes, ...cipher.bytes])
      .bytes;
  final ciphertextBytes = [...iv.bytes, ...cipher.bytes, ...tag];

  final wrapped = <String, String>{};
  for (final entry in recipientPublicKeys.entries) {
    try {
      final publicKey = _publicKeyFromJson(entry.value);
      final rsa = Encrypter(
        RSA(
          publicKey: publicKey,
          encoding: RSAEncoding.OAEP,
          digest: RSADigest.SHA256,
        ),
      );
      wrapped[entry.key] = rsa.encryptBytes(aesKey.bytes).base64;
    } catch (_) {
      // Skip a bad key — that recipient simply cannot decrypt.
    }
  }
  if (wrapped.isEmpty) {
    throw StateError('No recipient public key available');
  }
  final encryptedKeysJson = jsonEncode(wrapped);
  if (encryptedKeysJson.length > kMaxEncryptedKeysLength) {
    throw EncryptedKeysTooLarge(wrapped.length);
  }
  return EncryptedBytesEnvelope(
    ciphertextBytes: ciphertextBytes,
    encryptedKeysJson: encryptedKeysJson,
  );
}

/// Decrypts one byte envelope for [myUserId] using
/// [myPrivateKeyJson]. Returns the plaintext bytes, or null when
/// this device cannot decrypt them (wrong key, corrupt data, key
/// lost, tampered bytes — never garbage output). The HMAC tag is
/// verified first, so a flipped byte anywhere in the file is
/// caught even though CBC alone would still "decrypt" it.
List<int>? decryptBytesEnvelope(
  List<int> ciphertextBytes,
  String encryptedKeysJson,
  String myUserId,
  String myPrivateKeyJson,
) {
  try {
    // IV (16) + at least one cipher block (16) + tag (32).
    if (ciphertextBytes.length <= 48) return null;
    final wrapped = jsonDecode(encryptedKeysJson) as Map<String, dynamic>;
    final myWrapped = wrapped[myUserId] as String?;
    if (myWrapped == null) return null;
    final privateKey = _privateKeyFromJson(myPrivateKeyJson);
    final rsa = Encrypter(
      RSA(
        privateKey: privateKey,
        encoding: RSAEncoding.OAEP,
        digest: RSADigest.SHA256,
      ),
    );
    final aesKeyBytes = rsa.decryptBytes(Encrypted.fromBase64(myWrapped));
    final ivBytes = ciphertextBytes.sublist(0, 16);
    final cipherBytes =
        ciphertextBytes.sublist(16, ciphertextBytes.length - 32);
    final tag = ciphertextBytes.sublist(ciphertextBytes.length - 32);
    final expectedTag = Hmac(sha256, aesKeyBytes)
        .convert([...ivBytes, ...cipherBytes])
        .bytes;
    if (!_constantTimeEquals(tag, expectedTag)) return null;
    final iv = IV(Uint8List.fromList(ivBytes));
    final aes = Encrypter(AES(Key(Uint8List.fromList(aesKeyBytes))));
    return aes.decryptBytes(
      Encrypted(Uint8List.fromList(cipherBytes)),
      iv: iv,
    );
  } catch (_) {
    return null;
  }
}

/// Timing-safe-ish byte comparison for HMAC tags (avoids leaking
/// how many leading bytes matched through an early exit).
bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

// ---------------------------------------------------------------------------
// Per-conversation epoch keys — a step toward forward secrecy
// (v2.11.1, FIX 3).
//
// How it works: instead of RSA-wrapping one AES key per message,
// each conversation has an *epoch key* (a fresh random 256-bit key).
// Message keys are derived from it with HKDF, so the epoch key is
// RSA-wrapped only ONCE — in the epoch's first (establishment)
// message. When the epoch rotates (7 days, 100 sent messages, or
// a membership change), a new epoch key is generated and the old
// one is deleted from this device once every message under it has
// expired (messages live 12 hours, so this is quick). A later
// compromise of the device's current state can then only decrypt
// the current epoch — not the old ones.
//
// What this is NOT: full forward secrecy. The epoch keys are
// RSA-wrapped in the stored establishment messages, so anyone
// holding the RSA identity private key can unwrap any epoch. Full
// forward secrecy needs ephemeral one-time-prekey exchange (X3DH):
// the sender and the recipient each contribute a key that is
// deleted after use, so even the identity key cannot reconstruct
// past sessions. That needs a prekey store (a new Appwrite table)
// and a ratchet protocol — the documented next step, NOT this
// build. Do NOT claim forward secrecy for what is here; say
// "per-conversation key rotation" instead.
// ---------------------------------------------------------------------------

/// HKDF (RFC 5869) with HMAC-SHA256. [key] is the input keying
/// material, [info] binds the output to its purpose. Returns
/// [length] bytes.
List<int> hkdfSha256({
  required List<int> key,
  required List<int> info,
  List<int> salt = const [],
  int length = 32,
}) {
  final effectiveSalt = salt.isEmpty ? List<int>.filled(32, 0) : salt;
  final prk = Hmac(sha256, effectiveSalt).convert(key).bytes;
  final out = <int>[];
  var t = <int>[];
  var counter = 1;
  while (out.length < length) {
    final hmac = Hmac(sha256, prk);
    t = hmac.convert([...t, ...info, counter]).bytes;
    out.addAll(t);
    counter++;
  }
  return out.sublist(0, length);
}

/// Derives one message's AES-256 key from an epoch key and a fresh
/// per-message [nonce]. The nonce is stored with the message, so
/// both sides derive the same key without any shared counter.
Uint8List deriveEpochMessageKey(List<int> epochKey, List<int> nonce) {
  return Uint8List.fromList(
    hkdfSha256(
      key: epochKey,
      info: [...utf8.encode('lifegame-msg-v1:'), ...nonce],
    ),
  );
}

/// One conversation epoch, as stored on-device. The epoch key
/// NEVER leaves the device except RSA-wrapped inside its
/// establishment message.
class ChatEpoch {
  const ChatEpoch({
    required this.epoch,
    required this.keyBase64,
    required this.createdAt,
    required this.sentCount,
    required this.lastMessageAt,
  });

  factory ChatEpoch.fromJson(Map<String, dynamic> json) => ChatEpoch(
    epoch: (json['epoch'] as num).toInt(),
    keyBase64: json['key'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num).toInt(),
    ),
    sentCount: (json['sentCount'] as num?)?.toInt() ?? 0,
    lastMessageAt: DateTime.fromMillisecondsSinceEpoch(
      (json['lastMessageAt'] as num).toInt(),
    ),
  );

  Map<String, dynamic> toJson() => {
    'epoch': epoch,
    'key': keyBase64,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'sentCount': sentCount,
    'lastMessageAt': lastMessageAt.millisecondsSinceEpoch,
  };

  /// 1-based epoch number within the conversation.
  final int epoch;

  /// Base64 of the 32-byte epoch key.
  final String keyBase64;

  List<int> get keyBytes => base64Decode(keyBase64);

  final DateTime createdAt;

  /// Messages I have sent under this epoch (drives rotation).
  final int sentCount;

  /// When the newest message under this epoch was sent (drives
  /// safe deletion: an epoch key is deleted only after its
  /// messages have expired).
  final DateTime lastMessageAt;

  ChatEpoch copyWith({int? sentCount, DateTime? lastMessageAt}) =>
      ChatEpoch(
        epoch: epoch,
        keyBase64: keyBase64,
        createdAt: createdAt,
        sentCount: sentCount ?? this.sentCount,
        lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      );
}

/// Rotation policy (pure, unit-tested): an epoch rotates after 7
/// days or 100 messages I sent under it, whichever comes first.
bool epochNeedsRotation({
  required DateTime createdAt,
  required int sentCount,
  required DateTime now,
}) {
  if (sentCount >= 100) return true;
  return now.difference(createdAt) >= const Duration(days: 7);
}

/// Safe-deletion rule (pure, unit-tested): an old epoch key may be
/// deleted once every message under it has expired. Messages live
/// 12 hours, so an epoch whose newest message is over 12 hours
/// old has nothing live left to decrypt (starred messages are
/// re-encrypted under the new epoch at rotation time).
bool epochKeySafeToDelete({
  required DateTime lastMessageAt,
  required DateTime now,
}) {
  return now.difference(lastMessageAt) >= const Duration(hours: 12);
}

/// The epoch-ciphertext format for text messages (v2.11.1):
/// `v2:<epoch>:<nonce base64>:<iv base64>:<cipher base64>`.
/// The legacy v2.11.0 format is just `<iv base64>:<cipher base64>`
/// (no prefix) and still decrypts through the old path.
String buildEpochCiphertext({
  required int epoch,
  required List<int> nonce,
  required String ivCipher,
}) =>
    'v2:$epoch:${base64Encode(nonce)}:$ivCipher';

/// Parses an epoch ciphertext. Returns null for legacy ciphertext
/// and for anything malformed.
({int epoch, List<int> nonce, String ivCipher})?
parseEpochCiphertext(String? ciphertext) {
  if (ciphertext == null || !ciphertext.startsWith('v2:')) return null;
  final parts = ciphertext.split(':');
  if (parts.length != 5) return null;
  final epoch = int.tryParse(parts[1]);
  if (epoch == null) return null;
  late final List<int> nonce;
  try {
    nonce = base64Decode(parts[2]);
  } catch (_) {
    return null;
  }
  if (nonce.isEmpty) return null;
  return (epoch: epoch, nonce: nonce, ivCipher: '${parts[3]}:${parts[4]}');
}

/// Encrypts [plaintext] under an epoch key. Returns the
/// epoch-ciphertext string (`v2:<epoch>:...`).
String encryptWithEpochKey(
  String plaintext,
  List<int> epochKey,
  int epoch,
) {
  final nonce = Key.fromSecureRandom(16).bytes;
  final aesKey = Key(deriveEpochMessageKey(epochKey, nonce));
  final iv = IV.fromSecureRandom(16);
  final aes = Encrypter(AES(aesKey));
  final cipher = aes.encrypt(plaintext, iv: iv);
  return buildEpochCiphertext(
    epoch: epoch,
    nonce: nonce,
    ivCipher: '${iv.base64}:${cipher.base64}',
  );
}

/// Decrypts an epoch ciphertext with the epoch key. Returns the
/// plaintext, or null when the key is wrong or the data is corrupt.
String? decryptWithEpochKey(
  String epochCiphertext,
  List<int> epochKey,
) {
  try {
    final parsed = parseEpochCiphertext(epochCiphertext);
    if (parsed == null) return null;
    final aesKey = Key(
      deriveEpochMessageKey(epochKey, parsed.nonce),
    );
    final parts = parsed.ivCipher.split(':');
    if (parts.length != 2) return null;
    final iv = IV.fromBase64(parts[0]);
    final aes = Encrypter(AES(aesKey));
    return aes.decrypt64(parts[1], iv: iv);
  } catch (_) {
    return null;
  }
}

/// On-device store for per-conversation epoch keys. The keys never
/// leave the device except RSA-wrapped inside their establishment
/// messages. Old epoch keys are deleted once safe
/// ([epochKeySafeToDelete]) — that deletion is what makes rotation
/// worth anything; without it, rotation would be cosmetic.
class ChatEpochStore {
  ChatEpochStore._(this._prefs);

  static ChatEpochStore? _instance;

  static Future<ChatEpochStore> instance() async {
    final existing = _instance;
    if (existing != null) return existing;
    final prefs = await SharedPreferences.getInstance();
    return _instance = ChatEpochStore._(prefs);
  }

  /// Test seam.
  ChatEpochStore.forTest(this._prefs);

  final SharedPreferences _prefs;

  String _key(String conversationId, int epoch) =>
      'chat_epoch_${conversationId}_$epoch';

  String _currentKey(String conversationId) =>
      'chat_epoch_current_$conversationId';

  /// The current epoch for a conversation, or null when no message
  /// has established one yet.
  ChatEpoch? currentEpoch(String conversationId) {
    final epochNum = _prefs.getInt(_currentKey(conversationId));
    if (epochNum == null) return null;
    return epoch(conversationId, epochNum);
  }

  /// One epoch by number, or null when it was deleted (or never
  /// existed on this device).
  ChatEpoch? epoch(String conversationId, int epoch) {
    final raw = _prefs.getString(_key(conversationId, epoch));
    if (raw == null) return null;
    try {
      return ChatEpoch.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Saves an epoch and marks it current for the conversation.
  Future<void> saveEpoch(String conversationId, ChatEpoch epoch) async {
    await saveEpochRecord(conversationId, epoch);
    await _prefs.setInt(_currentKey(conversationId), epoch.epoch);
  }

  /// Saves an epoch WITHOUT marking it current — for an older
  /// epoch arriving late (out-of-order history), which must be
  /// stored so its messages decrypt but must not become current.
  Future<void> saveEpochRecord(String conversationId, ChatEpoch epoch) async {
    await _prefs.setString(_key(conversationId, epoch.epoch), jsonEncode(epoch.toJson()));
  }

  /// Deletes one epoch's key (rotation cleanup). Never deletes the
  /// current epoch — callers must rotate first.
  Future<void> deleteEpoch(String conversationId, int epoch) async {
    final current = _prefs.getInt(_currentKey(conversationId));
    if (current == epoch) return;
    await _prefs.remove(_key(conversationId, epoch));
  }

  /// Deletes every superseded epoch whose messages have all
  /// expired ([epochKeySafeToDelete]). Called at rotation time.
  /// Returns how many epoch keys were deleted.
  Future<int> deleteExpiredEpochs(
    String conversationId,
    DateTime now,
  ) async {
    final keys = _prefs.getKeys();
    final prefix = 'chat_epoch_${conversationId}_';
    var deleted = 0;
    for (final k in keys) {
      if (!k.startsWith(prefix)) continue;
      final epochNum = int.tryParse(k.substring(prefix.length));
      if (epochNum == null) continue;
      final record = epoch(conversationId, epochNum);
      if (record == null) continue;
      if (epochKeySafeToDelete(lastMessageAt: record.lastMessageAt, now: now)) {
        await deleteEpoch(conversationId, epochNum);
        deleted++;
      }
    }
    return deleted;
  }

  /// Wraps an epoch key for [recipientPublicKeys] (userId →
  /// public-key JSON), the same RSA-OAEP-SHA256 wrapping text
  /// messages use. The wrapped map goes into the establishment
  /// message's `encryptedKeys` field. Throws [StateError] when NO
  /// recipient could be wrapped for, and [EncryptedKeysTooLarge]
  /// when the wrapped map would not fit in the attribute (very
  /// large groups only — the message is then not sent, and not
  /// silently downgraded to plaintext).
  String wrapEpochKey(
    List<int> epochKey,
    Map<String, String> recipientPublicKeys,
  ) {
    final wrapped = <String, String>{};
    for (final entry in recipientPublicKeys.entries) {
      try {
        final publicKey = _publicKeyFromJson(entry.value);
        final rsa = Encrypter(
          RSA(
            publicKey: publicKey,
            encoding: RSAEncoding.OAEP,
            digest: RSADigest.SHA256,
          ),
        );
        wrapped[entry.key] = rsa.encryptBytes(epochKey).base64;
      } catch (_) {
        // Skip a bad key — that recipient simply cannot decrypt.
      }
    }
    if (wrapped.isEmpty) {
      throw StateError('No recipient public key available');
    }
    final wrappedJson = jsonEncode(wrapped);
    if (wrappedJson.length > kMaxEncryptedKeysLength) {
      throw EncryptedKeysTooLarge(wrapped.length);
    }
    return wrappedJson;
  }

  /// Unwraps an epoch key for [myUserId] from an establishment
  /// message's wrapped map. Returns null when this device cannot
  /// unwrap it.
  List<int>? unwrapEpochKey(
    String wrappedKeysJson,
    String myUserId,
    String myPrivateKeyJson,
  ) {
    try {
      final wrapped = jsonDecode(wrappedKeysJson) as Map<String, dynamic>;
      final myWrapped = wrapped[myUserId] as String?;
      if (myWrapped == null) return null;
      final privateKey = _privateKeyFromJson(myPrivateKeyJson);
      final rsa = Encrypter(
        RSA(
          privateKey: privateKey,
          encoding: RSAEncoding.OAEP,
          digest: RSADigest.SHA256,
        ),
      );
      return rsa.decryptBytes(Encrypted.fromBase64(myWrapped));
    } catch (_) {
      return null;
    }
  }
}
