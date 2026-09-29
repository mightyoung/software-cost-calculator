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
// SIQE1 uses whole-message AES-GCM. Bound its buffers before key derivation.
const maxEncryptedExchangeBytes = 128 * 1024 * 1024;
const _envelopeBytes = 6 + _saltLength + _nonceLength + _tagLength;

/// Only authentication failures can be retried with a different password.
class ExchangeAuthenticationException extends FormatException {
  const ExchangeAuthenticationException() : super('file: 口令不对，或文件已损坏');
}

Uint8List _readBounded(String path, int limit) {
  final file = File(path).openSync();
  try {
    final length = file.lengthSync();
    if (length > limit) invalid('file', 'encrypted exchange exceeds 128 MiB');
    final bytes = Uint8List(length);
    var read = 0;
    while (read < length) {
      final count = file.readIntoSync(bytes, read);
      if (count == 0) invalid('file', 'file changed while reading');
      read += count;
    }
    // Do not let a file that grows after the length check extend allocation.
    if (file.readByteSync() != -1)
      invalid('file', 'file changed while reading');
    return bytes;
  } finally {
    file.closeSync();
  }
}

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
    _readBounded(plain, maxEncryptedExchangeBytes - _envelopeBytes),
    secretKey: await _key(passphrase, salt),
    nonce: aes.newNonce(),
  );
  final part = File('$out.part');
  final output = part.openSync(mode: FileMode.write);
  try {
    for (final bytes in [
      _magic,
      salt,
      box.nonce,
      box.cipherText,
      box.mac.bytes,
    ]) {
      output.writeFromSync(bytes);
    }
    output.flushSync();
  } finally {
    output.closeSync();
  }
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
  final bytes = _readBounded(path, maxEncryptedExchangeBytes);
  final head = _magic.length, body = head + _saltLength + _nonceLength;
  if (bytes.length < body + _tagLength ||
      !List.generate(
        _magic.length,
        (i) => bytes[i] == _magic[i],
      ).every((v) => v)) {
    invalid('file', 'not an encrypted exchange file');
  }
  final box = SecretBox(
    Uint8List.sublistView(bytes, body, bytes.length - _tagLength),
    nonce: Uint8List.sublistView(bytes, head + _saltLength, body),
    mac: Mac(Uint8List.sublistView(bytes, bytes.length - _tagLength)),
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
    throw const ExchangeAuthenticationException();
  }
  tempDir.createSync(recursive: true);
  final out = File(
    '${tempDir.path}/decrypted-${DateTime.now().microsecondsSinceEpoch}.siq',
  )..writeAsBytesSync(plain, flush: true);
  return out.path;
}

extension EncryptedExchange on Store {
  Future<void> exportEncryptedTo(String path, String passphrase) async {
    final temp = Directory.systemTemp.createTempSync('siq-encrypt-');
    final plain = '${temp.path}/snapshot.siq';
    try {
      exportTo(plain);
      await encryptFile(plain, path, passphrase);
    } finally {
      temp.deleteSync(recursive: true);
    }
  }
}
