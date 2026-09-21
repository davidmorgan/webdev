// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dwds/data/build_result.dart';
import 'package:dwds/dwds.dart';
import 'package:frontend_server_client/frontend_server_client.dart';
import 'package:http_multi_server/http_multi_server.dart';
import 'package:logging/logging.dart' as logging;
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';
import 'package:watcher/watcher.dart';

import '../command/configuration.dart';
import '../logging.dart';
import '../util.dart';

/// Runs a one-shot `webdev build` directly using `dart compile js`, running
/// `build_runner build` first only if [hasBuildRunner] is true.
Future<int> runFrontendServerBuild({
  required Configuration configuration,
  required bool hasBuildRunner,
  String? workingDirectory,
}) async {
  final rootDir = workingDirectory ?? Directory.current.path;
  if (hasBuildRunner) {
    final codegenExit = await _runBuildRunnerCodegen(
      rootDir,
      release: configuration.release,
      verbose: configuration.verbose,
    );
    if (codegenExit != 0) return codegenExit;
  }

  final sourceDirName =
      (configuration.outputInput != null &&
          configuration.outputInput!.isNotEmpty)
      ? configuration.outputInput!
      : 'web';
  final outputDirName = configuration.outputPath ?? 'build';
  final sourceDir = Directory(p.join(rootDir, sourceDirName));
  final outputDir = Directory(p.join(rootDir, outputDirName));

  if (!sourceDir.existsSync()) {
    logWriter(
      logging.Level.SEVERE,
      'Source directory `$sourceDirName` does not exist.',
    );
    return 1;
  }

  if (!outputDir.existsSync()) {
    outputDir.createSync(recursive: true);
  }

  final dartEntrypoints = <File>[];
  await for (final entity in sourceDir.list(recursive: true)) {
    if (entity is! File) continue;
    final relPath = p.relative(entity.path, from: sourceDir.path);
    if (entity.path.endsWith('.dart')) {
      final content = await entity.readAsString();
      if (content.contains('main(')) {
        dartEntrypoints.add(entity);
      }
    } else {
      final destFile = File(p.join(outputDir.path, relPath));
      destFile.parent.createSync(recursive: true);
      await entity.copy(destFile.path);
    }
  }

  for (final entrypoint in dartEntrypoints) {
    final relPath = p.relative(entrypoint.path, from: sourceDir.path);
    final outJsPath = p.join(outputDir.path, '$relPath.js');
    File(outJsPath).parent.createSync(recursive: true);
    logWriter(logging.Level.INFO, 'Compiling $sourceDirName/$relPath...');
    final args = <String>[
      'compile',
      'js',
      configuration.release ? '-O2' : '-O1',
      if (!configuration.release) '--enable-asserts',
      for (final experiment in configuration.experiments)
        '--enable-experiment=$experiment',
      '-o',
      outJsPath,
      entrypoint.path,
    ];
    final result = await Process.run(dartPath, args, workingDirectory: rootDir);
    if (result.exitCode != 0) {
      logWriter(
        logging.Level.SEVERE,
        'Failed to compile ${entrypoint.path}:\n'
        '${result.stdout}\n${result.stderr}',
      );
      return result.exitCode;
    }
  }

  logWriter(logging.Level.INFO, 'Built with dart compile js\n');
  return 0;
}

Future<int> _runBuildRunnerCodegen(
  String workingDirectory, {
  required bool release,
  required bool verbose,
}) async {
  logWriter(
    logging.Level.INFO,
    'Running `dart run build_runner build` for source codegen...',
  );
  final result = await Process.run(dartPath, [
    'run',
    'build_runner',
    'build',
    if (release) '--release',
    if (verbose) '--verbose',
  ], workingDirectory: workingDirectory);
  if (result.exitCode != 0) {
    logWriter(
      logging.Level.SEVERE,
      'build_runner codegen failed:\n${result.stdout}\n${result.stderr}',
    );
  }
  return result.exitCode;
}

/// Dev workflow that drives `DartDevcFrontendServerClient` directly without
/// `build_daemon` or `build_web_compilers`.
class FrontendServerWorkflow {
  final _doneCompleter = Completer<void>();
  final List<HttpServer> _servers;
  final List<DartDevcFrontendServerClient> _clients;
  final List<Dwds> _dwdsInstances;
  final List<StreamSubscription<WatchEvent>> _watchSubs;
  final StreamController<BuildResult> _buildResultsController;
  final Directory _tempDillDir;

