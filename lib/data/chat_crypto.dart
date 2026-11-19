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
library;

import 'dart:convert';

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
  return EncryptedEnvelope(
    ciphertext: ciphertext,
    encryptedKeysJson: jsonEncode(wrapped),
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
