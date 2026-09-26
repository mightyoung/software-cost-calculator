import 'dart:typed_data';

import 'store.dart';
import 'values.dart';

class Attachment {
  Attachment(
    this.id,
    this.name,
    this.mime,
    this.size,
    this.addedAt,
    this.bytes,
  );
  final String id, name, addedAt;
  final String? mime;
  final int size;

  /// Null when only the listing was read.
  final Uint8List? bytes;
}

/// Original documents behind quotations (quote sheets, chat text, photos).
/// They are stored in the database, so the exchange file carries them.
extension Attachments on Store {
  String addAttachment(String name, List<int> bytes, {String? mime}) {
    if (bytes.isEmpty) invalid('attachment', 'empty file');
    if (bytes.length > maxAttachmentBytes) {
      invalid('attachment', 'larger than 20 MB');
    }
    final id = newUuid();
    db.execute('INSERT INTO attachment VALUES (?,?,?,?,?,?,?)', [
      id,
      normalizeText(name, 'name', 200, required: true),
      normalizeText(mime, 'mime', 100),
      bytes.length,
      Uint8List.fromList(bytes),
      stamp(clock()),
      device,
    ]);
    return id;
  }

  /// Listing without contents, in the order given.
  List<Attachment> attachmentsOf(List<Object?>? ids) => [
    for (final id in ids ?? const [])
      for (final r in db.select(
        'SELECT id, name, mime, size, added_at FROM attachment WHERE id=?',
        [id],
      ))
        Attachment(
          r['id'] as String,
          r['name'] as String,
          r['mime'] as String?,
          r['size'] as int,
          r['added_at'] as String,
          null,
        ),
  ];

  Attachment? attachment(String id) {
    final rows = db.select('SELECT * FROM attachment WHERE id=?', [id]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return Attachment(
      id,
      r['name'] as String,
      r['mime'] as String?,
      r['size'] as int,
      r['added_at'] as String,
      r['data'] as Uint8List,
    );
  }
}
