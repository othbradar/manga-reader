import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'controllers/appearance_controller.dart';
import 'controllers/download_controller.dart';
import 'controllers/favorites_controller.dart';
import 'controllers/library_controller.dart';
import 'controllers/reading_history_controller.dart';
import 'controllers/session_controller.dart';
import 'controllers/novel_controller.dart';
import 'services/novel_store.dart';
import 'pages/app_shell.dart';
import 'services/chinese_search_normalizer.dart';
import 'services/copy_api_protocol.dart';
import 'services/copy_client.dart';
import 'services/copy_device_identity.dart';
import 'services/library_database.dart';
import 'services/library_locator.dart';
import 'services/local_app_database.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'libjxl',
      'Brotli',
      'Highway',
      'skcms',
    ], await rootBundle.loadString('assets/licenses/jpeg_xl.txt'));
  });
  runApp(const CopyMangaReaderBootstrap());
}

class CopyMangaReaderBootstrap extends StatefulWidget {
  const CopyMangaReaderBootstrap({super.key});

  @override
  State<CopyMangaReaderBootstrap> createState() =>
      _CopyMangaReaderBootstrapState();
}

class _CopyMangaReaderBootstrapState extends State<CopyMangaReaderBootstrap> {
  late final CopyClient _client;
  late final ChineseSearchNormalizer _normalizer;
  late final LibraryDatabase _database;
  late final LocalAppDatabase _localDatabase;
  late final AppearanceController _appearance;
  late final LibraryController _library;
  late final ReadingHistoryController _history;
  late final SessionController _session;
  late final FavoritesController _favorites;
  late final DownloadController _downloads;
  late final NovelController _novels;

  @override
  void initState() {
    super.initState();
    _normalizer = ChineseSearchNormalizer();
    _client = CopyClient(normalizer: _normalizer);
    _localDatabase = LocalAppDatabase();
    _appearance = AppearanceController(_localDatabase);
    _database = LibraryDatabase(
      normalizer: _normalizer,
      localDatabase: _localDatabase,
    );
    _history = ReadingHistoryController(_localDatabase);
    _library = LibraryController(
      database: _database,
      locator: LibraryLocator(),
      client: _client,
      localDatabase: _localDatabase,
    );
    _session = SessionController(_client);
    _favorites = FavoritesController(database: _database, client: _client);
    _downloads = DownloadController(database: _database, client: _client);
    _novels = NovelController(
      store: NovelStore(_database),
      client: _client.novels,
    );
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    await _localDatabase.open();
    _client.setDeviceIdentity(
      await CopyDeviceIdentityService.load(_localDatabase),
    );
    await _appearance.initialize();
    await _history.initialize();
    await _normalizer.loadAssets();
    await _library.initialize();
    if (_library.ready) {
      final apiRoute = await _database.setting('api_route');
      _client.setApiRoute(CopyApiRoute.fromSetting(apiRoute));
      final apiDomain = await _database.setting('api_domain');
      final apiDomainMode = await _database.setting('api_domain_mode');
      if (apiDomainMode == 'manual' &&
          apiDomain.isNotEmpty &&
          !CopyApiProtocol.isPresetDomain(apiDomain)) {
        _client.setApiDomain(apiDomain);
      }
      final authenticationDomain = await _database.setting(
        'authentication_domain',
      );
      final authenticationDomainMode = await _database.setting(
        'authentication_domain_mode',
      );
      if (authenticationDomainMode == 'manual' &&
          authenticationDomain.isNotEmpty) {
        _client.setAuthenticationDomain(authenticationDomain);
      }
    }
    if (_library.ready) {
      await Future.wait([_favorites.loadCache(), _downloads.initialize()]);
      await _novels.initialize();
    }
    // Local novels must be usable even when account/profile requests are slow.
    await _session.restore();
  }

  @override
  void dispose() {
    unawaited(_database.close());
    unawaited(_localDatabase.close());
    _downloads.dispose();
    _novels.dispose();
    _appearance.dispose();
    _favorites.dispose();
    _session.dispose();
    _history.dispose();
    _library.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider.value(value: _client),
        Provider.value(value: _database),
        Provider.value(value: _localDatabase),
        ChangeNotifierProvider.value(value: _appearance),
        ChangeNotifierProvider.value(value: _library),
        ChangeNotifierProvider.value(value: _history),
        ChangeNotifierProvider.value(value: _session),
        ChangeNotifierProvider.value(value: _favorites),
        ChangeNotifierProvider.value(value: _downloads),
        ChangeNotifierProvider.value(value: _novels),
      ],
      child: const CopyMangaReaderApp(),
    );
  }
}

class CopyMangaReaderApp extends StatelessWidget {
  const CopyMangaReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    final appearance = context.watch<AppearanceController>();
    const seed = Color(0xff6b4eff);
    return MaterialApp(
      title: '拷贝漫画阅读器',
      debugShowCheckedModeBanner: false,
      themeMode: appearance.brightnessMode.themeMode,
      theme: _theme(
        seed: seed,
        surface: appearance.themeColor.surface(Brightness.light),
        brightness: Brightness.light,
      ),
      darkTheme: _theme(
        seed: seed,
        surface: appearance.themeColor.surface(Brightness.dark),
        brightness: Brightness.dark,
      ),
      home: const AppShell(),
    );
  }

  ThemeData _theme({
    required Color seed,
    required Color surface,
    required Brightness brightness,
  }) {
    final base = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    final containerTint = brightness == Brightness.dark
        ? Colors.white
        : Colors.black;
    Color container(double opacity) =>
        Color.alphaBlend(containerTint.withValues(alpha: opacity), surface);
    final colors = base.copyWith(
      surface: surface,
      onSurface: brightness == Brightness.dark ? Colors.white : Colors.black,
      surfaceContainerLowest: surface,
      surfaceContainerLow: container(0.035),
      surfaceContainer: container(0.06),
      surfaceContainerHigh: container(0.085),
      surfaceContainerHighest: container(0.12),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      scaffoldBackgroundColor: colors.surface,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        backgroundColor: colors.surfaceContainer,
      ),
    );
  }
}
