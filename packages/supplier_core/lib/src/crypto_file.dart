import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'exchange.dart';
import 'store.dart';
import 'values.dart';

/// Encrypted exchange file: magic, 16-byte salt, 12-byte nonce, AES-256-GCM
/// ciphertext, 16-byte tag. The key comes from the passphrase via
/// PBKDF2-HMAC-SHA256. A wrong passphrase and a damaged file both fail the
/// tag check.
final _magic = utf8.encode('SIQE1\n');
const _saltLength = 16, _nonceLength = 12, _tagLength = 16;
const _iterations = 150000;

bool isEncryptedExchange(String path) {
  final file = File(path);
  if (!file.existsSync() || file.lengthSync() < _magic.length) return false;
  final raf = file.openSync();
  try {
    final head = raf.readSync(_magic.length);
    for (var i = 0; i < _magic.length; i++) {
      if (head[i] != _magic[i]) return false;
    }
    return true;
  } finally {
    raf.closeSync();
  }
}

Future<SecretKey> _key(String passphrase, List<int> salt) => Pbkdf2(
  macAlgorithm: Hmac.sha256(),
  iterations: _iterations,
  bits: 256,
).deriveKeyFromPassword(password: passphrase, nonce: salt);

/// Key derivation and AES in pure Dart take a while; both directions run in
/// a background isolate so the window stays responsive.
Future<void> encryptFile(String plain, String out, String passphrase) =>
    Isolate.run(() => _encrypt(plain, out, passphrase));

Future<void> _encrypt(String plain, String out, String passphrase) async {
  final random = Random.secure();
  final salt = List<int>.generate(_saltLength, (_) => random.nextInt(256));
  final aes = AesGcm.with256bits();
  final box = await aes.encrypt(
    File(plain).readAsBytesSync(),
    secretKey: await _key(passphrase, salt),
    nonce: aes.newNonce(),
  );
  final part = File('$out.part');
  part.writeAsBytesSync(
    Uint8List.fromList([
      ..._magic,
      ...salt,
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]),
    flush: true,
  );
  part.renameSync(out);
}

/// Decrypts [path] into a new file under [tempDir] and returns its path.
Future<String> decryptExchange(
  String path,
  String passphrase,
  Directory tempDir,
) => Isolate.run(() => _decrypt(path, passphrase, tempDir));

Future<String> _decrypt(
  String path,
  String passphrase,
  Directory tempDir,
) async {
  final bytes = File(path).readAsBytesSync();
  final head = _magic.length, body = head + _saltLength + _nonceLength;
  if (!isEncryptedExchange(path) || bytes.length < body + _tagLength) {
    invalid('file', 'not an encrypted exchange file');
  }
  final box = SecretBox(
    bytes.sublist(body, bytes.length - _tagLength),
    nonce: bytes.sublist(head + _saltLength, body),
    mac: Mac(bytes.sublist(bytes.length - _tagLength)),
  );
  final List<int> plain;
  try {
    plain = await AesGcm.with256bits().decrypt(
      box,
      secretKey: await _key(
        passphrase,
        bytes.sublist(head, head + _saltLength),
      ),
    );
  } on SecretBoxAuthenticationError {
    invalid('file', '口令不对，或文件已损坏');
  }
  tempDir.createSync(recursive: true);
  final out = File(
    '${tempDir.path}/decrypted-${DateTime.now().microsecondsSinceEpoch}.siq',
  )..writeAsBytesSync(plain, flush: true);
  return out.path;
}

extension EncryptedExchange on Store {
  Future<void> exportEncryptedTo(String path, String passphrase) async {
    final plain = '$path.plain';
    exportTo(plain);
    try {
      await encryptFile(plain, path, passphrase);
    } finally {
      File(plain).deleteSync();
    }
  }
}
