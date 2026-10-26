import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import 'settings_provider.dart';

// =============================================================================
//  CONSTANTS
// =============================================================================

const String _kUserAgent = 'Mozilla/5.0 (Linux; Android 11; TV) NovaIPTV/1.0';

/// Hard ceiling (in pixels) for the decoded size of ANY network image.
const double kMaxImageCache = 200;

const Color kGold = Color(0xFFFFC107);

// =============================================================================
//  ENTRY POINT
// =============================================================================

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    MediaKit.ensureInitialized();

    // Image VRAM guard: small global cache, evicts aggressively on weak boxes.
    final cache = PaintingBinding.instance.imageCache;
    cache.maximumSize = 120;
    cache.maximumSizeBytes = 32 << 20; // 32 MB

    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      debugPrint('FlutterError: ${details.exceptionAsString()}');
    };
    // A widget that throws while building shows a quiet fallback instead of
    // the red/grey crash screen.
    ErrorWidget.builder = (details) => const _FallbackBox();

    final settings = await SettingsProvider.load();

    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<DataStore>(create: (_) => DataStore()),
          ChangeNotifierProvider<PlaybackController>(create: (_) => PlaybackController()),
        ],
        child: const NovaApp(),
      ),
    );
  }, (error, stack) => debugPrint('Uncaught: $error\n$stack'));
}

class _FallbackBox extends StatelessWidget {
  const _FallbackBox();
  @override
  Widget build(BuildContext context) => const Center(
        child: Icon(Icons.broken_image_outlined, color: Colors.white38, size: 28),
      );
}

// =============================================================================
//  THEME
// =============================================================================

class NovaColors {
  const NovaColors({
    required this.bg,
    required this.surface,
    required this.surfaceHi,
    required this.text,
    required this.dim,
    required this.focus,
    required this.accent,
  });

  final Color bg, surface, surfaceHi, text, dim, focus, accent;

  static const dark = NovaColors(
    bg: Color(0xFF0F0F14),
    surface: Color(0xFF1A1A22),
    surfaceHi: Color(0xFF2B2B38),
    text: Colors.white,
    dim: Color(0xFF9A9AA8),
    focus: Colors.white, // stark Apple-TV white ring
    accent: Color(0xFF0A84FF),
  );

  static const light = NovaColors(
    bg: Color(0xFFF2F2F7),
    surface: Colors.white,
    surfaceHi: Color(0xFFE3E3EA),
    text: Color(0xFF111114),
    dim: Color(0xFF6B6B76),
    focus: Color(0xFF0A84FF), // blue ring (white would vanish on light bg)
    accent: Color(0xFF0A84FF),
  );

  static NovaColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

ThemeData buildTheme(Brightness brightness, AppFont font) {
  final c = brightness == Brightness.dark ? NovaColors.dark : NovaColors.light;

  var text = Typography.material2021().englishLike.apply(
        bodyColor: c.text,
        displayColor: c.text,
        fontFamily: font.family,
        fontFamilyFallback: font.family == null ? null : const ['Roboto'],
      );
  if (font.spacing != 0) {
    TextStyle? sp(TextStyle? s) => s?.copyWith(letterSpacing: font.spacing);
    text = text.copyWith(
      bodyLarge: sp(text.bodyLarge),
      bodyMedium: sp(text.bodyMedium),
      bodySmall: sp(text.bodySmall),
      titleLarge: sp(text.titleLarge),
      titleMedium: sp(text.titleMedium),
      titleSmall: sp(text.titleSmall),
      labelLarge: sp(text.labelLarge),
    );
  }

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: c.bg,
    colorScheme: ColorScheme.fromSeed(
      seedColor: c.accent,
      brightness: brightness,
    ).copyWith(surface: c.surface, primary: c.accent),
    splashFactory: NoSplash.splashFactory, // ink ripples are costly on weak GPUs
    visualDensity: VisualDensity.compact,
    textTheme: text,
  );
}

// =============================================================================
//  ANIMATION ENGINE  (one place that decides how much motion the UI gets)
// =============================================================================

Duration animDuration(AnimProfile m) => switch (m) {
      AnimProfile.none => Duration.zero,
      AnimProfile.light => const Duration(milliseconds: 150),
      AnimProfile.medium => const Duration(milliseconds: 300),
    };

/// Inherited, so Focusable/cards read the current profile without each one
/// subscribing to the whole SettingsProvider.
class UiScope extends InheritedWidget {
  const UiScope({super.key, required this.anim, required this.ratings, required super.child});

  final AnimProfile anim;
  final bool ratings;

  static UiScope of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<UiScope>()!;
  static UiScope peek(BuildContext context) => context.getInheritedWidgetOfExactType<UiScope>()!;

  @override
  bool updateShouldNotify(UiScope old) => anim != old.anim || ratings != old.ratings;
}

/// Page route whose transition obeys the animation profile.
Route<T> novaRoute<T>(BuildContext context, WidgetBuilder builder) {
  final mode = UiScope.peek(context).anim;
  final d = animDuration(mode);
  return PageRouteBuilder<T>(
    transitionDuration: d,
    reverseTransitionDuration: d,
    pageBuilder: (ctx, _, __) => builder(ctx),
    transitionsBuilder: (ctx, anim, _, child) => switch (mode) {
      AnimProfile.none => child,
      AnimProfile.light => FadeTransition(opacity: anim, child: child), // linear fade
      AnimProfile.medium => FadeTransition(
          opacity: anim.drive(CurveTween(curve: Curves.easeOutCubic)),
          child: ScaleTransition(
            scale: anim.drive(Tween<double>(begin: 0.95, end: 1.0).chain(CurveTween(curve: Curves.easeOutBack))),
            child: child,
          ),
        ),
    },
  );
}

Future<T?> showNovaDialog<T>(BuildContext context, WidgetBuilder builder) {
  final mode = UiScope.peek(context).anim;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.black54,
    transitionDuration: animDuration(mode),
    pageBuilder: (ctx, _, __) => SafeArea(child: Center(child: builder(ctx))),
    transitionBuilder: (ctx, anim, _, child) => switch (mode) {
      AnimProfile.none => child,
      AnimProfile.light => FadeTransition(opacity: anim, child: child),
      AnimProfile.medium => FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: anim.drive(Tween<double>(begin: 0.92, end: 1.0).chain(CurveTween(curve: Curves.easeOutBack))),
            child: child,
          ),
        ),
    },
  );
}

// =============================================================================
//  APP ROOT
// =============================================================================

class NovaApp extends StatelessWidget {
  const NovaApp({super.key});

  @override
  Widget build(BuildContext context) {
    // select(): only these values can rebuild the MaterialApp.
    final mode = context.select<SettingsProvider, ThemeMode>((s) => s.themeMode);
    final scale = context.select<SettingsProvider, double>((s) => s.fontProfile.scale);
    final font = context.select<SettingsProvider, AppFont>((s) => s.appFont);
    final anim = context.select<SettingsProvider, AnimProfile>((s) => s.effectiveAnim);
    final ratings = context.select<SettingsProvider, bool>((s) => s.showRatings);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Nova IPTV',
      themeMode: mode,
      theme: buildTheme(Brightness.light, font),
      darkTheme: buildTheme(Brightness.dark, font),
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        return UiScope(
          anim: anim,
          ratings: ratings,
          // Font engine: one TextScaler (+ bold flag for High Contrast) injected
          // at the root; every Text resizes without touching a single TextStyle.
          child: MediaQuery(
            data: mq.copyWith(
              textScaler: TextScaler.linear(scale),
              boldText: font.bold || mq.boldText,
            ),
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
      home: const AppRoot(),
    );
  }
}

class AppRoot extends StatefulWidget {
  const AppRoot({super.key});
  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final settings = context.read<SettingsProvider>();
      final store = context.read<DataStore>();
      if (settings.hasCredentials && store.state == LoadState.idle) {
        store.load(XtreamApi.fromSettings(settings));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasCreds = context.select<SettingsProvider, bool>((s) => s.hasCredentials);
    final state = context.select<DataStore, LoadState>((s) => s.state);
    final store = context.read<DataStore>();

    if (!hasCreds) return const LoginScreen();
    switch (state) {
      case LoadState.idle:
      case LoadState.loading:
        return LoadingView(message: context.select<DataStore, String>((s) => s.status));
      case LoadState.error:
        return ErrorView(
          message: store.error ?? 'Something went wrong.',
          onRetry: () => store.load(XtreamApi.fromSettings(context.read<SettingsProvider>())),
          onSignOut: () => signOut(context),
        );
      case LoadState.ready:
        return const Shell();
    }
  }
}

void signOut(BuildContext context) {
  context.read<PlaybackController>().stop();
  context.read<DataStore>().clear();
  context.read<SettingsProvider>().clearCredentials();
}

// =============================================================================
//  MODELS + PARSING
// =============================================================================

enum MediaKind { live, movie, series }

class MediaItem {
  const MediaItem({
    required this.id,
    required this.name,
    required this.icon,
    required this.categoryId,
    required this.ext,
    required this.rating,
    required this.added,
    required this.kind,
    required this.key,
  });

  final String id, name, icon, categoryId, ext, key;
  final double rating; // always normalised to 0..10
  final int added; // unix seconds, 0 when unknown
  final MediaKind kind;

  String get uid => '${kind.name}:$id';
  String get lockKey => '${kind.name}:$categoryId';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'icon': icon,
        'cat': categoryId,
        'ext': ext,
        'rating': rating,
        'added': added,
        'kind': kind.index,
      };

  factory MediaItem.fromJson(Map<String, dynamic> j) {
    final name = (j['name'] ?? '').toString();
    final kindIndex = (j['kind'] is int) ? j['kind'] as int : 0;
    return MediaItem(
      id: (j['id'] ?? '').toString(),
      name: name,
      icon: (j['icon'] ?? '').toString(),
      categoryId: (j['cat'] ?? '').toString(),
      ext: (j['ext'] ?? '').toString(),
      rating: (j['rating'] is num) ? (j['rating'] as num).toDouble() : 0,
      added: (j['added'] is num) ? (j['added'] as num).toInt() : 0,
      kind: MediaKind.values[kindIndex.clamp(0, MediaKind.values.length - 1)],
      key: name.toLowerCase(),
    );
  }
}

class Episode {
  const Episode({
    required this.id,
    required this.title,
    required this.ext,
    required this.season,
    required this.number,
  });
  final String id, title, ext;
  final int season, number;
}

class SeriesDetail {
  const SeriesDetail({required this.plot, required this.seasons});
  final String plot;
  final Map<int, List<Episode>> seasons;
}

class CategoryEntry {
  const CategoryEntry(this.id, this.name, this.count);
  final String id, name;
  final int count;
}

String _str(dynamic v) => v == null ? '' : v.toString().trim();

/// Tolerant number parser: accepts ints, doubles, "8.4", "8,4", " 7 ".
double _num(dynamic v) {
  if (v is num) return v.toDouble();
  return double.tryParse(_str(v).replaceAll(',', '.')) ?? 0;
}

int _int(dynamic v, int fallback) {
  if (v is num) return v.toInt();
  return int.tryParse(_str(v)) ?? fallback;
}

