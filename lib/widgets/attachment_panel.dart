import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import '../data/store.dart';
import '../sync/operation.dart';

Future<Uint8List> readPicked(PlatformFile file, int limit) async {
  final known = await file.length();
  if (known != null && known > limit) {
    throw const FormatException('Файл превышает допустимый размер.');
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in file.readAsByteStream()) {
    if (builder.length + chunk.length > limit) {
      throw const FormatException('Файл превышает допустимый размер.');
    }
    builder.add(chunk);
  }
  return builder.takeBytes();
}

Future<void> saveBytes(String name, Uint8List bytes) async {
  final target = await FilePicker.saveFile(fileName: name, bytes: bytes);
  if (target != null &&
      (Platform.isLinux || Platform.isWindows) &&
      (target.scheme.isEmpty || target.scheme == 'file')) {
    await File.fromUri(target).writeAsBytes(bytes, flush: true);
  }
}

class AttachmentPanel extends StatefulWidget {
  final Store store;
  final String noteId;
  final bool readOnly;
  final Future<bool> Function() beforeChange;
  final void Function() onChanged;
  const AttachmentPanel({
    super.key,
    required this.store,
    required this.noteId,
    required this.beforeChange,
    required this.onChanged,
    this.readOnly = false,
  });
  @override
  State<AttachmentPanel> createState() => _AttachmentPanelState();
}

class _AttachmentPanelState extends State<AttachmentPanel> {
  bool busy = false;
  Future<void> action(Future<void> Function() task) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await task();
      widget.onChanged();
    } on FormatException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось обработать вложение. Проверьте свободное место и повторите.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        children: [
          const SizedBox(width: 16),
          const Text('Вложения'),
          const Spacer(),
          if (!widget.readOnly)
            TextButton.icon(
              onPressed: busy
                  ? null
                  : () => action(() async {
                      if (!await widget.beforeChange()) return;
                      final selected = await FilePicker.pickFile();
                      if (selected == null) return;
                      final bytes = await readPicked(
                        selected,
                        AttachmentDescriptor.maxBytes,
                      );
                      final temp = await Directory.systemTemp.createTemp(
                        'ladno-import-',
                      );
                      try {
                        final file = File('${temp.path}/attachment');
                        await file.writeAsBytes(bytes, flush: true);
                        await widget.store.addAttachment(
                          widget.noteId,
                          file,
                          name: selected.name,
                        );
                      } finally {
                        await temp.delete(recursive: true);
                      }
                    }),
              icon: const Icon(Icons.attach_file, size: 18),
              label: const Text('Добавить'),
            ),
        ],
      ),
      FutureBuilder<List<AttachmentDescriptor>>(
        future: widget.store.noteAttachments(widget.noteId),
        builder: (context, snapshot) {
          final files = snapshot.data ?? [];
          if (files.isEmpty) return const SizedBox.shrink();
          return ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 140),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final descriptor in files)
                  FutureBuilder<File?>(
                    future: widget.store.attachments.verifiedFile(descriptor),
                    builder: (context, available) {
                      final file = available.data;
                      return ListTile(
                        onTap:
                            file != null &&
                                RegExp(
                                  r'\.(png|jpg|jpeg|webp|gif)$',
                                  caseSensitive: false,
                                ).hasMatch(descriptor.name)
                            ? () => showDialog<void>(
                                context: context,
                                builder: (ctx) => Dialog(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Flexible(
                                        child: InteractiveViewer(
                                          child: Image.file(
                                            file,
                                            fit: BoxFit.contain,
                                            errorBuilder: (_, _, _) =>
                                                const Padding(
                                                  padding: EdgeInsets.all(24),
                                                  child: Text(
                                                    'Не удалось открыть изображение.',
                                                  ),
                                                ),
                                          ),
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: () => Navigator.pop(ctx),
                                        child: const Text('Закрыть'),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            : null,
                        dense: true,
                        title: Text(
                          descriptor.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          file == null
                              ? 'Ожидает загрузки'
                              : '${(descriptor.size / 1024).ceil()} КБ',
                        ),
                        leading:
                            file != null &&
                                RegExp(
                                  r'\.(png|jpg|jpeg|webp|gif)$',
                                  caseSensitive: false,
                                ).hasMatch(descriptor.name)
                            ? Image.file(
                                file,
                                width: 40,
                                height: 40,
                                cacheWidth: 80,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) =>
                                    const Icon(Icons.insert_drive_file),
                              )
                            : const Icon(Icons.insert_drive_file_outlined),
                        trailing: Wrap(
                          children: [
                            IconButton(
                              tooltip: 'Сохранить файл',
                              onPressed: file == null || busy
                                  ? null
                                  : () => action(() async {
                                      await saveBytes(
                                        descriptor.name,
                                        await file.readAsBytes(),
                                      );
                                    }),
                              icon: const Icon(Icons.download, size: 20),
                            ),
                            if (!widget.readOnly)
                              IconButton(
                                tooltip: 'Убрать вложение',
                                onPressed: busy
                                    ? null
                                    : () => action(() async {
                                        if (await widget.beforeChange()) {
                                          await widget.store.removeAttachment(
                                            widget.noteId,
                                            descriptor.hash,
                                          );
                                        }
                                      }),
                                icon: const Icon(Icons.close, size: 20),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
              ],
            ),
          );
        },
      ),
    ],
  );
}
