import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ladno_sync/replica.dart';
import 'package:ladno_sync/operation.dart';
import 'package:ladno_sync/attachment_cache.dart';

String _digest(String value) => sha256.convert(utf8.encode(value)).toString();
String _random() =>
    base64UrlEncode(List.generate(32, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');

class BackendFailure implements Exception {
  final int status;
  final String code;
  const BackendFailure(this.status, this.code);
}

class Backend {
  final Replica replica;
  final AttachmentCache attachments;
  final int maxOperations, maxStorageBytes;
  Database get db => replica.db as Database;
  HttpServer? _http;
  final Set<Future<void>> _handling = {};
  Future<void> _tail = Future.value();
  bool _closed = false;
  int _active = 0;
  int get port => _http!.port;
  Backend._(
    this.replica,
    this.attachments,
    this.maxOperations,
    this.maxStorageBytes,
  );
  static Future<Backend> open(
    Directory root, {
    int maxOperations = 100000,
    int maxStorageBytes = 10 * 1024 * 1024 * 1024,
  }) async {
    sqfliteFfiInit();
    final replica = await Replica.open(databaseFactoryFfi, root);
    final backend = Backend._(
      replica,
      AttachmentCache(Directory('${root.path}/attachments')),
      maxOperations,
      maxStorageBytes,
    );
    await backend.db.execute(
      'CREATE TABLE IF NOT EXISTS backend_devices(id TEXT PRIMARY KEY, name TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE, revoked INTEGER NOT NULL DEFAULT 0)',
    );
    await backend.db.execute(
      'CREATE TABLE IF NOT EXISTS backend_invites(hash TEXT PRIMARY KEY, expires INTEGER NOT NULL)',
    );
    return backend;
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<String> invite({
    Duration lifetime = const Duration(minutes: 10),
  }) async {
    final token = _random();
    await db.transaction((tx) async {
      await tx.delete(
        'backend_invites',
        where: 'expires < ?',
        whereArgs: [DateTime.now().millisecondsSinceEpoch],
      );
      await tx.insert('backend_invites', {
        'hash': _digest(token),
        'expires': DateTime.now().add(lifetime).millisecondsSinceEpoch,
      });
    });
    return token;
  }

  Future<void> revoke(String id) => _serial(() async {
    if (!validUuid(id)) throw const FormatException('Invalid device ID');
    await db.update(
      'backend_devices',
      {'revoked': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
    await replica.forgetReceipts(id);
  });
  Future<void> recoverIdentity() => db.transaction((tx) async {
    await tx.update(
      'replica_meta',
      {'value': const Uuid().v4()},
      where: 'key = ?',
      whereArgs: ['device'],
    );
    await tx.delete('replica_receipts');
    await tx.delete('backend_invites');
    await tx.update('backend_devices', {'revoked': 1});
  });
  Future<List<Map<String, Object?>>> devices() =>
      db.query('backend_devices', columns: ['id', 'name', 'revoked']);
  Future<Map<String, Object?>> _enroll(Map<String, dynamic> value) =>
      db.transaction((tx) async {
        final invite = value['invite'],
            id = value['deviceId'],
            name = value['name'];
        if (invite is! String ||
            invite.length > 128 ||
            !validUuid(id) ||
            id == replica.deviceId ||
            name is! String ||
            name.trim().isEmpty ||
            name.length > 100) {
          throw const BackendFailure(400, 'invalid_enrollment');
        }
        final rows = await tx.query(
          'backend_invites',
          where: 'hash = ? AND expires > ?',
          whereArgs: [_digest(invite), DateTime.now().millisecondsSinceEpoch],
        );
        if (rows.isEmpty) throw const BackendFailure(403, 'invalid_invite');
        final count =
            (await tx.rawQuery('SELECT COUNT(*) AS n FROM backend_devices'))
                    .single['n']
                as int;
        if (count >= 128 &&
            (await tx.query(
              'backend_devices',
              where: 'id = ?',
              whereArgs: [id],
            )).isEmpty)
          throw const BackendFailure(409, 'device_limit');
        final token = _random();
        await tx.delete(
          'backend_invites',
          where: 'hash = ?',
          whereArgs: [_digest(invite)],
        );
        await tx.insert('backend_devices', {
          'id': id,
          'name': name.trim(),
          'token_hash': _digest(token),
          'revoked': 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        final local = await Replica.attach(tx, inTransaction: true);
        await local.forgetReceipts(id as String);
        return {'token': token, 'deviceId': replica.deviceId};
      });
  Future<String> _auth(HttpRequest request) async {
    final auth = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    final id = request.headers.value('x-ladno-device-id');
    if (!auth.startsWith('Bearer ') || auth.length > 150 || !validUuid(id)) {
      throw const BackendFailure(403, 'unauthorized');
    }
    final rows = await db.query(
      'backend_devices',
      columns: ['id'],
      where: 'id = ? AND token_hash = ? AND revoked = 0',
      whereArgs: [id, _digest(auth.substring(7))],
    );
    if (rows.isEmpty) throw const BackendFailure(403, 'unauthorized');
    return id!;
  }

  Future<void> listen({
    InternetAddress? address,
    int port = 8080,
    SecurityContext? tls,
  }) async {
    _http = tls == null
        ? await HttpServer.bind(address ?? InternetAddress.anyIPv4, port)
        : await HttpServer.bindSecure(
            address ?? InternetAddress.loopbackIPv4,
            port,
            tls,
          );
    _http!.idleTimeout = const Duration(seconds: 15);
    _http!.listen((request) {
      final future = _handle(request);
      _handling.add(future);
      unawaited(future.whenComplete(() => _handling.remove(future)));
    });
  }

  Future<String> _body(HttpRequest request, int limit) async {
    if (request.contentLength > limit) {
      throw const BackendFailure(413, 'too_large');
    }
    final bytes = <int>[];
    await for (final chunk in request.timeout(const Duration(seconds: 10))) {
      if (bytes.length + chunk.length > limit) {
        throw const BackendFailure(413, 'too_large');
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  Map<String, dynamic> _control(String body) {
    final value = jsonDecode(body);
    if (value is! Map<String, dynamic> ||
        value['protocol'] != syncProtocolVersion) {
      throw const BackendFailure(400, 'incompatible_protocol');
    }
    return value;
  }

  Future<void> _handle(HttpRequest request) async {
    var counted = false;
    try {
      if (_closed || _active >= 32) throw const BackendFailure(503, 'busy');
      _active++;
      counted = true;
      if (request.uri.hasQuery || request.uri.hasFragment) {
        throw const BackendFailure(404, 'not_found');
      }
      if (request.method == 'GET' && request.uri.path == '/health') {
        await _reply(request, {'ok': true});
        return;
      }
      if (request.method != 'POST') {
        throw const BackendFailure(405, 'invalid_method');
      }
      final path = request.uri.path;
      if (path == '/v1/enroll') {
        final body = await _body(
          request,
          4096,
        ).timeout(const Duration(seconds: 12));
        final value = _control(body);
        final result = await _serial(() => _enroll(value));
        await _reply(request, result);
        return;
      }
      final peer = await _auth(request);
      final body = await _body(
        request,
        path == '/v1/push'
            ? maxSyncBatchBytes
            : path == '/v1/file/append'
            ? AttachmentCache.chunkBytes * 2
            : 65536,
      ).timeout(const Duration(seconds: 12));
      // Serialize authorization and mutations so revoke also blocks queued work.
      final result = await _serial(() async {
        await _auth(request);
        if (path == '/v1/push') {
          final batch = SyncBatch.decode(body);
          var added = 0;
          for (final operation in batch.operations) {
            if ((await db.query(
              'replica_ops',
              columns: ['id'],
              where: 'id = ?',
              whereArgs: [operation.id],
            )).isEmpty) {
              added++;
            }
          }
          if (await replica.operationCount() + added > maxOperations) {
            throw const BackendFailure(507, 'operation_quota');
          }
          return <String, Object?>{
            'ack': await replica.receive(batch, fromPeer: peer),
          };
        }
        final value = _control(body);
        if (path == '/v1/pull') {
          final ack = value['ack'];
          if (ack is! List || ack.any((v) => v is! String)) {
            throw const BackendFailure(400, 'invalid_ack');
          }
          await replica.acknowledge(peer, ack.cast<String>());
          return <String, Object?>{
            'batch': jsonDecode((await replica.outgoing(peer)).encode()),
          };
        }
        if (path == '/v1/info') return <String, Object?>{'name': 'Ладно'};
        if (!path.startsWith('/v1/file/')) {
          throw const BackendFailure(404, 'not_found');
        }
        final descriptor = AttachmentDescriptor.fromJson(value['descriptor']);
        // Files must already be referenced in the authenticated workspace.
        final refs = await replica.referencedAttachments();
        if (!refs.any(
          (d) => d.hash == descriptor.hash && d.size == descriptor.size,
        )) {
          throw const BackendFailure(403, 'unreferenced_file');
        }
        if (path == '/v1/file/status') {
          return <String, Object?>{
            'complete': await attachments.contains(descriptor),
            'offset': await attachments.resumeOffset(descriptor, create: false),
          };
        }
        if (path == '/v1/file/read' && value['offset'] is int) {
          return <String, Object?>{
            'data': base64Encode(
              await attachments.readChunk(descriptor, value['offset'] as int),
            ),
          };
        }
        if (path == '/v1/file/append' &&
            value['offset'] is int &&
            value['data'] is String) {
          var reserved = 0;
          final sizes = <String, int>{};
          for (final d in refs) {
            sizes[d.hash] = d.size;
          }
          for (final size in sizes.values) {
            reserved += size;
          }
          if (reserved > maxStorageBytes) {
            throw const BackendFailure(507, 'storage_quota');
          }
          final offset = await attachments.append(
            descriptor,
            value['offset'] as int,
            base64Decode(value['data'] as String),
          );
          return <String, Object?>{'offset': offset};
        }
        if (path == '/v1/file/finish') {
          await attachments.finish(descriptor);
          return <String, Object?>{'complete': true};
        }
        throw const BackendFailure(400, 'invalid_route');
      });
      await _reply(request, result);
    } catch (e) {
      try {
        request.response.statusCode = e is BackendFailure
            ? e.status
            : e is SyncProtocolException || e is FormatException
            ? 400
            : 503;
        await _reply(request, {
          'error': e is BackendFailure
              ? e.code
              : e is SyncProtocolException || e is FormatException
              ? 'invalid_data'
              : 'unavailable',
        });
      } catch (_) {
        /* Disconnected clients retry using durable receipts. */
      }
    } finally {
      if (counted) _active--;
    }
  }

  Future<void> _reply(HttpRequest request, Map<String, Object?> data) async {
    request.response.headers.contentType = ContentType.json;
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    request.response.write(
      jsonEncode({
        'protocol': syncProtocolVersion,
        'deviceId': replica.deviceId,
        ...data,
      }),
    );
    await request.response.close();
  }

  Future<void> close() async {
    _closed = true;
    await _http?.close(force: true);
    await Future.wait(_handling.toList());
    await _tail;
    await replica.close();
  }
}