List<MediaItem> _parseItems(List<dynamic> raw, MediaKind kind) {
  final out = <MediaItem>[];
  for (final e in raw) {
    if (e is! Map) continue;
    final id = _str(kind == MediaKind.series ? e['series_id'] : e['stream_id']);
    if (id.isEmpty) continue;
    final rawName = _str(e['name']);
    final name = rawName.isEmpty ? 'Untitled' : rawName;

    // Server 'rating' is 0-10; 'rating_5based' is 0-5. Normalise to 0-10.
    final r10 = _num(e['rating']);
    final r5 = _num(e['rating_5based']);
    final rating = (r10 > 0 ? r10 : r5 * 2).clamp(0.0, 10.0).toDouble();

    out.add(MediaItem(
      id: id,
      name: name,
      icon: _str(kind == MediaKind.series ? (e['cover'] ?? e['stream_icon']) : e['stream_icon']),
      categoryId: _str(e['category_id']),
      ext: _str(e['container_extension']),
      rating: rating,
      added: _int(kind == MediaKind.series ? (e['last_modified'] ?? e['added']) : e['added'], 0),
      kind: kind,
      key: name.toLowerCase(),
    ));
  }
  return out;
}

List<MediaItem> _decodeItems(List<String> raw) {
  final out = <MediaItem>[];
  for (final s in raw) {
    try {
      final j = jsonDecode(s);
      if (j is Map<String, dynamic>) out.add(MediaItem.fromJson(j));
    } catch (_) {/* skip corrupt entries */}
  }
  return out;
}

SeriesDetail _parseSeriesDetail(dynamic data) {
  var plot = '';
  final seasons = <int, List<Episode>>{};
  if (data is Map) {
    final info = data['info'];
    if (info is Map) plot = _str(info['plot']);

    void addEpisodes(dynamic list, int fallbackSeason) {
      if (list is! List) return;
      for (final e in list) {
        if (e is! Map) continue;
        final id = _str(e['id']);
        if (id.isEmpty) continue;
        final season = _int(e['season'], fallbackSeason);
        final number = _int(e['episode_num'], 0);
        final title = _str(e['title']);
        (seasons[season] ??= <Episode>[]).add(Episode(
          id: id,
          title: title.isEmpty ? 'Episode $number' : title,
          ext: _str(e['container_extension']).isEmpty ? 'mp4' : _str(e['container_extension']),
          season: season,
          number: number,
        ));
      }
    }

    final eps = data['episodes'];
    if (eps is Map) {
      eps.forEach((k, v) => addEpisodes(v, _int(k, 1)));
    } else if (eps is List) {
      for (var i = 0; i < eps.length; i++) {
        addEpisodes(eps[i], i + 1);
      }
    }
  }
  for (final list in seasons.values) {
    list.sort((a, b) => a.number.compareTo(b.number));
  }
  return SeriesDetail(plot: plot, seasons: seasons);
}

// =============================================================================
//  XTREAM CODES API  (all heavy work runs in a background isolate)
// =============================================================================

class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

Future<dynamic> _getJson(String url) async {
  final client = http.Client();
  try {
    final res = await client.get(Uri.parse(url), headers: const {
      'Accept': 'application/json',
      'User-Agent': _kUserAgent,
    }).timeout(const Duration(seconds: 90));
    if (res.statusCode != 200) {
      throw ApiException('Server responded with HTTP ${res.statusCode}.');
    }
    return jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
  } finally {
    client.close();
  }
}

Future<dynamic> _isolateJson(String url) => Isolate.run(() => _getJson(url));

Future<List<MediaItem>> _isolateStreams(String url, MediaKind kind) => Isolate.run(() async {
      final data = await _getJson(url);
      return data is List ? _parseItems(data, kind) : <MediaItem>[];
    });

Future<Map<String, String>> _isolateCategories(String url) => Isolate.run(() async {
      final data = await _getJson(url);
      final out = <String, String>{};
      if (data is List) {
        for (final e in data) {
          if (e is Map) out[_str(e['category_id'])] = _str(e['category_name']);
        }
      }
      return out;
    });

Future<SeriesDetail> _isolateSeries(String url) =>
    Isolate.run(() async => _parseSeriesDetail(await _getJson(url)));

class XtreamApi {
  XtreamApi(this.server, this.user, this.pass);

  factory XtreamApi.fromSettings(SettingsProvider s) =>
      XtreamApi(normalize(s.serverUrl), s.username, s.password);

  final String server, user, pass;

  static String normalize(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return s;
    if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'http://$s';
    s = s.replaceAll(RegExp(r'/(player_api|get)\.php.*$'), '');
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  String _url([Map<String, String> extra = const {}]) => Uri.parse('$server/player_api.php')
      .replace(queryParameters: {'username': user, 'password': pass, ...extra}).toString();

  Future<void> authenticate() async {
    final data = await _isolateJson(_url());
    final info = data is Map ? data['user_info'] : null;
    if (info is! Map || _str(info['auth']) != '1') {
      throw ApiException('Invalid server, username or password.');
    }
    final status = _str(info['status']).toLowerCase();
    if (status.isNotEmpty && status != 'active') {
      throw ApiException('This account is $status.');
    }
  }

  Future<Map<String, String>> categories(MediaKind kind) => _isolateCategories(_url({
        'action': switch (kind) {
          MediaKind.live => 'get_live_categories',
          MediaKind.movie => 'get_vod_categories',
          MediaKind.series => 'get_series_categories',
        }
      }));

  Future<List<MediaItem>> streams(MediaKind kind) => _isolateStreams(
      _url({
        'action': switch (kind) {
          MediaKind.live => 'get_live_streams',
          MediaKind.movie => 'get_vod_streams',
          MediaKind.series => 'get_series',
        }
      }),
      kind);

  Future<SeriesDetail> seriesInfo(String seriesId) =>
      _isolateSeries(_url({'action': 'get_series_info', 'series_id': seriesId}));

  String get _cred => '${Uri.encodeComponent(user)}/${Uri.encodeComponent(pass)}';

  String liveUrl(String id, {bool ts = false}) => '$server/live/$_cred/$id.${ts ? 'ts' : 'm3u8'}';

  String movieUrl(String id, String ext) =>
      '$server/movie/$_cred/$id.${ext.isEmpty ? 'mp4' : ext}';

  String episodeUrl(String id, String ext) =>
      '$server/series/$_cred/$id.${ext.isEmpty ? 'mp4' : ext}';
}

// =============================================================================
//  DATA STORE  (in-memory cache, master search, background sync)
// =============================================================================

enum LoadState { idle, loading, ready, error }

class _Fetched {
  _Fetched(this.live, this.movies, this.series, this.names);
  final List<MediaItem> live, movies, series;
  final Map<MediaKind, Map<String, String>> names;
}

class DataStore extends ChangeNotifier {
  LoadState state = LoadState.idle;
  String status = '';
  String? error;
  XtreamApi? api;

  /// Bumped every time the catalogue is replaced, so screens can rebuild.
  int revision = 0;
  bool syncing = false;
  DateTime? lastSync;

  List<MediaItem> live = const [];
  List<MediaItem> movies = const [];
  List<MediaItem> series = const [];
  List<MediaItem> trending = const [];
  List<MediaItem> recentlyAdded = const [];
  MediaItem? hero;

  final Map<MediaKind, Map<String, List<MediaItem>>> _groups = {};
  final Map<MediaKind, List<CategoryEntry>> _categories = {};

  List<MediaItem> _all(MediaKind k) => switch (k) {
        MediaKind.live => live,
        MediaKind.movie => movies,
        MediaKind.series => series,
      };

  List<CategoryEntry> categoriesOf(MediaKind k) => _categories[k] ?? const [];

  List<MediaItem> itemsFor(MediaKind k, String categoryId) {
    if (categoryId == '*') return _all(k);
    return _groups[k]?[categoryId] ?? const [];
  }

  Future<List<MediaItem>> _tolerant(Future<List<MediaItem>> f, List<Object> errors) async {
    try {
      return await f;
    } catch (e) {
      errors.add(e);
      return const <MediaItem>[];
    }
  }

  Future<_Fetched> _fetchAll(XtreamApi a, {void Function(String)? progress}) async {
    progress?.call('Loading categories…');
    final names = <MediaKind, Map<String, String>>{};
    for (final k in MediaKind.values) {
      try {
        names[k] = await a.categories(k);
      } catch (_) {
        names[k] = <String, String>{};
      }
    }

    // Sequential on purpose: keeps peak RAM low on 1 GB devices.
    final errors = <Object>[];
    progress?.call('Loading live channels…');
    final l = await _tolerant(a.streams(MediaKind.live), errors);
    progress?.call('Loading movies…');
    final m = await _tolerant(a.streams(MediaKind.movie), errors);
    progress?.call('Loading series…');
    final s = await _tolerant(a.streams(MediaKind.series), errors);

    if (l.isEmpty && m.isEmpty && s.isEmpty) {
      throw errors.isNotEmpty ? errors.first : ApiException('This playlist is empty.');
    }
    return _Fetched(l, m, s, names);
  }

  void _commit(_Fetched f) {
    live = f.live;
    movies = f.movies;
    series = f.series;
    _index(f.names);
    revision++;
  }

  Future<void> load(XtreamApi newApi) async {
    api = newApi;
    state = LoadState.loading;
    error = null;
    status = 'Signing in…';
    notifyListeners();

    try {
      await newApi.authenticate();
      final f = await _fetchAll(newApi, progress: _setStatus);
      _commit(f);
      lastSync = DateTime.now();
      state = LoadState.ready;
    } catch (e) {
      error = _friendly(e);
      state = LoadState.error;
    }
    notifyListeners();
  }

  /// Live Data Provider Sync: re-fetches everything in the background and
  /// swaps the catalogue atomically. Theme, favorites, recents, PIN and the
  /// current screen are untouched; on failure the old cache stays in place.
  Future<bool> sync(XtreamApi newApi) async {
    if (syncing) return false;
    syncing = true;
    notifyListeners();
    try {
      final f = await _fetchAll(newApi);
      api = newApi;
      _commit(f);
      lastSync = DateTime.now();
      syncing = false;
      notifyListeners();
      return true;
    } catch (_) {
      syncing = false;
      notifyListeners();
      return false;
    }
  }

  void _setStatus(String s) {
    status = s;
    notifyListeners();
  }

  void _index(Map<MediaKind, Map<String, String>> names) {
    for (final k in MediaKind.values) {
      final items = _all(k);
      final groups = <String, List<MediaItem>>{};
      for (final i in items) {
        (groups[i.categoryId] ??= <MediaItem>[]).add(i);
      }
      _groups[k] = groups;

      final list = <CategoryEntry>[CategoryEntry('*', 'All', items.length)];
      final n = names[k] ?? const <String, String>{};
      n.forEach((id, name) {
        final count = groups[id]?.length ?? 0;
        if (count > 0) list.add(CategoryEntry(id, name.isEmpty ? 'Category $id' : name, count));
      });
      groups.forEach((id, v) {
        if (!n.containsKey(id)) {
          list.add(CategoryEntry(id, id.isEmpty ? 'Uncategorized' : 'Category $id', v.length));
        }
      });
      _categories[k] = list;
    }

    trending = _topK(movies, 20, (m) => m.rating, (m) => m.icon.isNotEmpty && m.rating > 0);
    if (trending.isEmpty) {
      trending = movies.where((m) => m.icon.isNotEmpty).take(20).toList();
    }

    final addedMovies = _topK(movies, 20, (m) => m.added.toDouble(), (m) => m.icon.isNotEmpty && m.added > 0);
    final addedSeries = _topK(series, 20, (m) => m.added.toDouble(), (m) => m.icon.isNotEmpty && m.added > 0);
    recentlyAdded = ([...addedMovies, ...addedSeries]..sort((a, b) => b.added.compareTo(a.added)))
        .take(20)
        .toList();

    hero = trending.isNotEmpty
        ? trending.first
        : (series.isNotEmpty ? series.first : (live.isNotEmpty ? live.first : null));
  }

