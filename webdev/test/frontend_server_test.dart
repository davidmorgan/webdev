// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn('vm')
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

import 'test_utils.dart';

Future<int> findUnusedPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  final testRunner = TestRunner();
  setUpAll(testRunner.setUpAll);
  tearDownAll(testRunner.tearDownAll);

  group('frontend-server mode (no build_daemon or build_web_compilers)', () {
    test(
      'webdev build and serve work on a project with zero dev_dependencies',
      () async {
        await d.file('pubspec.yaml', '''
name: pure_web_app
environment:
  sdk: ^3.0.0
''').create();
        await d.dir('lib', [
          d.file('greeting.dart', '''
String greeting() => 'Hello from initial version';
'''),
        ]).create();
        await d.dir('web', [
          d.file('index.html', '''
<!DOCTYPE html>
<html>
  <head><script defer src="main.dart.js"></script></head>
  <body></body>
</html>
'''),
          d.file('main.dart', '''
import 'package:pure_web_app/greeting.dart';
void main() {
  print(greeting());
}
'''),
        ]).create();

        final pubGet = await Process.run(Platform.resolvedExecutable, [
          'pub',
          'get',
        ], workingDirectory: d.sandbox);
        expect(
          pubGet.exitCode,
          0,
          reason: '${pubGet.stdout}\n${pubGet.stderr}',
        );

        // 1. Verify `webdev build --frontend-server` compiles and outputs assets.
        final buildProcess = await testRunner.runWebDev([
          'build',
          '--frontend-server',
          '--no-release',
        ], workingDirectory: d.sandbox);
        await checkProcessStdout(buildProcess, ['Built with dart compile js']);
        await buildProcess.shouldExit(0);

        final builtIndex = File(p.join(d.sandbox, 'build', 'index.html'));
        final builtMainJs = File(p.join(d.sandbox, 'build', 'main.dart.js'));
        expect(builtIndex.existsSync(), isTrue);
        expect(builtMainJs.existsSync(), isTrue);
        expect(
          builtMainJs.readAsStringSync(),
          contains('Hello from initial version'),
        );

        // 2. Verify `webdev serve --frontend-server` serves and live-recompiles.
        final openPort = await findUnusedPort();
        final serveProcess = await testRunner.runWebDev([
          'serve',
          '--frontend-server',
          '--no-injected-client',
          'web:$openPort',
        ], workingDirectory: d.sandbox);

        await checkProcessStdout(serveProcess, [
          'Serving `web` on http://localhost:$openPort',
        ]);

        final baseUrl = 'http://localhost:$openPort';
        final indexResp = await http.get(Uri.parse('$baseUrl/index.html'));
        expect(indexResp.statusCode, 200);
        expect(indexResp.body, contains('main.dart.js'));

        final bootstrapResp = await http.get(
          Uri.parse('$baseUrl/main.dart.js'),
        );
        expect(bootstrapResp.statusCode, 200);

        final sdkResp = await http.get(Uri.parse('$baseUrl/dart_sdk.js'));
        expect(sdkResp.statusCode, 200);

        final greetingModuleUrl = Uri.parse(
          '$baseUrl/packages/pure_web_app/greeting.dart.lib.js',
        );
        final initialModuleResp = await http.get(greetingModuleUrl);
        expect(initialModuleResp.statusCode, 200);
        expect(initialModuleResp.body, contains('Hello from initial version'));

        // Edit `lib/greeting.dart` and verify incremental FrontendServer compile.
        File(p.join(d.sandbox, 'lib', 'greeting.dart')).writeAsStringSync('''
String greeting() => 'Hello after live edit';
''');

        await checkProcessStdout(serveProcess, ['Recompile succeeded']);

        final updatedModuleResp = await http.get(greetingModuleUrl);
        expect(updatedModuleResp.statusCode, 200);
        expect(updatedModuleResp.body, contains('Hello after live edit'));

        await serveProcess.kill();
        await serveProcess.shouldExit();
      },
    );

    test('webdev serve coordinates build_to: source codegen with FrontendServer '
        'without build_web_compilers', () async {
      await d.file('pubspec.yaml', '''
name: codegen_web_app
environment:
  sdk: ^3.0.0

dev_dependencies:
  build: ^4.0.0
  build_runner: ^2.4.0
''').create();

      await d.file('build.yaml', '''
builders:
  config_builder:
    import: "package:codegen_web_app/builder.dart"
    builder_factories: ["configBuilder"]
    build_extensions: {".txt": [".g.dart"]}
    auto_apply: root_package
    build_to: source
''').create();

      await d.dir('lib', [
        d.file('builder.dart', '''
import 'package:build/build.dart';

Builder configBuilder(BuilderOptions options) => _ConfigBuilder();

class _ConfigBuilder implements Builder {
  @override
  final buildExtensions = const {
    '.txt': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final text = (await buildStep.readAsString(buildStep.inputId)).trim();
    final outputId = buildStep.inputId.changeExtension('.g.dart');
    await buildStep.writeAsString(
      outputId,
      "const generatedMessage = 'Generated: \$text';\\n",
    );
  }
}
'''),
        d.file('config.txt', 'v1\n'),
      ]).create();

      await d.dir('web', [
        d.file('index.html', '<script defer src="main.dart.js"></script>'),
        d.file('main.dart', '''
import 'package:codegen_web_app/config.g.dart';
void main() {
  print(generatedMessage);
}
'''),
      ]).create();

      final pubGet = await Process.run(Platform.resolvedExecutable, [
        'pub',
        'get',
      ], workingDirectory: d.sandbox);
      expect(pubGet.exitCode, 0, reason: '${pubGet.stdout}\n${pubGet.stderr}');

      final openPort = await findUnusedPort();
      final serveProcess = await testRunner.runWebDev([
        'serve',
        '--frontend-server',
        '--no-injected-client',
        'web:$openPort',
      ], workingDirectory: d.sandbox);

      await checkProcessStdout(serveProcess, [
        'Serving `web` on http://localhost:$openPort',
      ]);

      // Verify `build_runner` wrote `lib/config.g.dart` to source and
      // `FrontendServer` compiled it.
      expect(
        File(p.join(d.sandbox, 'lib', 'config.g.dart')).existsSync(),
        isTrue,
      );
      final generatedModuleUrl = Uri.parse(
        'http://localhost:$openPort/packages/codegen_web_app/config.g.dart.lib.js',
      );
      final initialResp = await http.get(generatedModuleUrl);
      expect(initialResp.statusCode, 200);
      expect(initialResp.body, contains('Generated: v1'));

      // Modify `lib/config.txt` -> `build_runner` regenerates `lib/config.g.dart`
      // -> `FrontendServer` incrementally recompiles `config.g.dart`.
      File(p.join(d.sandbox, 'lib', 'config.txt')).writeAsStringSync('v2\n');

      await checkProcessStdout(serveProcess, ['Recompile succeeded']);

      final updatedResp = await http.get(generatedModuleUrl);
      expect(updatedResp.statusCode, 200);
      expect(updatedResp.body, contains('Generated: v2'));

      await serveProcess.kill();
      await serveProcess.shouldExit();
    });
  });
}
