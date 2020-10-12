// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:meta/meta.dart';

import '../base/file_system.dart';
import '../base/platform.dart';
import '../base/user_messages.dart' hide userMessages;
import '../base/version.dart';
import '../doctor.dart';
import '../ios/plist_parser.dart';
import 'intellij.dart';

/// A doctor validator for both Intellij and Android Studio.
abstract class IntelliJValidator extends DoctorValidator {
  IntelliJValidator(String title, this.installPath, {
    @required FileSystem fileSystem,
    @required UserMessages userMessages,
  }) : _fileSystem = fileSystem,
       _userMessages = userMessages,
       super(title);

  final String installPath;
  final FileSystem _fileSystem;
  final UserMessages _userMessages;

  String get version;

  String get pluginsPath;

  static const Map<String, String> _idToTitle = <String, String>{
    'IntelliJIdea': 'IntelliJ IDEA Ultimate Edition',
    'IdeaIC': 'IntelliJ IDEA Community Edition',
  };

  static final Version kMinIdeaVersion = Version(2017, 1, 0);

  /// Create a [DoctorValidator] for each installation of Intellij.
  ///
  /// On platforms other than macOS, Linux, and Windows this returns an
  /// empty list.
  static Iterable<DoctorValidator> installedValidators({
    @required FileSystem fileSystem,
    @required Platform platform,
    @required UserMessages userMessages,
    @required PlistParser plistParser,
  }) {
    final FileSystemUtils fileSystemUtils = FileSystemUtils(fileSystem: fileSystem, platform: platform);
    if (platform.isLinux || platform.isWindows) {
      return IntelliJValidatorOnLinuxAndWindows.installed(
        fileSystem: fileSystem,
        fileSystemUtils: fileSystemUtils,
        userMessages: userMessages,
      );
    }
    if (platform.isMacOS) {
      return IntelliJValidatorOnMac.installed(
        fileSystem: fileSystem,
        fileSystemUtils: fileSystemUtils,
        userMessages: userMessages,
        plistParser: plistParser,
      );
    }
    return <DoctorValidator>[];
  }

  @override
  Future<ValidationResult> validate() async {
    final List<ValidationMessage> messages = <ValidationMessage>[];

    if (pluginsPath == null) {
      messages.add(const ValidationMessage.error('Invalid IntelliJ version number.'));
    } else {
      messages.add(ValidationMessage(_userMessages.intellijLocation(installPath)));

      final IntelliJPlugins plugins = IntelliJPlugins(pluginsPath, fileSystem: _fileSystem);
      plugins.validatePackage(
        messages,
        <String>['flutter-intellij', 'flutter-intellij.jar'],
        'Flutter',
        IntelliJPlugins.kIntellijFlutterPluginUrl,
        minVersion: IntelliJPlugins.kMinFlutterPluginVersion,
      );
      plugins.validatePackage(
        messages,
        <String>['Dart'],
        'Dart',
        IntelliJPlugins.kIntellijDartPluginUrl,
      );

      if (_hasIssues(messages)) {
        messages.add(ValidationMessage(_userMessages.intellijPluginInfo));
      }

      _validateIntelliJVersion(messages, kMinIdeaVersion);
    }

    return ValidationResult(
      _hasIssues(messages) ? ValidationType.partial : ValidationType.installed,
      messages,
      statusInfo: _userMessages.intellijStatusInfo(version),
    );
  }

  bool _hasIssues(List<ValidationMessage> messages) {
    return messages.any((ValidationMessage message) => message.isError);
  }

  void _validateIntelliJVersion(List<ValidationMessage> messages, Version minVersion) {
    // Ignore unknown versions.
    if (minVersion == Version.unknown) {
      return;
    }

    final Version installedVersion = Version.parse(version);
    if (installedVersion == null) {
      return;
    }

    if (installedVersion < minVersion) {
      messages.add(ValidationMessage.error(_userMessages.intellijMinimumVersion(minVersion.toString())));
    }
  }
}

/// A linux and windows specific implementation of the intellij validator.
class IntelliJValidatorOnLinuxAndWindows extends IntelliJValidator {
  IntelliJValidatorOnLinuxAndWindows(String title, this.version, String installPath, this.pluginsPath, {
    @required FileSystem fileSystem,
    @required UserMessages userMessages,
  }) : super(title, installPath, fileSystem: fileSystem, userMessages: userMessages);

  @override
  final String version;

  @override
  final String pluginsPath;