  /// O(n·k) top-k selection: no 100k-element sort.
  List<MediaItem> _topK(
    List<MediaItem> src,
    int k,
    double Function(MediaItem) score,
    bool Function(MediaItem) where,
  ) {
    final top = <MediaItem>[];
    for (final m in src) {
      if (!where(m)) continue;
      final s = score(m);
      if (top.length < k || s > score(top.last)) {
        var i = top.length;
        while (i > 0 && score(top[i - 1]) < s) {
          i--;
        }
        top.insert(i, m);
        if (top.length > k) top.removeLast();
      }
    }
    return top;
  }

  /// Master search: all terms must appear in the (pre-lowercased) title.
  /// Early-exits at [limit] so a 100k-item playlist never stalls the UI.
  List<MediaItem> search(MediaKind kind, String query, {int limit = 40}) {
    final terms = query.toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (terms.isEmpty) return const [];
    final out = <MediaItem>[];
    for (final item in _all(kind)) {
      var ok = true;
      for (final t in terms) {
        if (!item.key.contains(t)) {
          ok = false;
          break;
        }
      }
      if (ok) {
        out.add(item);
        if (out.length >= limit) break;
      }
    }
    return out;
  }

  void clear() {
    api = null;
    live = movies = series = trending = recentlyAdded = const [];
    hero = null;
    _groups.clear();
    _categories.clear();
    state = LoadState.idle;
    error = null;
    syncing = false;
    revision++;
    notifyListeners();
  }

  String _friendly(Object e) {
    if (e is ApiException) return e.message;
    if (e is TimeoutException) return 'The server took too long to respond.';
    final s = e.toString();
    if (s.contains('SocketException') || s.contains('ClientException')) {
      return 'Cannot reach the server. Check the address and your connection.';
    }
    if (s.contains('FormatException')) return 'The server returned an unexpected response.';
    return 'Unexpected error: $s';
  }
}

Future<void> syncNow(BuildContext context) async {
  final store = context.read<DataStore>();
  final settings = context.read<SettingsProvider>();
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (store.syncing) return;
  final ok = await store.sync(XtreamApi.fromSettings(settings));
  messenger?.showSnackBar(SnackBar(
    duration: const Duration(seconds: 3),
    content: Text(ok ? 'Playlist updated.' : 'Sync failed — showing cached data.'),
  ));
}

// =============================================================================
//  PLAYBACK CONTROLLER  (single native player, auto-recovery, sleep timer)
// =============================================================================

class PlaybackController extends ChangeNotifier {
  PlaybackController() {
    player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 16 * 1024 * 1024, // small demuxer buffer for 1 GB devices
        title: 'Nova IPTV',
      ),
    );
    controller = VideoController(
      player,
      configuration: const VideoControllerConfiguration(enableHardwareAcceleration: true),
    );
    _tuneNative();
    _subs.add(player.stream.error.listen(_onError));
    _subs.add(player.stream.buffering.listen(_onBuffering));
    _subs.add(player.stream.completed.listen(_onCompleted));
  }

  late final Player player;
  late final VideoController controller;
  final List<StreamSubscription<dynamic>> _subs = [];

  MediaItem? current;
  String title = '';
  String? error;

  /// Short status shown on the video while silently reconnecting.
  String? notice;

  /// Incremented when all reconnect attempts fail -> the Shell shows a dialog.
  int fatalSerial = 0;
  String? fatalMessage;

  DateTime? sleepAt;

  String? _url;
  String? _fallbackUrl;
  int _retries = 0;
  bool _recovering = false;
  bool _gaveUp = false;
  Timer? _stallTimer;
  Timer? _stableTimer;
  Timer? _sleepTimer;

  static const int _maxRetries = 3;

  bool get isLive => current?.kind == MediaKind.live;

  Future<void> _tuneNative() async {
    try {
      final p = player.platform as dynamic;
      await p.setProperty('hwdec', 'mediacodec,mediacodec-copy'); // MediaCodec first
      await p.setProperty('demuxer-max-back-bytes', '8MiB');
      await p.setProperty('cache', 'yes');
      await p.setProperty('cache-secs', '15');
      await p.setProperty('vd-lavc-threads', '2');
      await p.setProperty('framedrop', 'vo');
    } catch (e) {
      debugPrint('Native tuning skipped: $e');
    }
  }

  // ------------------------------------------------------------- playing

  Future<void> playLive(MediaItem item, XtreamApi api) {
    current = item;
    title = item.name;
    return _open(api.liveUrl(item.id), fallback: api.liveUrl(item.id, ts: true));
  }

  Future<void> playMovie(MediaItem item, XtreamApi api) {
    current = item;
    title = item.name;
    return _open(api.movieUrl(item.id, item.ext));
  }

  Future<void> playEpisode(MediaItem series, Episode ep, XtreamApi api) {
    current = series;
    title = '${series.name} • S${ep.season} E${ep.number}';
    return _open(api.episodeUrl(ep.id, ep.ext));
  }

  /// User-initiated open: resets all recovery state.
  Future<void> _open(String url, {String? fallback}) async {
    _cancelRecoveryTimers();
    _url = url;
    _fallbackUrl = fallback;
    _retries = 0;
    _recovering = false;
    _gaveUp = false;
    error = null;
    notice = null;
    fatalMessage = null;
    notifyListeners();
    try {
      await player.open(Media(url, httpHeaders: const {'User-Agent': _kUserAgent}));
    } catch (e) {
      error = 'Unable to start playback.';
      notifyListeners();
    }
  }

  void retry() {
    final u = _url;
    if (u != null) _open(u);
  }

  // ------------------------------------------------- smart auto-recovery

  void _onError(String message) {
    if (_url == null || _gaveUp) return;
    final fb = _fallbackUrl;
    if (fb != null) {
      // Live: if .m3u8 fails, silently try raw MPEG-TS first (not a "retry").
      _fallbackUrl = null;
      _url = fb;
      player.open(Media(fb, httpHeaders: const {'User-Agent': _kUserAgent}));
      return;
    }
    _recover();
  }

  void _onCompleted(bool done) {
    // A live stream should never "finish": treat it as a dropped connection.
    if (done && isLive && _url != null && !_recovering && !_gaveUp) _recover();
  }

  void _onBuffering(bool buffering) {
    _stallTimer?.cancel();
    if (buffering && current != null && _url != null && !_recovering && !_gaveUp) {
      // Buffering for 25 s straight = the network silently died.
      _stallTimer = Timer(const Duration(seconds: 25), _recover);
    }
  }

  Future<void> _recover() async {
    if (_url == null || current == null || _recovering || _gaveUp) return;
    if (_retries >= _maxRetries) {
      _giveUp();
      return;
    }
    _retries++;
    _recovering = true;
    _stableTimer?.cancel();
    _stallTimer?.cancel();
    notice = 'Reconnecting… ($_retries/$_maxRetries)';
    notifyListeners();

    final resumeAt = isLive ? null : player.state.position;
    await Future<void>.delayed(Duration(seconds: _retries)); // 1 s, 2 s, 3 s back-off

    final url = _url;
    if (url == null || _gaveUp) {
      _recovering = false;
      return;
    }
    try {
      await player.open(Media(url, start: resumeAt, httpHeaders: const {'User-Agent': _kUserAgent}));
    } catch (_) {/* the error stream will trigger the next attempt */}
    _recovering = false;

    // If playback stays healthy for 8 s, the incident is over.
    _stableTimer = Timer(const Duration(seconds: 8), () {
      _retries = 0;
      if (notice != null) {
        notice = null;
        notifyListeners();
      }
    });
  }

  void _giveUp() {
    _gaveUp = true;
    _recovering = false;
    _retries = 0;
    notice = null;
    error = 'Connection lost.';
    fatalMessage = 'The connection to "$title" was lost and $_maxRetries reconnect attempts failed.';
    fatalSerial++;
    player.stop();
    notifyListeners();
  }

  void _cancelRecoveryTimers() {
    _stallTimer?.cancel();
    _stableTimer?.cancel();
  }

  // ---------------------------------------------------------- transport

  void togglePlay() => player.playOrPause();

  void seekBy(Duration delta) {
    if (isLive) return;
    var target = player.state.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    player.seek(target);
  }

  // -------------------------------------------------------- sleep timer

  /// Pass null to cancel. One-shot timer: zero per-second rebuild cost.
  void setSleep(Duration? d) {
    _sleepTimer?.cancel();
    if (d == null) {
      sleepAt = null;
    } else {
      sleepAt = DateTime.now().add(d);
      _sleepTimer = Timer(d, _onSleep);
    }
    notifyListeners();
  }

  Future<void> _onSleep() async {
    _sleepTimer = null;
    sleepAt = null;
    await stop();
    // Close the app so the TV can fall back to its own idle / standby timer.
    await SystemNavigator.pop();
  }

  Future<void> stop() async {
    _cancelRecoveryTimers();
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepAt = null;
    current = null;
    error = null;
    notice = null;
    _url = null;
    _fallbackUrl = null;
    _retries = 0;
    _recovering = false;
    _gaveUp = false;
    notifyListeners();
    try {
      await player.stop(); // releases decoder + buffers immediately
    } catch (_) {}
  }

  @override
  void dispose() {
    _cancelRecoveryTimers();
    _sleepTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    player.dispose();
    super.dispose();
  }
}

// =============================================================================
//  ACTIONS (open / favorite / parental lock)
// =============================================================================

void toggleFavorite(BuildContext context, MediaItem item) {
  context.read<SettingsProvider>().toggleFavorite(item.uid, jsonEncode(item.toJson()));
}

/// Shows the PIN keypad when [key] is locked; true when playback may proceed.
Future<bool> ensureUnlocked(BuildContext context, String key) async {
  final settings = context.read<SettingsProvider>();
  if (!settings.isKeyLocked(key)) return true;
  final pin = await showNovaDialog<String>(
    context,
    (_) => PinDialog(
      title: 'Parental PIN',
      subtitle: 'This category is locked.',
      verify: settings.checkPin,
    ),
  );
  if (pin == null) return false;
  settings.unlock(key);
  return true;
}

Future<void> openItem(BuildContext context, MediaItem item) async {
  final store = context.read<DataStore>();
  final api = store.api;
  if (api == null) return;
  final playback = context.read<PlaybackController>();
  final settings = context.read<SettingsProvider>();

  if (!await ensureUnlocked(context, item.lockKey)) return;
  if (!context.mounted) return;

  settings.pushRecent(item.uid, jsonEncode(item.toJson()));

  switch (item.kind) {
    case MediaKind.live:
      await playback.playLive(item, api);
    case MediaKind.movie:
      await playback.playMovie(item, api);
    case MediaKind.series:
      await Navigator.of(context).push(novaRoute<void>(context, (_) => SeriesScreen(item: item)));
  }
}

// =============================================================================
//  REUSABLE WIDGETS
// =============================================================================

