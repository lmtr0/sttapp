import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

const _assetName = 'sttapp_audio_bindings_generated.dart';
const _libraryName = 'sttapp_audio';
const _rustBuilderEnvironmentVariable = 'STTAPP_RUST_BUILDER';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }

    _addRustDependencies(input.packageRoot, output);

    final codeConfig = input.config.code;
    final targetTriple = _rustTargetTriple(
      codeConfig.targetOS,
      codeConfig.targetArchitecture,
    );
    final libraryFileName = codeConfig.targetOS.dylibFileName(_libraryName);
    final manifestPath = File.fromUri(
      input.packageRoot.resolve('rust/Cargo.toml'),
    ).path;

    final cargoSubcommand = _cargoSubcommand();
    final cargoArgs = [
      cargoSubcommand,
      '--manifest-path',
      manifestPath,
      '--release',
      '--target',
      targetTriple,
    ];
    final result = await Process.run(
      'cargo',
      cargoArgs,
      workingDirectory: Directory.fromUri(input.packageRoot).path,
    );

    if (result.exitCode != 0) {
      throw ProcessException(
        'cargo',
        cargoArgs,
        '${result.stdout}\n${result.stderr}',
        result.exitCode,
      );
    }

    final sourceLibrary = File.fromUri(
      input.packageRoot.resolve(
        'rust/target/$targetTriple/release/$libraryFileName',
      ),
    );
    final outputLibraryUri = input.outputDirectory.resolve(libraryFileName);
    final outputLibrary = File.fromUri(outputLibraryUri);
    await outputLibrary.parent.create(recursive: true);
    await sourceLibrary.copy(outputLibrary.path);

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: _assetName,
        linkMode: DynamicLoadingBundled(),
        file: outputLibraryUri,
      ),
    );
  });
}

void _addRustDependencies(Uri packageRoot, BuildOutputBuilder output) {
  output.dependencies.addAll([
    packageRoot.resolve('rust/Cargo.toml'),
    packageRoot.resolve('rust/Cargo.lock'),
    packageRoot.resolve('rust/src/'),
  ]);
}

String _cargoSubcommand() {
  return Platform.environment[_rustBuilderEnvironmentVariable] == 'zigbuild'
      ? 'zigbuild'
      : 'build';
}

String _rustTargetTriple(OS os, Architecture architecture) {
  if (os == OS.linux) {
    return switch (architecture) {
      Architecture.x64 => 'x86_64-unknown-linux-gnu',
      Architecture.arm64 => 'aarch64-unknown-linux-gnu',
      _ => throw UnsupportedError(
        'Unsupported Linux architecture: $architecture',
      ),
    };
  }

  if (os == OS.macOS) {
    return switch (architecture) {
      Architecture.x64 => 'x86_64-apple-darwin',
      Architecture.arm64 => 'aarch64-apple-darwin',
      _ => throw UnsupportedError(
        'Unsupported macOS architecture: $architecture',
      ),
    };
  }

  if (os == OS.windows) {
    return switch (architecture) {
      Architecture.x64 => 'x86_64-pc-windows-msvc',
      Architecture.arm64 => 'aarch64-pc-windows-msvc',
      Architecture.ia32 => 'i686-pc-windows-msvc',
      _ => throw UnsupportedError(
        'Unsupported Windows architecture: $architecture',
      ),
    };
  }

  throw UnsupportedError('Unsupported target OS: $os');
}