  static Iterable<DoctorValidator> installed({
    @required FileSystem fileSystem,
    @required FileSystemUtils fileSystemUtils,
    @required UserMessages userMessages,
  }) {
    final List<DoctorValidator> validators = <DoctorValidator>[];
    if (fileSystemUtils.homeDirPath == null) {
      return validators;
    }

    void addValidator(String title, String version, String installPath, String pluginsPath) {
      final IntelliJValidatorOnLinuxAndWindows validator = IntelliJValidatorOnLinuxAndWindows(
        title,
        version,
        installPath,
        pluginsPath,
        fileSystem: fileSystem,
        userMessages: userMessages,
      );
      for (int index = 0; index < validators.length; index += 1) {
        final DoctorValidator other = validators[index];
        if (other is IntelliJValidatorOnLinuxAndWindows && validator.installPath == other.installPath) {
          if (validator.version.compareTo(other.version) > 0) {
            validators[index] = validator;
          }
          return;
        }
      }
      validators.add(validator);
    }

    final Directory homeDir = fileSystem.directory(fileSystemUtils.homeDirPath);
    for (final Directory dir in homeDir.listSync().whereType<Directory>()) {
      final String name = fileSystem.path.basename(dir.path);
      IntelliJValidator._idToTitle.forEach((String id, String title) {
        if (name.startsWith('.$id')) {
          final String version = name.substring(id.length + 1);
          String installPath;
          try {
            installPath = fileSystem.file(fileSystem.path.join(dir.path, 'system', '.home')).readAsStringSync();
          } on FileSystemException {
            // ignored
          }
          if (installPath != null && fileSystem.isDirectorySync(installPath)) {
            final String pluginsPath = fileSystem.path.join(dir.path, 'config', 'plugins');
            addValidator(title, version, installPath, pluginsPath);
          }
        }
      });
    }
    return validators;
  }
}

/// A macOS specific implementation of the intellij validator.
class IntelliJValidatorOnMac extends IntelliJValidator {
  IntelliJValidatorOnMac(String title, this.id, String installPath, {
    @required FileSystem fileSystem,
    @required UserMessages userMessages,
    @required PlistParser plistParser,
    @required String homeDirPath,
  }) : _plistParser = plistParser,
       _homeDirPath = homeDirPath,
       super(title, installPath, fileSystem: fileSystem, userMessages: userMessages);

  final String id;
  final PlistParser _plistParser;
  final String _homeDirPath;

  static const Map<String, String> _dirNameToId = <String, String>{
    'IntelliJ IDEA.app': 'IntelliJIdea',
    'IntelliJ IDEA Ultimate.app': 'IntelliJIdea',
    'IntelliJ IDEA CE.app': 'IdeaIC',
  };

  static Iterable<DoctorValidator> installed({
    @required FileSystem fileSystem,
    @required FileSystemUtils fileSystemUtils,
    @required UserMessages userMessages,
    @required PlistParser plistParser,
  }) {
    final List<DoctorValidator> validators = <DoctorValidator>[];
    final List<String> installPaths = <String>[
      '/Applications',
      fileSystem.path.join(fileSystemUtils.homeDirPath, 'Applications'),
    ];

    void checkForIntelliJ(Directory dir) {
      final String name = fileSystem.path.basename(dir.path);
      _dirNameToId.forEach((String dirName, String id) {
        if (name == dirName) {
          final String title = IntelliJValidator._idToTitle[id];
          validators.add(IntelliJValidatorOnMac(
            title,
            id,
            dir.path,
            fileSystem: fileSystem,
            userMessages: userMessages,
            plistParser: plistParser,
            homeDirPath: fileSystemUtils.homeDirPath,
          ));
        }
      });
    }

    try {
      final Iterable<Directory> installDirs = installPaths
        .map(fileSystem.directory)
        .map<List<FileSystemEntity>>((Directory dir) => dir.existsSync() ? dir.listSync() : <FileSystemEntity>[])
        .expand<FileSystemEntity>((List<FileSystemEntity> mappedDirs) => mappedDirs)
        .whereType<Directory>();
      for (final Directory dir in installDirs) {
        checkForIntelliJ(dir);
        if (!dir.path.endsWith('.app')) {
          for (final FileSystemEntity subdirectory in dir.listSync()) {
            if (subdirectory is Directory) {
              checkForIntelliJ(subdirectory);
            }
          }
        }
      }
    } on FileSystemException catch (e) {
      validators.add(ValidatorWithResult(
          userMessages.intellijMacUnknownResult,
          ValidationResult(ValidationType.missing, <ValidationMessage>[
            ValidationMessage.error(e.message),
          ]),
      ));
    }
    return validators;
  }

  @visibleForTesting
  String get plistFile {
    _plistFile ??= _fileSystem.path.join(installPath, 'Contents', 'Info.plist');
    return _plistFile;
  }
  String _plistFile;

  @override
  String get version {
    return _version ??= _plistParser.getValueFromFile(
        plistFile,
        PlistParser.kCFBundleShortVersionStringKey,
      ) ?? 'unknown';
  }
  String _version;

  @override
  String get pluginsPath {
    if (_pluginsPath != null) {
      return _pluginsPath;
    }

    final String altLocation = _plistParser
      .getValueFromFile(plistFile, 'JetBrainsToolboxApp');

    if (altLocation != null) {
      _pluginsPath = altLocation + '.plugins';
      return _pluginsPath;
    }

    final List<String> split = version.split('.');
    if (split.length < 2) {
      return null;
    }
    final String major = split[0];
    final String minor = split[1];

    final String homeDirPath = _homeDirPath;
    String pluginsPath = _fileSystem.path.join(
      homeDirPath,
      'Library',
      'Application Support',
      'JetBrains',
      '$id$major.$minor',
      'plugins',
    );
    // Fallback to legacy location from < 2020.
    if (!_fileSystem.isDirectorySync(pluginsPath)) {
      pluginsPath = _fileSystem.path.join(
        homeDirPath,
        'Library',
        'Application Support',
        '$id$major.$minor',
      );
    }
    _pluginsPath = pluginsPath;

    return _pluginsPath;
  }
  String _pluginsPath;
}