/// Remote-control friendly focus wrapper. Obvious focus ring on every profile;
/// how it animates depends on the Interface Animations profile:
///   none   -> instant swap, no scrolling animation
///   light  -> linear 150 ms opacity fade of the ring
///   medium -> 300 ms spring-loaded scale + eased highlight
class Focusable extends StatefulWidget {
  const Focusable({
    super.key,
    required this.child,
    required this.onTap,
    this.onAlt,
    this.autofocus = false,
    this.radius = 12,
    this.padding = EdgeInsets.zero,
    this.color,
    this.focusColor,
  });

  final Widget child;
  final VoidCallback? onTap;

  /// Secondary action (long-press / remote Menu or Info key): favorites.
  final VoidCallback? onAlt;
  final bool autofocus;
  final double radius;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Color? focusColor;

  @override
  State<Focusable> createState() => _FocusableState();
}

class _FocusableState extends State<Focusable> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final c = NovaColors.of(context);
    final mode = UiScope.of(context).anim;
    final radius = BorderRadius.circular(widget.radius);
    final hi = widget.focusColor ?? c.surfaceHi;
    final idle = widget.color;

    BoxDecoration deco() => BoxDecoration(
          borderRadius: radius,
          color: _focused ? hi : idle,
          // Constant 3 px width => focusing never shifts the layout.
          border: Border.all(color: _focused ? c.focus : Colors.transparent, width: 3),
        );

    Widget visual;
    switch (mode) {
      case AnimProfile.none:
        visual = Container(padding: widget.padding, decoration: deco(), child: widget.child);
      case AnimProfile.light:
        visual = Stack(
          children: [
            Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(borderRadius: radius, color: idle))),
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _focused ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.linear,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: radius,
                      color: hi,
                      border: Border.all(color: c.focus, width: 3),
                    ),
                  ),
                ),
              ),
            ),
            Padding(padding: widget.padding.add(const EdgeInsets.all(3)), child: widget.child),
          ],
        );
      case AnimProfile.medium:
        visual = AnimatedScale(
          scale: _focused ? 1.06 : 1.0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutBack, // spring-loaded overshoot
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            padding: widget.padding,
            decoration: deco(),
            child: widget.child,
          ),
        );
    }

    Widget result = InkWell(
      autofocus: widget.autofocus,
      onTap: widget.onTap,
      onLongPress: widget.onAlt,
      borderRadius: radius,
      focusColor: Colors.transparent,
      hoverColor: Colors.transparent,
      highlightColor: Colors.transparent,
      splashColor: Colors.transparent,
      onFocusChange: (focused) {
        if (focused) {
          Scrollable.ensureVisible(
            context,
            alignment: 0.5,
            duration: mode == AnimProfile.none ? Duration.zero : animDuration(mode) * 0.7,
            curve: mode == AnimProfile.medium ? Curves.easeOutCubic : Curves.linear,
          );
        }
        if (mounted) setState(() => _focused = focused);
      },
      child: visual,
    );

    if (widget.onAlt != null) {
      result = Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (node, e) {
          if (e is KeyDownEvent &&
              (e.logicalKey == LogicalKeyboardKey.contextMenu || e.logicalKey == LogicalKeyboardKey.info)) {
            widget.onAlt!();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: result,
      );
    }
    return result;
  }
}

/// Ring for composite Material controls (SwitchListTile, DropdownButton) that
/// own their focus nodes: lights up whenever anything inside has focus.
class FocusRing extends StatefulWidget {
  const FocusRing({super.key, required this.child});
  final Widget child;
  @override
  State<FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<FocusRing> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final c = NovaColors.of(context);
    final mode = UiScope.of(context).anim;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) {
        if (f) {
          Scrollable.ensureVisible(
            context,
            alignment: 0.5,
            duration: mode == AnimProfile.none ? Duration.zero : animDuration(mode) * 0.7,
          );
        }
        if (mounted) setState(() => _focused = f);
      },
      child: AnimatedContainer(
        duration: animDuration(mode),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: _focused ? c.surfaceHi : c.surface,
          border: Border.all(color: _focused ? c.focus : Colors.transparent, width: 3),
        ),
        child: widget.child,
      ),
    );
  }
}

class SettingSwitch extends StatelessWidget {
  const SettingSwitch({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.autofocus = false,
  });

  final String title;
  final String? subtitle;
  final bool value, autofocus;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: FocusRing(
          child: SwitchListTile(
            autofocus: autofocus,
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: subtitle == null ? null : Text(subtitle!),
            value: value,
            onChanged: onChanged,
          ),
        ),
      );
}

class NovaButton extends StatelessWidget {
  const NovaButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.autofocus = false,
    this.filled = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool autofocus;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final c = NovaColors.of(context);
    return Focusable(
      autofocus: autofocus,
      onTap: onTap,
      color: filled ? c.accent : c.surface,
      focusColor: filled ? c.accent : c.surfaceHi,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 20, color: filled ? Colors.white : c.text),
            const SizedBox(width: 8),
          ],
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: filled ? Colors.white : c.text,
            ),
          ),
        ],
      ),
    );
  }
}

class IconBtn extends StatelessWidget {
  const IconBtn({super.key, required this.icon, required this.onTap, this.autofocus = false, this.color});
  final IconData icon;
  final VoidCallback? onTap;
  final bool autofocus;
  final Color? color;

  @override
  Widget build(BuildContext context) => Focusable(
        autofocus: autofocus,
        onTap: onTap,
        radius: 10,
        padding: const EdgeInsets.all(6),
        child: Icon(icon, size: 22, color: color),
      );
}

/// Star button: adds/removes [item] from "My Favorites".
class FavButton extends StatelessWidget {
  const FavButton({super.key, required this.item});
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final fav = context.select<SettingsProvider, bool>((s) => s.isFavorite(item.uid));
    return IconBtn(
      icon: fav ? Icons.star_rounded : Icons.star_border_rounded,
      color: fav ? kGold : null,
      onTap: () => toggleFavorite(context, item),
    );
  }
}

/// Network image with a hard VRAM guard: the decode size is capped at
/// [kMaxImageCache] on the longest side while preserving the aspect ratio of
/// the box it is drawn in (so nothing is distorted).
class NetImage extends StatelessWidget {
  const NetImage({
    super.key,
    required this.url,
    required this.width,
    required this.height,
    this.fit = BoxFit.cover,
  });

  final String url;
  final double width, height;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final c = NovaColors.of(context);
    Widget placeholder() => SizedBox(
          width: width,
          height: height,
          child: ColoredBox(
            color: c.surface,
            child: Icon(Icons.image_not_supported_outlined, color: c.dim, size: math.min(width, height) * 0.35),
          ),
        );

    if (!url.startsWith('http')) return placeholder();

    final scale = math.min(1.0, kMaxImageCache / math.max(width, height));
    return Image.network(
      url,
      width: width,
      height: height,
      cacheWidth: math.max(1, (width * scale).round()),
      cacheHeight: math.max(1, (height * scale).round()),
      fit: fit,
      gaplessPlayback: true,
      filterQuality: FilterQuality.low,
      errorBuilder: (_, __, ___) => placeholder(),
    );
  }
}

class _RatingPill extends StatelessWidget {
  const _RatingPill({required this.rating});
  final double rating;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(color: const Color(0xCC000000), borderRadius: BorderRadius.circular(8)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.star_rounded, size: 12, color: kGold),
            const SizedBox(width: 2),
            Text(
              rating.toStringAsFixed(1),
              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      );
}

/// Poster / channel card used in every carousel, grid and search row.
/// Remote: Select = open. Menu/Info key (or long-press) = toggle favorite.
class MediaCard extends StatelessWidget {
  const MediaCard({
    super.key,
    required this.item,
    required this.width,
    required this.imageHeight,
    this.autofocus = false,
  });

  final MediaItem item;
  final double width, imageHeight;
  final bool autofocus;

  static const double chrome = 14; // 3px border + 4px padding on each side

  static Size sizeFor(MediaKind kind) =>
      kind == MediaKind.live ? const Size(160, 90) : const Size(130, 195);

  @override
  Widget build(BuildContext context) {
    final c = NovaColors.of(context);
    final live = item.kind == MediaKind.live;
    final showRating = UiScope.of(context).ratings && !live && item.rating > 0;
    final isFav = context.select<SettingsProvider, bool>((s) => s.isFavorite(item.uid));

    return SizedBox(
      width: width,
      child: Focusable(
        autofocus: autofocus,
        onTap: () => openItem(context, item),
        onAlt: () => toggleFavorite(context, item),
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: ColoredBox(
                color: c.surface,
                child: Stack(
                  children: [
                    NetImage(
                      url: item.icon,
                      width: width - chrome,
                      height: imageHeight,
                      fit: live ? BoxFit.contain : BoxFit.cover,
                    ),
                    if (showRating) Positioned(top: 6, right: 6, child: _RatingPill(rating: item.rating)),
                    if (isFav)
                      const Positioned(
                        top: 6,
                        left: 6,
                        child: Icon(Icons.stars_rounded, color: kGold, size: 18, shadows: [
                          Shadow(blurRadius: 4, color: Colors.black),
                        ]),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              item.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}

class Carousel extends StatelessWidget {
  const Carousel({
    super.key,
    required this.title,
    required this.count,
    required this.height,
    required this.itemBuilder,
  });

  final String title;
  final int count, height;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    if (count == 0) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
          child: Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        ),
        SizedBox(
          height: height.toDouble(),
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            cacheExtent: 120, // strict: don't pre-build off-screen cards
            padding: const EdgeInsets.symmetric(horizontal: 14),
            itemCount: count,
            itemBuilder: itemBuilder,
          ),
        ),
      ],
    );
  }
}

class TvTextField extends StatefulWidget {
  const TvTextField({
    super.key,
    required this.controller,
    required this.label,
    required this.icon,
    this.obscure = false,
    this.action = TextInputAction.next,
    this.keyboardType,
    this.onSubmitted,
    this.onChanged,
    this.onDown,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool obscure, autofocus;
  final TextInputAction action;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onSubmitted, onChanged;
  final VoidCallback? onDown;

  @override
  State<TvTextField> createState() => _TvTextFieldState();
}

class _TvTextFieldState extends State<TvTextField> {
  late final FocusNode _node = FocusNode(debugLabel: widget.label, onKeyEvent: _onKey);

  // D-pad up/down must be able to LEAVE the text field (arrow keys otherwise
  // get swallowed by the text editing shortcuts).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      widget.onDown?.call();
      WidgetsBinding.instance.addPostFrameCallback((_) => node.focusInDirection(TraversalDirection.down));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      WidgetsBinding.instance.addPostFrameCallback((_) => node.focusInDirection(TraversalDirection.up));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = NovaColors.of(context);
    OutlineInputBorder border(Color color, double w) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: color, width: w),
        );
    return TextField(
      controller: widget.controller,
      focusNode: _node,
      autofocus: widget.autofocus,
      obscureText: widget.obscure,
      keyboardType: widget.keyboardType,
      textInputAction: widget.action,
      onSubmitted: widget.onSubmitted,
      onChanged: widget.onChanged,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: widget.label,
        prefixIcon: Icon(widget.icon),
        filled: true,
        fillColor: c.surface,
        enabledBorder: border(Colors.transparent, 3),
        focusedBorder: border(c.focus, 3),
        border: border(Colors.transparent, 3),
      ),
    );
  }
}