  FrontendServerWorkflow._({
    required List<HttpServer> servers,
    required List<DartDevcFrontendServerClient> clients,
    required List<Dwds> dwdsInstances,
    required List<StreamSubscription<WatchEvent>> watchSubs,
    required StreamController<BuildResult> buildResultsController,
    required Directory tempDillDir,
  }) : _servers = servers,
       _clients = clients,
       _dwdsInstances = dwdsInstances,
       _watchSubs = watchSubs,
       _buildResultsController = buildResultsController,
       _tempDillDir = tempDillDir;

  Future<void> get done => _doneCompleter.future;

  static Future<FrontendServerWorkflow> start(
    Configuration configuration,
    Map<String, int> targetPorts, {
    required bool hasBuildRunner,
    String? workingDirectory,
  }) async {
    final rootDir = workingDirectory ?? Directory.current.path;
    if (hasBuildRunner) {
      final exitCode = await _runBuildRunnerCodegen(
        rootDir,
        release: configuration.release,
        verbose: configuration.verbose,
      );
      if (exitCode != 0) {
        throw StateError('Initial build_runner codegen failed.');
      }
    }

    final sdkDir = p.dirname(p.dirname(dartPath));
    final dartSdkJsPath = await _ensureCachedDartSdkJs(sdkDir);
    final packageConfigFile = File(
      p.join(rootDir, '.dart_tool', 'package_config.json'),
    );
    final packageConfig = await loadPackageConfig(packageConfigFile);
    final tempDillDir = Directory.systemTemp.createTempSync('webdev_dill_');

    final servers = <HttpServer>[];
    final clients = <DartDevcFrontendServerClient>[];
    final dwdsInstances = <Dwds>[];
    final buildResultsController = StreamController<BuildResult>.broadcast();
    final targetClients = <String, DartDevcFrontendServerClient>{};

    final watchedDirs = <String>{'lib', ...targetPorts.keys};
    var lastKnownContents = _snapshotSourceContents(rootDir, watchedDirs);

    for (final entry in targetPorts.entries) {
      final target = entry.key;
      final port = entry.value;
      final entrypointRel = '$target/main.dart';
      final outputDill = p.join(tempDillDir.path, '$target.app.dill');

      final sdkKernelPath = p.join(
        sdkDir,
        'lib',
        '_internal',
        'ddc_platform.dill',
      );
      final client = await DartDevcFrontendServerClient.start(
        'org-dartlang-root:///$entrypointRel',
        outputDill,
        fileSystemRoots: [rootDir],
        fileSystemScheme: 'org-dartlang-root',
        platformKernel: p.toUri(sdkKernelPath).toString(),
        packagesJson: packageConfigFile.path,
        verbose: configuration.verbose,
      );
      clients.add(client);
      targetClients[target] = client;

      logWriter(
        logging.Level.INFO,
        'Starting initial compile for `$target`...',
      );
      final compileResult = await client.compile([]);
      if (compileResult.errorCount > 0) {
        await client.reject();
        throw StateError(
          'Initial compile failed:\n'
          '${compileResult.compilerOutputLines.join('\n')}',
        );
      }
      client.accept();

      final server = await HttpMultiServer.bind(configuration.hostname, port);
      servers.add(server);

      final targetDir = p.join(rootDir, target);
      final staticHandler = createStaticHandler(
        targetDir,
        defaultDocument: 'index.html',
      );
      final packagesHandler = _createPackagesHandler(packageConfig);

      final cascade = Cascade()
          .add(_createFrontendServerAssetHandler(client, target))
          .add(createFileHandler(dartSdkJsPath, url: 'dart_sdk.js'))
          .add(
            createFileHandler(
              p.join(
                sdkDir,
                'lib',
                'dev_compiler',
                'web',
                'dart_stack_trace_mapper.js',
              ),
              url: 'dart_stack_trace_mapper.js',
            ),
          )
          .add(
            createFileHandler(
              p.join(sdkDir, 'lib', 'dev_compiler', 'amd', 'require.js'),
              url: 'require.js',
            ),
          )
          .add(packagesHandler)
          .add(staticHandler);

      shelf_io.serveRequests(server, cascade.handler);
    }

    var isCompiling = false;
    var checkRequested = false;

    Future<void> processPendingChanges() async {
      if (isCompiling) {
        checkRequested = true;
        return;
      }
      isCompiling = true;
      try {
        do {
          checkRequested = false;
          final currentContents = _snapshotSourceContents(rootDir, watchedDirs);
          final changedPaths = _diffSourceContents(
            lastKnownContents,
            currentContents,
          );
          if (changedPaths.isEmpty) continue;
          lastKnownContents = currentContents;

          buildResultsController.add(BuildResult(status: BuildStatus.started));

          final updatedDartFiles = <String>{
            for (final path in changedPaths)
              if (path.endsWith('.dart')) path,
          };

          if (hasBuildRunner) {
            final codegenExit = await _runBuildRunnerCodegen(
              rootDir,
              release: configuration.release,
              verbose: configuration.verbose,
            );
            if (codegenExit != 0) {
              buildResultsController.add(
                BuildResult(status: BuildStatus.failed),
              );
              continue;
            }
            final afterCodegenContents = _snapshotSourceContents(
              rootDir,
              watchedDirs,
            );
            for (final path in _diffSourceContents(
              lastKnownContents,
              afterCodegenContents,
            )) {
              if (path.endsWith('.dart')) {
                updatedDartFiles.add(path);
              }
            }
            lastKnownContents = afterCodegenContents;
          }

          if (updatedDartFiles.isNotEmpty) {
            final invalidatedUris = <Uri>[
              for (final filePath in updatedDartFiles)
                _filePathToCompileUri(filePath, rootDir, packageConfig),
            ];
            var allSucceeded = true;
            for (final client in targetClients.values) {
              final result = await client.compile(invalidatedUris);
              if (result.errorCount > 0) {
                allSucceeded = false;
                logWriter(
                  logging.Level.SEVERE,
                  'Compile errors:\n'
                  '${result.compilerOutputLines.join('\n')}',
                );
                await client.reject();
              } else {
                client.accept();
              }
            }
            if (allSucceeded) {
              logWriter(logging.Level.INFO, 'Recompile succeeded\n');
              buildResultsController.add(
                BuildResult(status: BuildStatus.succeeded),
              );
            } else {
              buildResultsController.add(
                BuildResult(status: BuildStatus.failed),
              );
            }
          } else {
            logWriter(logging.Level.INFO, 'Recompile succeeded\n');
            buildResultsController.add(
              BuildResult(status: BuildStatus.succeeded),
            );
          }
        } while (checkRequested);
      } finally {
        isCompiling = false;
      }
    }

    // Set up and await directory watchers on source directories BEFORE logging
    // `Serving ...` so no file edits after startup are missed on Windows.
    final watchSubs = <StreamSubscription<WatchEvent>>[];
    for (final dirName in watchedDirs) {
      final dirPath = p.join(rootDir, dirName);
      if (!Directory(dirPath).existsSync()) continue;
      final watcher = DirectoryWatcher(dirPath);
      // ignore: cancel_subscriptions
      final sub = watcher.events.listen((_) {
        unawaited(processPendingChanges());
      });
      watchSubs.add(sub);
      await watcher.ready;
    }

    var i = 0;
    for (final target in targetPorts.keys) {
      final server = servers[i++];
      logWriter(
        logging.Level.INFO,
        'Serving `$target` on '
        'http://${configuration.hostname}:${server.port}\n',
      );
    }

    final workflow = FrontendServerWorkflow._(
      servers: servers,
      clients: clients,
      dwdsInstances: dwdsInstances,
      watchSubs: watchSubs,
      buildResultsController: buildResultsController,
      tempDillDir: tempDillDir,
    );

    ProcessSignal.sigint.watch().listen((_) => unawaited(workflow.shutDown()));
    if (!Platform.isWindows) {
      ProcessSignal.sigterm.watch().listen(
        (_) => unawaited(workflow.shutDown()),
      );
    }

    return workflow;
  }

