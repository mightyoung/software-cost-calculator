import 'package:flutter/material.dart';

import '../../app/motion.dart';
import 'package:flutter/services.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../widgets/app_icon.dart';
import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';
import '../../widgets/deletion.dart';
import '../../widgets/save_keys.dart';

/// Contact list shown inside the supplier editor.
class SupplierContacts extends StatelessWidget {
  const SupplierContacts({
    super.key,
    required this.state,
    required this.supplierId,
  });
  final AppState state;
  final String supplierId;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final contacts = state.store.contactsOf(supplierId);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text('联系人', style: TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              TextButton.icon(
                onPressed: () => showContactForm(context, state, supplierId),
                icon: const AppIcon(Icons.person_add_alt, size: 18),
                label: const Text('添加联系人'),
              ),
            ],
          ),
          if (contacts.isEmpty)
            Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('还没有联系人', style: TextStyle(color: Tokens.ink3)),
            ),
          for (final c in contacts)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(c.data['name']! as String),
              subtitle: Text(contactLine(c.data)),
              trailing: IconButton(
                tooltip: '复制联系方式',
                icon: const AppIcon(Icons.copy, size: 16),
                onPressed: () {
                  Clipboard.setData(
                    ClipboardData(
                      text: '${c.data['name']} ${contactLine(c.data)}',
                    ),
                  );
                  toast(context, '已复制联系方式');
                },
              ),
              onTap: () =>
                  showContactForm(context, state, supplierId, id: c.id),
            ),
        ],
      );
    },
  );
}

String contactLine(Map<String, Object?> c) => [
  if (c['phone'] != null) '电话 ${c['phone']}',
  if (c['wechat'] != null) '微信 ${c['wechat']}',
  if (c['email'] != null) c['email'],
].join(' · ');

Future<void> showContactForm(
  BuildContext context,
  AppState state,
  String supplierId, {
  String? id,
}) => showAppDialog(
  context: context,
  builder: (_) => _ContactForm(state: state, supplierId: supplierId, id: id),
);

class _ContactForm extends StatefulWidget {
  const _ContactForm({required this.state, required this.supplierId, this.id});
  final AppState state;
  final String supplierId;
  final String? id;

  @override
  State<_ContactForm> createState() => _ContactFormState();
}

class _ContactFormState extends State<_ContactForm> {
  static const _fields = [
    ('name', '姓名'),
    ('phone', '电话'),
    ('wechat', '微信'),
    ('email', '邮箱'),
    ('notes', '备注'),
  ];
  final c = <String, TextEditingController>{};
  String? error;

  @override
  void initState() {
    super.initState();
    final data = widget.id == null
        ? null
        : widget.state.store.get('contact', widget.id!)?.data;
    for (final (k, _) in _fields) {
      c[k] = TextEditingController(text: data?[k] as String? ?? '');
    }
  }

  @override
  void dispose() {
    for (final x in c.values) {
      x.dispose();
    }
    super.dispose();
  }

  void _save() {
    final payload = <String, Object?>{
      'supplier_id': widget.supplierId,
      for (final e in c.entries)
        e.key: e.value.text.trim().isEmpty ? null : e.value.text.trim(),
    };
    if (payload['phone'] == null &&
        payload['wechat'] == null &&
        payload['email'] == null) {
      return setState(() => error = '电话、微信、邮箱至少填一项');
    }
    final err = widget.state.write(
      (s) => s.save('contact', payload, id: widget.id),
    );
    if (err != null) return setState(() => error = err);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => SaveKeys(
    onSave: _save,
    child: AlertDialog(
      scrollable: true,
      title: Text(widget.id == null ? '添加联系人' : '编辑联系人'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (k, label) in _fields) ...[
              TextField(
                controller: c[k],
                autofocus: k == 'name',
                keyboardType: k == 'phone' ? TextInputType.phone : null,
                decoration: InputDecoration(labelText: label),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 10),
            ],
            if (error != null)
              Text(error!, style: TextStyle(color: Tokens.red)),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: dialogActions(
        onDelete: widget.id == null
            ? null
            : () {
                final id = widget.id!;
                final name =
                    widget.state.store.get('contact', id)?.data['name']
                        as String? ??
                    '';
                if (deleteWithUndo(
                  context,
                  widget.state,
                  type: 'contact',
                  id: id,
                  name: name,
                )) {
                  Navigator.pop(context);
                }
              },
        deleteLabel: '删除联系人',
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
    ),
  );
}