class LoadingView extends StatelessWidget {
  const LoadingView({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 20),
              Text(message.isEmpty ? 'Loading…' : message, style: const TextStyle(fontSize: 16)),
              const SizedBox(height: 6),
              Text('Large playlists can take a moment.',
                  style: TextStyle(fontSize: 12, color: NovaColors.of(context).dim)),
            ],
          ),
        ),
      );
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.message, required this.onRetry, required this.onSignOut});
  final String message;
  final VoidCallback onRetry, onSignOut;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off_rounded, size: 56),
                  const SizedBox(height: 16),
                  Text(message, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    alignment: WrapAlignment.center,
                    children: [
                      NovaButton(label: 'Retry', icon: Icons.refresh_rounded, filled: true, autofocus: true, onTap: onRetry),
                      NovaButton(label: 'Change login', icon: Icons.logout_rounded, onTap: onSignOut),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

// =============================================================================
//  PIN KEYPAD
// =============================================================================

class PinDialog extends StatefulWidget {
  const PinDialog({
    super.key,
    required this.title,
    this.subtitle,
    this.verify,
    this.errorText = 'Incorrect PIN. Try again.',
  });

  final String title;
  final String? subtitle;
  final String errorText;

  /// When provided, the dialog only closes with a PIN this callback accepts.
  final bool Function(String pin)? verify;

  @override
  State<PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<PinDialog> {
  String _pin = '';
  String? _error;

  void _digit(String d) {
    if (_pin.length >= 4) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length == 4) _submit();
  }

  void _back() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  void _submit() {
    final v = widget.verify;
    if (v != null && !v(_pin)) {
      setState(() {
        _pin = '';
        _error = widget.errorText;
      });
      return;
    }
    Navigator.of(context).pop(_pin);
  }

  @override
  Widget build(BuildContext context) {
    final c = NovaColors.of(context);

    Widget key(String label, {VoidCallback? onTap, IconData? icon, bool autofocus = false}) => Padding(
          padding: const EdgeInsets.all(4),
          child: SizedBox(
            width: 72,
            height: 52,
            child: Focusable(
              autofocus: autofocus,
              onTap: onTap ?? () => _digit(label),
              color: c.surfaceHi.withOpacity(0.5),
              child: Center(
                child: icon != null
                    ? Icon(icon, size: 22)
                    : Text(label, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        );

    return Focus(
      // Physical number keys on the remote work too.
      onKeyEvent: (node, e) {
        if (e is! KeyDownEvent) return KeyEventResult.ignored;
        final ch = e.character;
        if (ch != null && ch.length == 1 && '0123456789'.contains(ch)) {
          _digit(ch);
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.backspace) {
          _back();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Dialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: SizedBox(
            width: 270,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_rounded, size: 30),
                const SizedBox(height: 8),
                Text(widget.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                if (widget.subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(widget.subtitle!, style: TextStyle(color: c.dim, fontSize: 12)),
                  ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < 4; i++)
                      Container(
                        width: 16,
                        height: 16,
                        margin: const EdgeInsets.symmetric(horizontal: 6),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i < _pin.length ? c.accent : Colors.transparent,
                          border: Border.all(color: i < _pin.length ? c.accent : c.dim, width: 2),
                        ),
                      ),
                  ],
                ),
                SizedBox(
                  height: 24,
                  child: Center(
                    child: Text(_error ?? '', style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                  ),
                ),
                for (final row in const [
                  ['1', '2', '3'],
                  ['4', '5', '6'],
                  ['7', '8', '9'],
                ])
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [for (final d in row) key(d, autofocus: d == '5')],
                  ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    key('', icon: Icons.backspace_outlined, onTap: _back),
                    key('0'),
                    key('', icon: Icons.close_rounded, onTap: () => Navigator.of(context).pop()),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
//  LOGIN
// =============================================================================

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _server = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final server = XtreamApi.normalize(_server.text);
    final user = _user.text.trim();
    final pass = _pass.text;
    if (server.isEmpty || user.isEmpty || pass.isEmpty) {
      setState(() => _problem = 'Please fill in all three fields.');
      return;
    }
    if (Uri.tryParse(server)?.host.isEmpty ?? true) {
      setState(() => _problem = 'That server address does not look valid.');
      return;
    }
    final settings = context.read<SettingsProvider>();
    final store = context.read<DataStore>();
    final api = XtreamApi(server, user, pass);
    store.load(api); // flips the root into the loading state immediately
    await settings.saveCredentials(server: server, username: user, password: pass);
  }

  @override
  Widget build(BuildContext context) {
    final c = NovaColors.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.live_tv_rounded, size: 56, color: c.accent),
                  const SizedBox(height: 12),
                  const Text('Nova IPTV',
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text('Connect your Xtream Codes account',
                      textAlign: TextAlign.center, style: TextStyle(color: c.dim)),
                  const SizedBox(height: 28),
                  TvTextField(
                    controller: _server,
                    label: 'Server  (e.g. http://host:8080)',
                    icon: Icons.dns_rounded,
                    keyboardType: TextInputType.url,
                    autofocus: true,
                  ),
                  const SizedBox(height: 14),
                  TvTextField(controller: _user, label: 'Username', icon: Icons.person_rounded),
                  const SizedBox(height: 14),
                  TvTextField(
                    controller: _pass,
                    label: 'Password',
                    icon: Icons.lock_rounded,
                    obscure: true,
                    action: TextInputAction.done,
                    onSubmitted: (_) => _connect(),
                  ),
                  if (_problem != null) ...[
                    const SizedBox(height: 12),
                    Text(_problem!, style: const TextStyle(color: Colors.redAccent)),
                  ],
                  const SizedBox(height: 22),
                  Center(child: NovaButton(label: 'Connect', icon: Icons.login_rounded, filled: true, onTap: _connect)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
//  SHELL  (responsive layout + navigation)
// =============================================================================

const List<(IconData, String)> _destinations = [
  (Icons.home_rounded, 'Home'),
  (Icons.live_tv_rounded, 'Live TV'),
  (Icons.movie_rounded, 'Movies'),
  (Icons.video_library_rounded, 'Series'),
  (Icons.search_rounded, 'Search'),
  (Icons.settings_rounded, 'Settings'),
];

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _index = 0;
  int _shownFatal = 0;
  final FocusScopeNode _contentScope = FocusScopeNode(debugLabel: 'content');

  @override
  void dispose() {
    _contentScope.dispose();
    super.dispose();
  }

  void _select(int i) {
    setState(() => _index = i);
    // After choosing a destination, drop the cursor straight into its content.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _contentScope.requestFocus();
    });
  }

  Widget _screen(int i) => switch (i) {
        0 => const HomeScreen(),
        1 => const BrowseScreen(kind: MediaKind.live),
        2 => const BrowseScreen(kind: MediaKind.movie),
        3 => const BrowseScreen(kind: MediaKind.series),
        4 => const SearchScreen(),
        _ => const SettingsScreen(),
      };

  /// Smart Auto-Recovery gave up after 3 silent reconnects: tell the user.
  Future<void> _showFatal() async {
    final pb = context.read<PlaybackController>();
    final message = pb.fatalMessage ?? 'Playback was interrupted.';
    final c = NovaColors.of(context);
    final retry = await showNovaDialog<bool>(
      context,
      (ctx) => Dialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.wifi_off_rounded, size: 40),
                const SizedBox(height: 10),
                const Text('Connection lost', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Text(message, textAlign: TextAlign.center, style: TextStyle(color: c.dim)),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    NovaButton(
                      label: 'Try again',
                      icon: Icons.refresh_rounded,
                      filled: true,
                      autofocus: true,
                      onTap: () => Navigator.of(ctx).pop(true),
                    ),
                    NovaButton(label: 'Close', onTap: () => Navigator.of(ctx).pop(false)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (retry == true) {
      pb.retry();
    } else if (retry == false) {
      pb.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final landscape = size.width > size.height;
    final playing = context.select<PlaybackController, bool>((p) => p.current != null);
    final fatal = context.select<PlaybackController, int>((p) => p.fatalSerial);
    final syncing = context.select<DataStore, bool>((s) => s.syncing);

    if (fatal != _shownFatal) {
      _shownFatal = fatal;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showFatal();
      });
    }

    final content = FocusScope(
      node: _contentScope,
      child: FocusTraversalGroup(
        child: KeyedSubtree(key: ValueKey(_index), child: _screen(_index)),
      ),
    );

    Widget body;
    if (landscape) {
      final showPlayer = playing && _index != 5;
      final playerWidth = (size.width * 0.34).clamp(300.0, 480.0).toDouble();
      body = Row(
        children: [
          FocusTraversalGroup(
            child: _SideNav(
              selected: _index,
              extended: size.width >= 1000,
              syncing: syncing,
              onSelect: _select,
              onSync: () => syncNow(context),
            ),
          ),
          Expanded(child: content),
          if (showPlayer)
            SizedBox(
              width: playerWidth,
              child: const Padding(
                padding: EdgeInsets.fromLTRB(0, 16, 16, 16),
                child: Align(alignment: Alignment.topCenter, child: PlayerPanel()),
              ),
            ),
        ],
      );
    } else {
      body = Column(
        children: [
          if (playing)
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: PlayerPanel(),
            ),
          Expanded(child: content),
          FocusTraversalGroup(child: _BottomNav(selected: _index, onSelect: _select)),
        ],
      );
    }

    return PopScope(
      canPop: !playing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.read<PlaybackController>().stop();
      },
      child: Scaffold(body: SafeArea(child: body)),
    );
  }
}

class _SideNav extends StatelessWidget {
  const _SideNav({
    required this.selected,
    required this.extended,
    required this.syncing,
    required this.onSelect,
    required this.onSync,
  });
  final int selected;
  final bool extended, syncing;
  final ValueChanged<int> onSelect;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    final c = NovaColors.of(context);
    return Container(
      width: extended ? 220 : 84,
      color: c.surface,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Scrollable so short landscape phones never overflow.
          Expanded(
            child: ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 14, top: 4),
                  child: extended
                      ? Row(children: [
                          Icon(Icons.live_tv_rounded, color: c.accent),
                          const SizedBox(width: 10),
                          const Text('Nova IPTV', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                        ])
                      : Icon(Icons.live_tv_rounded, color: c.accent, size: 28),
                ),
                for (var i = 0; i < _destinations.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Focusable(
                      onTap: () => onSelect(i),
                      color: i == selected ? c.surfaceHi : null,
                      padding: EdgeInsets.symmetric(horizontal: extended ? 14 : 0, vertical: 12),
                      child: Row(
                        mainAxisAlignment: extended ? MainAxisAlignment.start : MainAxisAlignment.center,
                        children: [
                          Icon(_destinations[i].$1, color: i == selected ? c.accent : c.text),
                          if (extended) ...[
                            const SizedBox(width: 12),
                            Text(
                              _destinations[i].$2,
                              style: TextStyle(fontWeight: i == selected ? FontWeight.w700 : FontWeight.w500),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Live Data Provider Sync button
          Focusable(
            onTap: syncing ? null : onSync,
            padding: EdgeInsets.symmetric(horizontal: extended ? 14 : 0, vertical: 12),
            child: Row(
              mainAxisAlignment: extended ? MainAxisAlignment.start : MainAxisAlignment.center,
              children: [
                syncing
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.sync_rounded, color: c.text),
                if (extended) ...[
                  const SizedBox(width: 12),
                  Text(syncing ? 'Syncing…' : 'Sync playlist'),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.selected, required this.onSelect});
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = NovaColors.of(context);
    return Container(
      color: c.surface,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          for (var i = 0; i < _destinations.length; i++)
            Expanded(
              child: Focusable(
                onTap: () => onSelect(i),
                color: i == selected ? c.surfaceHi : null,
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_destinations[i].$1, size: 22, color: i == selected ? c.accent : c.text),
                    const SizedBox(height: 2),
                    Text(
                      _destinations[i].$2,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: i == selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// =============================================================================
//  PLAYER PANEL, SLEEP TIMER, FULLSCREEN OSD
// =============================================================================

class _BufferingOverlay extends StatelessWidget {
  const _BufferingOverlay({required this.player});
  final Player player;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: StreamBuilder<bool>(
          stream: player.stream.buffering,
          initialData: player.state.buffering,
          builder: (_, snap) => (snap.data ?? false)
              ? const Center(child: CircularProgressIndicator(strokeWidth: 3))
              : const SizedBox.shrink(),
        ),
      );
}

class _NoticePill extends StatelessWidget {
  const _NoticePill({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(20)),
            child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ),
      );
}

class _SleepDialog extends StatelessWidget {
  const _SleepDialog();

  @override
  Widget build(BuildContext context) {
    final c = NovaColors.of(context);
    final active = context.read<PlaybackController>().sleepAt != null;
    return Dialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.bedtime_rounded, size: 34),
              const SizedBox(height: 8),
              const Text('Sleep timer', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text('Stops playback and closes the app.', style: TextStyle(color: c.dim, fontSize: 12)),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  NovaButton(label: '15 min', autofocus: true, onTap: () => Navigator.of(context).pop(15)),
                  NovaButton(label: '30 min', onTap: () => Navigator.of(context).pop(30)),
                  NovaButton(label: '60 min', onTap: () => Navigator.of(context).pop(60)),
                  if (active)
                    NovaButton(label: 'Turn off', icon: Icons.timer_off_rounded, onTap: () => Navigator.of(context).pop(0)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SleepCountdown extends StatefulWidget {
  const _SleepCountdown({required this.at});
  final DateTime at;
  @override
  State<_SleepCountdown> createState() => _SleepCountdownState();
}

class _SleepCountdownState extends State<_SleepCountdown> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    // Coarse refresh (20 s): minutes are all we show, so no need to tick faster.
    _t = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final secs = widget.at.difference(DateTime.now()).inSeconds;
    final mins = math.max(0, (secs / 60).ceil());
    return Text('${mins}m', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700));
  }
}

/// HUD button: opens the 15 / 30 / 60 minute sleep timer chooser.
class SleepButton extends StatelessWidget {
  const SleepButton({super.key});

  @override
  Widget build(BuildContext context) {
    final at = context.select<PlaybackController, DateTime?>((p) => p.sleepAt);
    final c = NovaColors.of(context);
    return Focusable(
      radius: 10,
      padding: const EdgeInsets.all(6),
      onTap: () async {
        final pb = context.read<PlaybackController>();
        final choice = await showNovaDialog<int>(context, (_) => const _SleepDialog());
        if (choice == null) return;
        pb.setSleep(choice == 0 ? null : Duration(minutes: choice));
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bedtime_rounded, size: 22, color: at != null ? c.accent : null),
          if (at != null) ...[
            const SizedBox(width: 4),
            _SleepCountdown(at: at),
          ],
        ],
      ),
    );
  }
}

class PlayerPanel extends StatelessWidget {
  const PlayerPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final pb = context.watch<PlaybackController>();
    final c = NovaColors.of(context);
    final item = pb.current;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ColoredBox(
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Video(controller: pb.controller, controls: NoVideoControls, fill: Colors.black),
                  _BufferingOverlay(player: pb.player),
                  if (pb.notice != null) _NoticePill(text: pb.notice!),
                  if (pb.error != null)
                    Container(
                      color: Colors.black87,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.error_outline_rounded, color: Colors.white70),
                          const SizedBox(height: 6),
                          Text(pb.error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white, fontSize: 12)),
                          const SizedBox(height: 8),
                          NovaButton(label: 'Retry', icon: Icons.refresh_rounded, onTap: pb.retry),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                pb.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              ),
              const SizedBox(height: 4),
              Wrap(
                alignment: WrapAlignment.center,
                children: [
                  StreamBuilder<bool>(
                    stream: pb.player.stream.playing,
                    initialData: pb.player.state.playing,
                    builder: (_, snap) => IconBtn(
                      icon: (snap.data ?? false) ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      onTap: pb.togglePlay,
                    ),
                  ),
                  if (!pb.isLive) ...[
                    IconBtn(icon: Icons.replay_10_rounded, onTap: () => pb.seekBy(const Duration(seconds: -10))),
                    IconBtn(icon: Icons.forward_10_rounded, onTap: () => pb.seekBy(const Duration(seconds: 10))),
                  ],
                  if (item != null) FavButton(item: item),
                  const SleepButton(),
                  IconBtn(
                    icon: Icons.fullscreen_rounded,
                    onTap: () => Navigator.of(context).push(novaRoute<void>(context, (_) => const FullscreenPlayer())),
                  ),
                  IconBtn(icon: Icons.stop_rounded, onTap: pb.stop),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Fullscreen player with an auto-hiding OSD / HUD.
///   OSD hidden : Select/Up/Down = show HUD, Left/Right = seek 10 s (VOD)
///   OSD visible: normal D-pad navigation between the HUD buttons
class FullscreenPlayer extends StatefulWidget {
  const FullscreenPlayer({super.key});
  @override
  State<FullscreenPlayer> createState() => _FullscreenPlayerState();
}

class _FullscreenPlayerState extends State<FullscreenPlayer> {
  bool _osd = false;
  Timer? _hideTimer;
  late final FocusNode _root = FocusNode(debugLabel: 'player-root', onKeyEvent: _onKey);
  final FocusScopeNode _osdScope = FocusScopeNode(debugLabel: 'osd');

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _root.dispose();
    _osdScope.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _armHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 6), _hideOsd);
  }

  void _showOsd() {
    if (!_osd) setState(() => _osd = true);
    _armHide();
  }

  void _hideOsd() {
    _hideTimer?.cancel();
    if (_osd && mounted) setState(() => _osd = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _root.requestFocus();
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final pb = context.read<PlaybackController>();
    final k = e.logicalKey;

    if (_osd) {
      _armHide(); // any activity keeps the HUD alive; let focus traversal run
      return KeyEventResult.ignored;
    }

    if (k == LogicalKeyboardKey.mediaPlayPause ||
        k == LogicalKeyboardKey.mediaPlay ||
        k == LogicalKeyboardKey.mediaPause) {
      pb.togglePlay();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.mediaFastForward) {
      pb.isLive ? _showOsd() : pb.seekBy(const Duration(seconds: 10));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.mediaRewind) {
      pb.isLive ? _showOsd() : pb.seekBy(const Duration(seconds: -10));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.space ||
        k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.arrowDown) {
      _showOsd();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final pb = context.watch<PlaybackController>();
    final item = pb.current;

    return PopScope(
      canPop: !_osd,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _hideOsd(); // first Back closes the HUD, second leaves fullscreen
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _root,
          autofocus: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _osd ? _hideOsd() : _showOsd(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Video(controller: pb.controller, controls: NoVideoControls, fill: Colors.black),
                _BufferingOverlay(player: pb.player),
                if (pb.notice != null) _NoticePill(text: pb.notice!),
                if (pb.error != null)
                  Center(child: Text(pb.error!, style: const TextStyle(color: Colors.white70))),
                if (_osd)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: FocusScope(
                      node: _osdScope,
                      child: FocusTraversalGroup(
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(24, 36, 24, 16),
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Colors.transparent, Color(0xE6000000)],
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                            ),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                pb.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                              ),
                              if (!pb.isLive) ...[
                                const SizedBox(height: 8),
                                StreamBuilder<Duration>(
                                  stream: pb.player.stream.position,
                                  initialData: pb.player.state.position,
                                  builder: (_, snap) {
                                    final total = pb.player.state.duration.inMilliseconds;
                                    final pos = (snap.data ?? Duration.zero).inMilliseconds;
                                    return LinearProgressIndicator(
                                      value: total > 0 ? (pos / total).clamp(0.0, 1.0) : 0.0,
                                      minHeight: 4,
                                    );
                                  },
                                ),
                              ],
                              const SizedBox(height: 10),
                              Theme(
                                data: Theme.of(context).copyWith(
                                  iconTheme: const IconThemeData(color: Colors.white),
                                ),
                                child: DefaultTextStyle.merge(
                                  style: const TextStyle(color: Colors.white),
                                  child: Wrap(
                                    alignment: WrapAlignment.center,
                                    spacing: 6,
                                    children: [
                                      IconBtn(icon: Icons.arrow_back_rounded, onTap: () => Navigator.of(context).maybePop()),
                                      StreamBuilder<bool>(
                                        stream: pb.player.stream.playing,
                                        initialData: pb.player.state.playing,
                                        builder: (_, snap) => IconBtn(
                                          autofocus: true,
                                          icon: (snap.data ?? false) ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                          onTap: pb.togglePlay,
                                        ),
                                      ),
                                      if (!pb.isLive) ...[
                                        IconBtn(icon: Icons.replay_10_rounded, onTap: () => pb.seekBy(const Duration(seconds: -10))),
                                        IconBtn(icon: Icons.forward_10_rounded, onTap: () => pb.seekBy(const Duration(seconds: 10))),
                                      ],
                                      if (item != null) FavButton(item: item),
                                      const SleepButton(),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
//  HOME
// =============================================================================

class _RowSpec {
  const _RowSpec(this.anchor, this.title, this.items);
  final HomeAnchor? anchor;
  final String title;
  final List<MediaItem> items;
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final store = context.watch<DataStore>();
    final c = NovaColors.of(context);

    bool visible(MediaItem i) => !settings.isKeyLocked(i.lockKey);

    final recent = settings.showRecentRow
        ? _decodeItems(settings.recentPayloads).where(visible).toList()
        : <MediaItem>[];
    final favorites = _decodeItems(settings.favoritePayloads).where(visible).toList();

    final specs = <_RowSpec>[
      if (settings.showRecentRow)
        _RowSpec(
          recent.isNotEmpty ? HomeAnchor.recent : null,
          recent.isNotEmpty ? 'Recently Watched' : 'Live Channels',
          recent.isNotEmpty ? recent : store.live.take(20).toList(),
        ),
      _RowSpec(HomeAnchor.favorites, 'My Favorites', favorites),
      _RowSpec(HomeAnchor.added, 'Recently Added', store.recentlyAdded.where(visible).toList()),
      _RowSpec(null, 'Trending Movies', store.trending.where(visible).toList()),
    ];

    // The pinned row (if any, and non-empty) goes above EVERYTHING, hero included.
    final pinned = specs.where((s) => s.anchor != null && s.anchor == settings.homeAnchor && s.items.isNotEmpty).toList();
    final rest = specs.where((s) => !pinned.contains(s) && s.items.isNotEmpty).toList();
    final hero = settings.showHero && store.hero != null && visible(store.hero!) ? store.hero : null;

    final sections = <Object>[...pinned, if (hero != null) hero, ...rest];

    if (sections.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Nothing to show yet.\nTurn Home sections back on in Settings.',
            textAlign: TextAlign.center,
            style: TextStyle(color: c.dim),
          ),
        ),
      );
    }

    return ListView.builder(
      cacheExtent: 400,
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: sections.length,
      itemBuilder: (context, i) {
        final s = sections[i];
        final first = i == 0; // boot focus goes to the first thing on screen
        if (s is MediaItem) return _HeroBanner(item: s, autofocus: first);

        final spec = s as _RowSpec;
        return Carousel(
          title: spec.title,
          count: spec.items.length,
          height: 195 + 80,
          itemBuilder: (context, idx) {
            final it = spec.items[idx];
            final size = MediaCard.sizeFor(it.kind);
            return Align(
              alignment: Alignment.topCenter,
              child: MediaCard(
                item: it,
                width: size.width + MediaCard.chrome,
                imageHeight: size.height,
                autofocus: first && idx == 0,
              ),
            );
          },
        );
      },
    );
  }
}

class _HeroBanner extends StatelessWidget {
  const _HeroBanner({required this.item, required this.autofocus});
  final MediaItem item;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final c = NovaColors.of(context);
    final showRatings = UiScope.of(context).ratings;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: LinearGradient(
            colors: [c.accent.withOpacity(0.35), c.surface],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        padding: const EdgeInsets.all(20),
        child: LayoutBuilder(builder: (context, box) {
          final showPoster = box.maxWidth > 520;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('FEATURED',
                        style: TextStyle(
                            color: c.accent, fontSize: 12, letterSpacing: 2, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Text(item.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Row(children: [
                      if (showRatings && item.rating > 0) ...[
                        const Icon(Icons.star_rounded, color: kGold, size: 18),
                        const SizedBox(width: 4),
                        Text(item.rating.toStringAsFixed(1), style: const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(width: 12),
                      ],
                      Text(switch (item.kind) {
                        MediaKind.live => 'Live',
                        MediaKind.movie => 'Movie',
                        MediaKind.series => 'Series',
                      }, style: TextStyle(color: c.dim)),
                    ]),
                    const SizedBox(height: 16),
                    NovaButton(
                      label: item.kind == MediaKind.series ? 'View episodes' : 'Play now',
                      icon: Icons.play_arrow_rounded,
                      filled: true,
                      autofocus: autofocus,
                      onTap: () => openItem(context, item),
                    ),
                  ],
                ),
              ),
              if (showPoster) ...[
                const SizedBox(width: 20),
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: NetImage(url: item.icon, width: 133, height: 200),
                ),
              ],
            ],
          );
        }),
      ),
    );
  }
}

// =============================================================================
//  BROWSE (Live TV / Movies / Series)
// =============================================================================

class BrowseScreen extends StatefulWidget {
  const BrowseScreen({super.key, required this.kind});
  final MediaKind kind;
  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  String _cat = '*';

  String _lockKey(CategoryEntry cat) => '${widget.kind.name}:${cat.id}';

  Future<void> _pick(CategoryEntry cat) async {
    if (cat.id != '*' && cat.id != '#fav') {
      if (!await ensureUnlocked(context, _lockKey(cat))) return;
    }
    if (mounted) setState(() => _cat = cat.id);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<DataStore>();
    final settings = context.watch<SettingsProvider>();
    final c = NovaColors.of(context);

    final favItems = _decodeItems(settings.favoritePayloads).where((i) => i.kind == widget.kind).toList();
    final cats = <CategoryEntry>[
      CategoryEntry('#fav', '★ Favorites', favItems.length),
      ...store.categoriesOf(widget.kind),
    ];

    // Locked categories are hidden from the "All" list until unlocked.
    var items = _cat == '#fav' ? favItems : store.itemsFor(widget.kind, _cat);
    if (_cat == '*' && settings.hasLocks) {
      items = items.where((i) => !settings.isKeyLocked(i.lockKey)).toList();
    }

    final wide = MediaQuery.sizeOf(context).width >= 900;
    final list = _ItemsView(key: ValueKey('${widget.kind.name}-$_cat-${store.revision}'), kind: widget.kind, items: items);

    Widget label(CategoryEntry cat, bool selected, {required bool withCount}) {
      final locked = cat.id != '*' && cat.id != '#fav' && settings.isConfiguredLocked(_lockKey(cat));
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              withCount ? '${cat.name}  (${cat.count})' : cat.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                color: selected ? c.accent : c.text,
              ),
            ),
          ),
          if (locked) ...[
            const SizedBox(width: 6),
            Icon(settings.isKeyLocked(_lockKey(cat)) ? Icons.lock_rounded : Icons.lock_open_rounded, size: 14, color: c.dim),
          ],
        ],
      );
    }

    if (wide) {
      return Row(
        children: [
          SizedBox(
            width: 230,
            child: FocusTraversalGroup(
              child: ListView.builder(
                cacheExtent: 100,
                padding: const EdgeInsets.fromLTRB(12, 12, 6, 12),
                itemExtent: 52,
                itemCount: cats.length,
                itemBuilder: (_, i) {
                  final cat = cats[i];
                  final selected = cat.id == _cat;
                  return Focusable(
                    onTap: () => _pick(cat),
                    color: selected ? c.surface : null,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Align(alignment: Alignment.centerLeft, child: label(cat, selected, withCount: true)),
                  );
                },
              ),
            ),
          ),
          Expanded(child: list),
        ],
      );
    }

    return Column(
      children: [
        SizedBox(
          height: 56,
          child: FocusTraversalGroup(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              cacheExtent: 100,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              itemCount: cats.length,
              itemBuilder: (_, i) {
                final cat = cats[i];
                final selected = cat.id == _cat;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Focusable(
                    onTap: () => _pick(cat),
                    color: selected ? c.surface : null,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Center(child: label(cat, selected, withCount: false)),
                  ),
                );
              },
            ),
          ),
        ),
        Expanded(child: list),
      ],
    );
  }
}

class _ItemsView extends StatelessWidget {
  const _ItemsView({super.key, required this.kind, required this.items});
  final MediaKind kind;
  final List<MediaItem> items;

  @override
  Widget build(BuildContext context) {
    final c = NovaColors.of(context);

    if (items.isEmpty) {
      return Center(child: Text('Nothing here yet.', style: TextStyle(color: c.dim)));
    }

    if (kind == MediaKind.live) {
      final playingUid = context.select<PlaybackController, String?>((p) => p.current?.uid);
      return ListView.builder(
        cacheExtent: 120,
        padding: const EdgeInsets.all(12),
        itemExtent: 68,
        itemCount: items.length,
        itemBuilder: (context, i) {
          final it = items[i];
          final isPlaying = it.uid == playingUid;
          // Two sibling focus targets: channel (Select = play) and star (Right, then Select).
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Focusable(
                  autofocus: i == 0,
                  onTap: () => openItem(context, it),
                  onAlt: () => toggleFavorite(context, it),
                  color: isPlaying ? c.surface : null,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: ColoredBox(
                          color: c.surface,
                          child: NetImage(url: it.icon, width: 48, height: 48, fit: BoxFit.contain),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          it.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: isPlaying ? FontWeight.w800 : FontWeight.w500),
                        ),
                      ),
                      if (isPlaying) Icon(Icons.graphic_eq_rounded, color: c.accent),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 4),
              FavButton(item: it),
            ],
          );
        },
      );
    }

    // Movies / Series: poster grid with a fixed 2:3 cell so decode size matches
    // the drawn size exactly.
    return LayoutBuilder(builder: (context, box) {
      const spacing = 10.0;
      const pad = 12.0;
      final avail = box.maxWidth - pad * 2;
      final count = math.max(2, ((avail + spacing) / (140 + spacing)).floor());
      final cell = (avail - spacing * (count - 1)) / count;
      final imageHeight = (cell - MediaCard.chrome) * 1.5;

      return GridView.builder(
        cacheExtent: 150,
        padding: const EdgeInsets.all(pad),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: count,
          mainAxisSpacing: spacing,
          crossAxisSpacing: spacing,
          mainAxisExtent: imageHeight + MediaCard.chrome + 62,
        ),
        itemCount: items.length,
        itemBuilder: (context, i) => MediaCard(
          item: items[i],
          width: cell,
          imageHeight: imageHeight,
          autofocus: i == 0,
        ),
      );
    });
  }
}

// =============================================================================
//  SERIES DETAIL
// =============================================================================

class SeriesScreen extends StatefulWidget {
  const SeriesScreen({super.key, required this.item});
  final MediaItem item;
  @override
  State<SeriesScreen> createState() => _SeriesScreenState();
}

class _SeriesScreenState extends State<SeriesScreen> {
  SeriesDetail? _detail;
  String? _error;
  bool _loading = true;
  int _season = 1;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    final api = context.read<DataStore>().api;
    if (api == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await api.seriesInfo(widget.item.id);
      if (!mounted) return;
      final seasons = d.seasons.keys.toList()..sort();
      setState(() {
        _detail = d;
        _season = seasons.isNotEmpty ? seasons.first : 1;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load episodes.';
        _loading = false;
      });
    }
  }

  void _play(Episode ep) {
    final api = context.read<DataStore>().api;
    if (api == null) return;
    context.read<PlaybackController>().playEpisode(widget.item, ep, api);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = NovaColors.of(context);
    final d = _detail;

    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null || d == null) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error ?? 'No data.'),
            const SizedBox(height: 12),
            NovaButton(label: 'Retry', icon: Icons.refresh_rounded, autofocus: true, onTap: _fetch),
          ],
        ),
      );
    } else if (d.seasons.isEmpty) {
      body = Center(child: Text('No episodes available.', style: TextStyle(color: c.dim)));
    } else {
      final seasons = d.seasons.keys.toList()..sort();
      final episodes = d.seasons[_season] ?? const <Episode>[];
      body = Column(
        children: [
          SizedBox(
            height: 56,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              cacheExtent: 100,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              itemCount: seasons.length,
              itemBuilder: (_, i) {
                final s = seasons[i];
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: NovaButton(
                    label: 'Season $s',
                    filled: s == _season,
                    onTap: () => setState(() => _season = s),
                  ),
                );
              },
            ),
          ),
          Expanded(
            child: ListView.builder(
              key: ValueKey(_season),
              cacheExtent: 120,
              padding: const EdgeInsets.all(12),
              itemExtent: 60,
              itemCount: episodes.length,
              itemBuilder: (_, i) {
                final ep = episodes[i];
                return Focusable(
                  autofocus: i == 0,
                  onTap: () => _play(ep),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 36,
                        child: Text('${ep.number}', style: TextStyle(color: c.dim, fontWeight: FontWeight.w700)),
                      ),
                      Expanded(child: Text(ep.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                      const Icon(Icons.play_arrow_rounded),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      );
    }

    return Scaffold(
      body: SafeArea(
        child: FocusTraversalGroup(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Column(
                      children: [
                        IconBtn(icon: Icons.arrow_back_rounded, onTap: () => Navigator.of(context).maybePop()),
                        FavButton(item: widget.item),
                      ],
                    ),
                    const SizedBox(width: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: NetImage(url: widget.item.icon, width: 80, height: 120),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.item.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                          if (UiScope.of(context).ratings && widget.item.rating > 0) ...[
                            const SizedBox(height: 4),
                            _RatingPill(rating: widget.item.rating),
                          ],
                          if ((d?.plot ?? '').isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(d!.plot,
                                maxLines: 4,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: c.dim, fontSize: 13)),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
//  MASTER SEARCH
// =============================================================================

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  String _query = '';
  List<MediaItem> _live = const [], _movies = const [], _series = const [];

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _run() {
    _debounce?.cancel();
    final q = _ctrl.text.trim();
    final store = context.read<DataStore>();
    final settings = context.read<SettingsProvider>();
    List<MediaItem> find(MediaKind k) =>
        store.search(k, q).where((i) => !settings.isKeyLocked(i.lockKey)).toList();
    setState(() {
      _query = q;
      _live = find(MediaKind.live);
      _movies = find(MediaKind.movie);
      _series = find(MediaKind.series);
    });
  }

  // 500 ms debounce: no parsing loop per keystroke.
  void _onChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      if (mounted) _run();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = NovaColors.of(context);
    final rows = <(String, MediaKind, List<MediaItem>)>[
      ('Live TV Results', MediaKind.live, _live),
      ('Movie Results', MediaKind.movie, _movies),
      ('Series Results', MediaKind.series, _series),
    ];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TvTextField(
                  controller: _ctrl,
                  label: 'Search channels, movies and series',
                  icon: Icons.search_rounded,
                  action: TextInputAction.search,
                  autofocus: true,
                  onChanged: _onChanged,
                  onSubmitted: (_) => _run(),
                  onDown: _run, // pressing Down jumps from the keyboard into the result rows
                ),
              ),
              const SizedBox(width: 8),
              IconBtn(icon: Icons.search_rounded, onTap: _run),
            ],
          ),
        ),
        Expanded(
          child: _query.isEmpty
              ? Center(child: Text('Type a title, then press Search.', style: TextStyle(color: c.dim)))
              : ListView.builder(
                  cacheExtent: 300,
                  itemCount: rows.length,
                  itemBuilder: (context, i) {
                    final (title, kind, items) = rows[i];
                    final s = MediaCard.sizeFor(kind);
                    if (items.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                        child: Text('$title — no matches', style: TextStyle(color: c.dim, fontSize: 15)),
                      );
                    }
                    return Carousel(
                      title: '$title  (${items.length})',
                      count: items.length,
                      height: s.height.round() + 80,
                      itemBuilder: (context, idx) => Align(
                        alignment: Alignment.topCenter,
                        child: MediaCard(
                          item: items[idx],
                          width: s.width + MediaCard.chrome,
                          imageHeight: s.height,
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// =============================================================================
//  SETTINGS
// =============================================================================

Future<void> _changePin(BuildContext context, SettingsProvider s) async {
  if (s.hasPin) {
    final ok = await showNovaDialog<String>(
      context,
      (_) => PinDialog(title: 'Current PIN', verify: s.checkPin),
    );
    if (ok == null || !context.mounted) return;
  }
  final first = await showNovaDialog<String>(context, (_) => const PinDialog(title: 'Choose a 4-digit PIN'));
  if (first == null || !context.mounted) return;
  final second = await showNovaDialog<String>(
    context,
    (_) => PinDialog(title: 'Confirm PIN', verify: (p) => p == first, errorText: 'PINs do not match.'),
  );
  if (second == null) return;
  await s.setPin(first);
}

Future<void> _removePin(BuildContext context, SettingsProvider s) async {
  final ok = await showNovaDialog<String>(
    context,
    (_) => PinDialog(title: 'Enter PIN to remove', verify: s.checkPin),
  );
  if (ok != null) await s.clearPin();
}

Future<void> _openLockedCategories(BuildContext context, SettingsProvider s) async {
  final ok = await showNovaDialog<String>(
    context,
    (_) => PinDialog(title: 'Enter PIN', verify: s.checkPin),
  );
  if (ok == null || !context.mounted) return;
  await Navigator.of(context).push(novaRoute<void>(context, (_) => const LockedCategoriesScreen()));
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Widget _section(String title, List<Widget> children, {String? hint}) => Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            if (hint != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Opacity(opacity: 0.65, child: Text(hint, style: const TextStyle(fontSize: 12))),
              ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      );

  Widget _wrap(List<Widget> children) => Wrap(spacing: 10, runSpacing: 10, children: children);

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsProvider>();
    final syncing = context.select<DataStore, bool>((d) => d.syncing);
    final c = NovaColors.of(context);

    final blocks = <Widget>[
      const Padding(
        padding: EdgeInsets.only(bottom: 18),
        child: Text('Settings', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
      ),

      // ------------------------------------------------------- Appearance
      _section('Appearance', [
        _wrap([
          NovaButton(
            label: 'Dark',
            icon: Icons.dark_mode_rounded,
            filled: s.isDark,
            autofocus: true,
            onTap: () => s.setDarkMode(true),
          ),
          NovaButton(
            label: 'Light',
            icon: Icons.light_mode_rounded,
            filled: !s.isDark,
            onTap: () => s.setDarkMode(false),
          ),
        ]),
      ]),

      // ------------------------------------------------------- Typography
      _section('Text', [
        const Text('Size', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        _wrap([
          for (final p in FontProfile.values)
            NovaButton(
              label: p.label,
              icon: Icons.text_fields_rounded,
              filled: s.fontProfile == p,
              onTap: () => s.setFontProfile(p),
            ),
        ]),
        const SizedBox(height: 14),
        const Text('Font family', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: FocusRing(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<AppFont>(
                  value: s.appFont,
                  isExpanded: true,
                  dropdownColor: c.surface,
                  focusColor: Colors.transparent,
                  icon: const Icon(Icons.arrow_drop_down_rounded),
                  items: [
                    for (final f in AppFont.values)
                      DropdownMenuItem<AppFont>(
                        value: f,
                        child: Text(
                          f.label,
                          style: TextStyle(
                            fontFamily: f.family,
                            fontWeight: f.bold ? FontWeight.w800 : FontWeight.w500,
                            letterSpacing: f.spacing,
                          ),
                        ),
                      ),
                  ],
                  onChanged: (f) {
                    if (f != null) s.setAppFont(f);
                  },
                ),
              ),
            ),
          ),
        ),
      ]),

      // ------------------------------------------------------- Animations
      _section(
        'Interface Animations',
        [
          SettingSwitch(
            title: 'Animations Engine',
            subtitle: s.animationsEnabled ? 'On' : 'Off — every animation and transition is disabled',
            value: s.animationsEnabled,
            onChanged: s.setAnimationsEnabled,
          ),
          const SizedBox(height: 8),
          _wrap([
            for (final p in AnimProfile.values)
              NovaButton(
                label: p.label,
                icon: switch (p) {
                  AnimProfile.none => Icons.block_rounded,
                  AnimProfile.light => Icons.blur_linear_rounded,
                  AnimProfile.medium => Icons.auto_awesome_rounded,
                },
                filled: s.animProfile == p,
                onTap: () => s.setAnimProfile(p),
              ),
          ]),
        ],
        hint: 'No Animations = fastest. Light = 150 ms fades. Medium = 300 ms spring effects.',
      ),

      // ------------------------------------------------------- Home screen
      _section('Home Screen', [
        SettingSwitch(
          title: 'Featured Hero Banner',
          value: s.showHero,
          onChanged: s.setShowHero,
        ),
        SettingSwitch(
          title: 'Recently Watched Row',
          value: s.showRecentRow,
          onChanged: s.setShowRecentRow,
        ),
        SettingSwitch(
          title: 'Movie Ratings Overlays',
          subtitle: 'Gold star + score on posters',
          value: s.showRatings,
          onChanged: s.setShowRatings,
        ),
        const SizedBox(height: 10),
        const Text('Pin a row to the very top', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        for (final a in HomeAnchor.values)
          SettingSwitch(
            title: a.label,
            value: s.homeAnchor == a,
            onChanged: (on) => s.setHomeAnchor(on ? a : null),
          ),
      ]),

      // ------------------------------------------------- Parental controls
      _section(
        'Parental Controls',
        [
          Text(
            s.hasPin
                ? 'PIN is set · ${s.lockedCount} locked categor${s.lockedCount == 1 ? 'y' : 'ies'}'
                : 'No PIN set',
            style: TextStyle(color: c.dim),
          ),
          const SizedBox(height: 10),
          _wrap([
            NovaButton(
              label: s.hasPin ? 'Change PIN' : 'Set PIN',
              icon: Icons.pin_rounded,
              onTap: () => _changePin(context, s),
            ),
            if (s.hasPin) ...[
              NovaButton(
                label: 'Locked categories',
                icon: Icons.lock_rounded,
                onTap: () => _openLockedCategories(context, s),
              ),
              NovaButton(label: 'Re-lock now', icon: Icons.lock_clock_rounded, onTap: s.relockAll),
              NovaButton(label: 'Remove PIN', icon: Icons.lock_open_rounded, onTap: () => _removePin(context, s)),
            ],
          ]),
        ],
        hint: 'Locked categories ask for the PIN before they open or play.',
      ),

      // --------------------------------------------------------- Library
      _section('Library', [
        _wrap([
          NovaButton(
            label: syncing ? 'Syncing…' : 'Sync playlist now',
            icon: Icons.sync_rounded,
            filled: true,
            onTap: syncing ? null : () => syncNow(context),
          ),
          NovaButton(label: 'Clear recently watched', icon: Icons.history_toggle_off_rounded, onTap: s.clearRecents),
          NovaButton(
            label: 'Clear favorites (${s.favoriteCount})',
            icon: Icons.star_border_rounded,
            onTap: s.clearFavorites,
          ),
        ]),
      ], hint: 'Sync refreshes channels and VOD in the background — your settings stay untouched.'),

      // --------------------------------------------------------- Account
      _section('Account', [
        Text('${s.username} @ ${s.serverUrl}', style: TextStyle(color: c.dim)),
        const SizedBox(height: 10),
        _wrap([NovaButton(label: 'Sign out', icon: Icons.logout_rounded, onTap: () => signOut(context))]),
      ]),
    ];

    return ListView.builder(
      cacheExtent: 600,
      padding: const EdgeInsets.all(20),
      itemCount: blocks.length,
      itemBuilder: (_, i) => blocks[i],
    );
  }
}

class LockedCategoriesScreen extends StatelessWidget {
  const LockedCategoriesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<DataStore>();
    final s = context.watch<SettingsProvider>();

    // Flatten to one virtualised list: headers + switches.
    final rows = <Object>[];
    for (final k in MediaKind.values) {
      final cats = store.categoriesOf(k).where((c) => c.id != '*').toList();
      if (cats.isEmpty) continue;
      rows.add(switch (k) {
        MediaKind.live => 'Live TV',
        MediaKind.movie => 'Movies',
        MediaKind.series => 'Series',
      });
      for (final cat in cats) {
        rows.add((k, cat));
      }
    }

    return Scaffold(
      body: SafeArea(
        child: FocusTraversalGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
                child: Row(
                  children: [
                    IconBtn(icon: Icons.arrow_back_rounded, onTap: () => Navigator.of(context).maybePop()),
                    const SizedBox(width: 8),
                    const Text('Locked categories', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  cacheExtent: 200,
                  padding: const EdgeInsets.all(16),
                  itemCount: rows.length,
                  itemBuilder: (_, i) {
                    final r = rows[i];
                    if (r is String) {
                      return Padding(
                        padding: const EdgeInsets.only(top: 14, bottom: 6),
                        child: Text(r, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                      );
                    }
                    final (kind, cat) = r as (MediaKind, CategoryEntry);
                    final key = '${kind.name}:${cat.id}';
                    return SettingSwitch(
                      autofocus: i == 1,
                      title: '${cat.name}  (${cat.count})',
                      value: s.isConfiguredLocked(key),
                      onChanged: (v) => s.setLocked(key, v),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