  Future<void> shutDown() async {
    for (final sub in _watchSubs) {
      await sub.cancel();
    }
    for (final dwds in _dwdsInstances) {
      await dwds.stop();
    }
    for (final server in _servers) {
      await server.close(force: true);
    }
    for (final client in _clients) {
      await client.shutdown();
    }
    try {
      if (_tempDillDir.existsSync()) {
        _tempDillDir.deleteSync(recursive: true);
      }
    } catch (_) {}
    await _buildResultsController.close();
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }
}

Handler _createPackagesHandler(PackageConfig packageConfig) {
  return (Request request) {
    final segments = request.url.pathSegments;
    final packagesIndex = segments.indexOf('packages');
    if (packagesIndex == -1 || packagesIndex + 2 >= segments.length) {
      return Response.notFound('Not a package URI');
    }
    final pkgName = segments[packagesIndex + 1];
    final pkgPath = segments.sublist(packagesIndex + 2).join('/');
    final resolved = packageConfig.resolve(
      Uri.parse('package:$pkgName/$pkgPath'),
    );
    if (resolved == null) return Response.notFound('Unknown package: $pkgName');
    final file = File.fromUri(resolved);
    if (!file.existsSync()) return Response.notFound('File not found');
    return createFileHandler(file.path, url: request.url.path)(request);
  };
}

