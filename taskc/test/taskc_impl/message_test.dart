import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:taskc/taskc.dart';
import 'package:taskc/taskc_impl.dart';
import 'package:taskc/taskd.dart';
import 'package:taskc/taskrc.dart';
import 'package:taskj/json.dart';

void main() {
  var taskdData = Directory('../fixture/var/taskd').absolute.path;
  var taskd = Taskd(taskdData);
  late Map<String, String> config;
  late List<String> server;
  late Connection connection;
  late Credentials credentials;

  setUpAll(() async {
    await taskd.initialize();
    await taskd.setAddressAndPort(
      address: 'localhost',
      port: 53589,
    );
    unawaited(taskd.start());
    await Future.delayed(const Duration(seconds: 1));

    var userKey = await taskd.addUser('First Last');
    var uuid = const Uuid().v1();
    var home = Directory('test/taskc_impl/tmp/$uuid').absolute.path;
    await taskd.initializeClient(
      home: home,
      address: 'localhost',
      port: 53589,
      fullName: 'First Last',
      fileName: 'first_last',
      userKey: userKey,
    );

    config = parseTaskrc(
      File('$home/.taskrc').readAsStringSync(),
    );
    server = (config['taskd.server']!).split(':');
    connection = Connection(
      address: server[0],
      port: int.parse(server[1]),
      context: SecurityContext()
        ..useCertificateChain(config['taskd.certificate']!)
        ..usePrivateKey(config['taskd.key']!),
      onBadCertificate: (_) => true,
    );
    credentials = Credentials.fromString(config['taskd.credentials']!);
  });

  tearDownAll(() async {
    await taskd.kill();
  });

  group('Test statistics', () {
    test('test', () async {
      var response = await statistics(
        connection: connection,
        credentials: credentials,
        client: 'test',
      );
      expect(response.header['status'], 'Ok');
    });
  });

  String newTask() => json.encode(
        Task(
          (b) => b
            ..status = 'pending'
            ..uuid = const Uuid().v1()
            ..entry = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
            ..description = 'test',
        ).toJson(),
      );

  group('Test synchronize', () {
    String? userKey;

    test('test first sync with one task', () async {
      var response = await synchronize(
        connection: connection,
        credentials: credentials,
        client: 'test',
        payload: '${Payload(tasks: [newTask()])}',
      );

      userKey = response.payload.userKey;

      expect(response.header['client'], 'taskd 1.1.0');
      expect(response.header['code'], '200');
      expect(response.header['status'], 'Ok');
    });

    test('test second sync with userKey and no tasks', () async {
      var response = await synchronize(
        connection: connection,
        credentials: credentials,
        client: 'test',
        payload: '${Payload(tasks: [], userKey: userKey)}',
      );

      expect(response.header['client'], 'taskd 1.1.0');
      expect(response.header['code'], '201');
      expect(response.header['status'], 'No change');
    });
    test('test response with more than 2^13th bytes', () async {
      // My experience is that implementations need to account for some limit at
      // 8191 bytes (2^13 - 1) being sent over socket.

      var payload = Payload(
        tasks: List.generate(100, (_) => newTask()).toList(),
      ).toString();

      expect(Codec.encode(payload).length > pow(2, 13), true);

      await synchronize(
        connection: connection,
        credentials: credentials,
        client: 'test',
        payload: payload,
      );

      var response = await synchronize(
        connection: connection,
        credentials: credentials,
        client: 'test',
        payload: '',
      );

      expect(Codec.encode('${response.payload}').length > pow(2, 13), true);
      expect(response.header['status'], 'Ok');
    });
    test('count tasks', () async {
      await File(
              '../fixture/var/taskd/orgs/Public/users/${credentials.key}/tx.data')
          .delete();

      await synchronize(
        connection: connection,
        credentials: credentials,
        client: 'test',
        payload: '${newTask()}\n${newTask()}',
      );

      var response = await synchronize(
        connection: connection,
        credentials: credentials,
        client: 'test',
        payload: '',
      );

      expect(response.payload.tasks.length, 2);
    });
    test('too many tasks', () async {
      // Can apply request.limit=0 with the following diff:
      //
      // ```
      // modified   taskc/lib/src/taskd/taskd.dart
      // @@ -35,6 +35,7 @@ class Taskd {
      //        ['config', '--force', 'log', '$taskdData/taskd.log'],
      //        ['config', '--force', 'pid.file', '$taskdData/taskd.pid'],
      //        ['config', '--force', 'debug.tls', '2'],
      // +      ['config', '--force', 'request.limit', '0'],
      //        ['add', 'org', 'Public'],
      //      ]) {
      //        await Process.run('taskd', arguments,
      // ```
      //
      // With the above change, there's no exceptions until pow(2, 24), as in
      // the following:
      //
      // ```
      // payload = '{"description":"foo"}\n' * (pow(2, 24) as int);
      // ```
      //
      // Then, we see TimeoutException, and very slow test runs.

      var payload = '{"description":"foo"}\n' * (pow(2, 16) as int);

      try {
        await synchronize(
          connection: connection,
          credentials: credentials,
          client: 'test',
          payload: payload,
        );
        expect(true, false);
      } on TaskserverResponseException catch (e) {
        expect(e.header, {
          'client': 'taskd 1.1.0',
          'code': '504',
          'status': 'Request too big',
        });
      }

      payload = '{"description":"foo"}\n' * (pow(2, 15) as int);

      var response = await synchronize(
        connection: connection,
        credentials: credentials,
        client: 'test',
        payload: payload,
      );

      expect(response.header['code'], '200');
      expect(response.header['status'], 'Ok');
    });
    test('escape character', () async {
      var userKey = await taskd.addUser('First Last');
      var uuid = const Uuid().v1();
      var home = Directory('test/taskc_impl/tmp/$uuid').absolute.path;
      await taskd.initializeClient(
        home: home,
        address: 'localhost',
        port: 53589,
        fullName: 'First Last',
        fileName: 'first_last',
        userKey: userKey,
      );
      config = parseTaskrc(
        File('$home/.taskrc').readAsStringSync(),
      );
      server = (config['taskd.server']!).split(':');
      connection = Connection(
        address: server[0],
        port: int.parse(server[1]),
        context: SecurityContext()
          ..useCertificateChain(config['taskd.certificate']!)
          ..usePrivateKey(config['taskd.key']!),
        onBadCertificate: (_) => true,
      );
      credentials = Credentials.fromString(config['taskd.credentials']!);

      var taskUuid = const Uuid().v1();
      var now = DateTime.now().toUtc();
      var payload = json.encode(
        Task(
          (b) => b
            ..status = 'pending'
            ..uuid = taskUuid
            ..entry = now
            ..description = r'hello\',
        ).toJson(),
      );

      expect(() => json.decode(payload), returnsNormally);
      expect(
        payload,
        '{'
        '"status":"pending",'
        '"uuid":"$taskUuid",'
        '"entry":"${iso8601Basic.format(now)}",'
        '"description":"hello\\\\"' // ignore: use_raw_strings
        '}',
      );

      var response = await synchronize(
        connection: connection,
        credentials: credentials,
        client: 'test',
        payload: payload,
      );

      expect(response.header['code'], '200');
      expect(response.header['status'], 'Ok');

      response = await synchronize(
        connection: connection,
        credentials: credentials,
        client: 'test',
        payload: '',
      );

      expect(response.header['code'], '200');
      expect(response.header['status'], 'Ok');

      var task = response.payload.tasks.first;

      expect(
        () => json.decode(task),
        throwsA(const TypeMatcher<FormatException>()),
      );
      expect(
        task,
        '{'
        '"description":"hello\\\\\x00",'
        '"entry":"${iso8601Basic.format(now)}",'
        '"status":"pending",'
        '"uuid":"$taskUuid"'
        '}',
      );
    });
  });
}