Map<String, String> _snapshotSourceContents(
  String rootDir,
  Iterable<String> subDirs,
) {
  final result = <String, String>{};
  for (final subDir in subDirs) {
    final dir = Directory(p.join(rootDir, subDir));
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is File) {
        try {
          result[p.normalize(entity.path)] = entity.readAsStringSync();
        } catch (_) {}
      }
    }
  }
  return result;
}

Set<String> _diffSourceContents(
  Map<String, String> before,
  Map<String, String> after,
) {
  final changed = <String>{};
  for (final entry in after.entries) {
    if (before[entry.key] != entry.value) {
      changed.add(entry.key);
    }
  }
  for (final key in before.keys) {
    if (!after.containsKey(key)) {
      changed.add(key);
    }
  }
  return changed;
}

Uri _filePathToCompileUri(
  String filePath,
  String rootDir,
  PackageConfig packageConfig,
) {
  final fileUri = p.toUri(p.absolute(filePath));
  final packageUri = packageConfig.toPackageUri(fileUri);
  if (packageUri != null) {
    return packageUri;
  }
  final relPath = p.relative(filePath, from: rootDir).replaceAll(r'\', '/');
  return Uri.parse('org-dartlang-root:///$relPath');
}

Handler _createFrontendServerAssetHandler(
  DartDevcFrontendServerClient client,
  String target,
) {
  return (Request request) {
    var reqPath = request.url.path;
    if (!reqPath.startsWith('/')) reqPath = '/$reqPath';

    final candidates = <String>[
      reqPath,
      '/$target$reqPath',
      if (reqPath.endsWith('.dart.js') &&
          reqPath != '/main.dart.js' &&
          reqPath != '/$target/main.dart.js') ...[
        reqPath.replaceFirst('.dart.js', '.dart.lib.js', reqPath.length - 8),
        '/$target${reqPath.replaceFirst('.dart.js', '.dart.lib.js', reqPath.length - 8)}',
      ],
    ];

    for (final candidate in candidates) {
      var bytes = client.assetBytes(candidate);
      if (bytes != null) {
        if (candidate == '/$target/main.dart.js' ||
            candidate == '/$target/main.dart.bootstrap.js') {
          final rewritten = utf8
              .decode(bytes)
              .replaceAll('"$target/', '"')
              .replaceAll("'$target/", "'");
          bytes = utf8.encode(rewritten);
        }
        final contentType = candidate.endsWith('.map')
            ? 'application/json'
            : 'application/javascript';
        return Response.ok(
          bytes,
          headers: {HttpHeaders.contentTypeHeader: contentType},
        );
      }
    }
    return Response.notFound('Asset not found: $reqPath');
  };
}

Future<String> _ensureCachedDartSdkJs(String sdkDir) async {
  final sdkKernelPath = p.join(sdkDir, 'lib', '_internal', 'ddc_platform.dill');
  final kernelStat = File(sdkKernelPath).statSync();
  final cacheKey =
      '${sdkDir.hashCode}_${kernelStat.modified.millisecondsSinceEpoch}';
  final cacheDir = Directory(
    p.join(Directory.systemTemp.path, 'webdev_sdk_cache_$cacheKey'),
  );
  final cachedSdkJs = File(p.join(cacheDir.path, 'dart_sdk.js'));
  if (cachedSdkJs.existsSync()) {
    return cachedSdkJs.path;
  }

  cacheDir.createSync(recursive: true);
  final tempSdkJs = File(p.join(cacheDir.path, 'dart_sdk.js.tmp.$pid'));
  final result = await Process.run(dartPath, [
    'compile',
    'js-dev',
    '--multi-root-scheme=org-dartlang-sdk',
    '--modules=amd',
    '--module-name=dart_sdk',
    '-o',
    tempSdkJs.path,
    sdkKernelPath,
  ]);
  if (result.exitCode != 0) {
    throw StateError(
      'Failed to compile dart_sdk.js:\n${result.stdout}\n${result.stderr}',
    );
  }
  await tempSdkJs.rename(cachedSdkJs.path);
  return cachedSdkJs.path;
}
