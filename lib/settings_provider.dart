import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// =============================================================================
//  ENUMS
// =============================================================================

/// Global text-size profiles (applied once at the app root via TextScaler).
enum FontProfile {
  small(0.85, 'Small'),
  medium(1.0, 'Medium'),
  large(1.2, 'Large');

  const FontProfile(this.scale, this.label);
  final double scale;
  final String label;
}

/// Interface animation profiles.
///  none   -> zero animations, zero transitions (cheapest possible rendering)
///  light  -> linear 150 ms opacity fades only
///  medium -> 300 ms spring-style scale + easing on focused panels
enum AnimProfile {
  none('No Animations'),
  light('Light'),
  medium('Medium');

  const AnimProfile(this.label);
  final String label;
}

/// Font-family presets. They use fonts that ship with the OS, so there are no
/// font assets to bundle and no extra RAM spent on custom glyph caches.
enum AppFont {
  system('System Default', null, false, 0.0),
  cinematic('Modern Cinematic', 'sans-serif-light', false, 0.6),
  highContrast('High Contrast Bold', 'sans-serif-medium', true, 0.3);

  const AppFont(this.label, this.family, this.bold, this.spacing);
  final String label;
  final String? family;
  final bool bold;
  final double spacing;
}

/// Which Home row can be pinned above everything else.
enum HomeAnchor {
  favorites('Favorites Shelf'),
  recent('Recently Watched History'),
  added('Recently Added Content');

  const HomeAnchor(this.label);
  final String label;
}

T _enumAt<T>(List<T> values, int? index, T fallback) {
  if (index == null || index < 0 || index >= values.length) return fallback;
  return values[index];
}

// =============================================================================
//  SHELF  (ordered key/payload list that persists: recents + favorites)
// =============================================================================

class _Shelf {
  _Shelf(this._prefs, this._name, this._max) {
    final k = _prefs.getStringList('${_name}_keys') ?? const <String>[];
    final p = _prefs.getStringList('${_name}_payloads') ?? const <String>[];
    if (k.length == p.length) {
      keys.addAll(k);
      payloads.addAll(p);
      _set.addAll(k);
    }
  }

  final SharedPreferences _prefs;
  final String _name;
  final int _max;
  final List<String> keys = <String>[];
  final List<String> payloads = <String>[];
  final Set<String> _set = <String>{};

  bool has(String key) => _set.contains(key);

  void push(String key, String payload) {
    _remove(key);
    keys.insert(0, key);
    payloads.insert(0, payload);
    _set.add(key);
    while (keys.length > _max) {
      _set.remove(keys.removeLast());
      payloads.removeLast();
    }
    _save();
  }

  /// Returns true when the key was added, false when it was removed.
  bool toggle(String key, String payload) {
    if (has(key)) {
      _remove(key);
      _save();
      return false;
    }
    push(key, payload);
    return true;
  }

  void clear() {
    keys.clear();
    payloads.clear();
    _set.clear();
    _save();
  }

  void _remove(String key) {
    final i = keys.indexOf(key);
    if (i >= 0) {
      keys.removeAt(i);
      payloads.removeAt(i);
      _set.remove(key);
    }
  }

  void _save() {
    _prefs.setStringList('${_name}_keys', List<String>.of(keys));
    _prefs.setStringList('${_name}_payloads', List<String>.of(payloads));
  }
}

// =============================================================================
//  SETTINGS PROVIDER
// =============================================================================

class SettingsProvider extends ChangeNotifier {
  SettingsProvider._(this._prefs)
      : _recents = _Shelf(_prefs, 'recent', 20),
        _favorites = _Shelf(_prefs, 'favorites', 300) {
    _themeMode = (_prefs.getBool(_kDark) ?? true) ? ThemeMode.dark : ThemeMode.light;
    _font = _enumAt(FontProfile.values, _prefs.getInt(_kFont), FontProfile.medium);
    _appFont = _enumAt(AppFont.values, _prefs.getInt(_kAppFont), AppFont.system);
    _animProfile = _enumAt(AnimProfile.values, _prefs.getInt(_kAnim), AnimProfile.light);
    _animEnabled = _prefs.getBool(_kAnimEnabled) ?? true;
    _showHero = _prefs.getBool(_kShowHero) ?? true;
    _showRecent = _prefs.getBool(_kShowRecent) ?? true;
    _showRatings = _prefs.getBool(_kShowRatings) ?? true;
    final anchor = _prefs.getInt(_kAnchor) ?? -1;
    _anchor = (anchor >= 0 && anchor < HomeAnchor.values.length) ? HomeAnchor.values[anchor] : null;

    _server = _prefs.getString(_kServer) ?? '';
    _user = _prefs.getString(_kUser) ?? '';
    _pass = _prefs.getString(_kPass) ?? '';

    _pinHash = _prefs.getString(_kPin) ?? '';
    _locked.addAll(_prefs.getStringList(_kLocked) ?? const <String>[]);
  }

  static const _kDark = 'dark_mode';
  static const _kFont = 'font_profile';
  static const _kAppFont = 'app_font';
  static const _kAnim = 'anim_profile';
  static const _kAnimEnabled = 'anim_enabled';
  static const _kShowHero = 'show_hero';
  static const _kShowRecent = 'show_recent';
  static const _kShowRatings = 'show_ratings';
  static const _kAnchor = 'home_anchor';
  static const _kServer = 'server';
  static const _kUser = 'username';
  static const _kPass = 'password';
  static const _kPin = 'pin_hash';
  static const _kLocked = 'locked_categories';

  final SharedPreferences _prefs;
  final _Shelf _recents;
  final _Shelf _favorites;

  late ThemeMode _themeMode;
  late FontProfile _font;
  late AppFont _appFont;
  late AnimProfile _animProfile;
  late bool _animEnabled, _showHero, _showRecent, _showRatings;
  HomeAnchor? _anchor;
  String _server = '', _user = '', _pass = '';
  String _pinHash = '';
  final Set<String> _locked = <String>{};
  final Set<String> _sessionUnlocked = <String>{};

  static Future<SettingsProvider> load() async {
    final prefs = await SharedPreferences.getInstance();
    return SettingsProvider._(prefs);
  }

  // ---------------------------------------------------------------- Theme

  ThemeMode get themeMode => _themeMode;
  bool get isDark => _themeMode == ThemeMode.dark;

  Future<void> setDarkMode(bool dark) async {
    final next = dark ? ThemeMode.dark : ThemeMode.light;
    if (next == _themeMode) return;
    _themeMode = next;
    notifyListeners();
    await _prefs.setBool(_kDark, dark);
  }

  // ------------------------------------------------------------- Typography

  FontProfile get fontProfile => _font;
  AppFont get appFont => _appFont;

  Future<void> setFontProfile(FontProfile profile) async {
    if (profile == _font) return;
    _font = profile;
    notifyListeners();
    await _prefs.setInt(_kFont, profile.index);
  }

  Future<void> setAppFont(AppFont font) async {
    if (font == _appFont) return;
    _appFont = font;
    notifyListeners();
    await _prefs.setInt(_kAppFont, font.index);
  }

  // ------------------------------------------------------------- Animations

  bool get animationsEnabled => _animEnabled;
  AnimProfile get animProfile => _animProfile;

  /// What the UI really uses: the master switch beats the chosen profile.
  AnimProfile get effectiveAnim => _animEnabled ? _animProfile : AnimProfile.none;

  Future<void> setAnimationsEnabled(bool v) async {
    if (v == _animEnabled) return;
    _animEnabled = v;
    notifyListeners();
    await _prefs.setBool(_kAnimEnabled, v);
  }

  Future<void> setAnimProfile(AnimProfile p) async {
    if (p == _animProfile) return;
    _animProfile = p;
    notifyListeners();
    await _prefs.setInt(_kAnim, p.index);
  }

  // ------------------------------------------------------------ Home toggles

  bool get showHero => _showHero;
  bool get showRecentRow => _showRecent;
  bool get showRatings => _showRatings;
  HomeAnchor? get homeAnchor => _anchor;

  Future<void> setShowHero(bool v) async {
    _showHero = v;
    notifyListeners();
    await _prefs.setBool(_kShowHero, v);
  }

  Future<void> setShowRecentRow(bool v) async {
    _showRecent = v;
    notifyListeners();
    await _prefs.setBool(_kShowRecent, v);
  }

  Future<void> setShowRatings(bool v) async {
    _showRatings = v;
    notifyListeners();
    await _prefs.setBool(_kShowRatings, v);
  }

  /// Pass null to go back to the default row order.
  Future<void> setHomeAnchor(HomeAnchor? anchor) async {
    _anchor = anchor;
    notifyListeners();
    await _prefs.setInt(_kAnchor, anchor?.index ?? -1);
  }

  // --------------------------------------------------------- Credentials
  // NOTE: for a store release, move the password to flutter_secure_storage.

  String get serverUrl => _server;
  String get username => _user;
  String get password => _pass;
  bool get hasCredentials => _server.isNotEmpty && _user.isNotEmpty && _pass.isNotEmpty;

  Future<void> saveCredentials({
    required String server,
    required String username,
    required String password,
  }) async {
    _server = server;
    _user = username;
    _pass = password;
    notifyListeners();
    await _prefs.setString(_kServer, server);
    await _prefs.setString(_kUser, username);
    await _prefs.setString(_kPass, password);
  }

  Future<void> clearCredentials() async {
    _server = '';
    _user = '';
    _pass = '';
    notifyListeners();
    await _prefs.remove(_kServer);
    await _prefs.remove(_kUser);
    await _prefs.remove(_kPass);
  }

  // ------------------------------------------------------------- Recents

  List<String> get recentPayloads => _recents.payloads;

  void pushRecent(String key, String payload) {
    _recents.push(key, payload);
    notifyListeners();
  }

  void clearRecents() {
    _recents.clear();
    notifyListeners();
  }

  // ----------------------------------------------------------- Favorites

  List<String> get favoritePayloads => _favorites.payloads;
  int get favoriteCount => _favorites.keys.length;
  bool isFavorite(String key) => _favorites.has(key);

  /// Returns true when the item is now a favorite.
  bool toggleFavorite(String key, String payload) {
    final added = _favorites.toggle(key, payload);
    notifyListeners();
    return added;
  }

  void clearFavorites() {
    _favorites.clear();
    notifyListeners();
  }

  // ---------------------------------------------------- Parental controls

  bool get hasPin => _pinHash.isNotEmpty;
  bool get hasLocks => hasPin && _locked.isNotEmpty;
  int get lockedCount => _locked.length;

  // Tiny salted FNV-1a. A 4-digit PIN is a speed bump for kids, not a vault.
  String _hash(String pin) {
    var h = 0x811C9DC5;
    for (final u in 'nova-iptv|$pin'.codeUnits) {
      h ^= u;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16);
  }

  bool checkPin(String pin) => hasPin && _hash(pin) == _pinHash;

  Future<void> setPin(String pin) async {
    _pinHash = _hash(pin);
    _sessionUnlocked.clear();
    notifyListeners();
    await _prefs.setString(_kPin, _pinHash);
  }

  Future<void> clearPin() async {
    _pinHash = '';
    _locked.clear();
    _sessionUnlocked.clear();
    notifyListeners();
    await _prefs.remove(_kPin);
    await _prefs.remove(_kLocked);
  }

  /// Category key format: '<kind>:<categoryId>', e.g. 'movie:42'.
  bool isConfiguredLocked(String key) => hasPin && _locked.contains(key);

  /// Locked AND not yet unlocked during this app session.
  bool isKeyLocked(String key) => isConfiguredLocked(key) && !_sessionUnlocked.contains(key);

  Future<void> setLocked(String key, bool locked) async {
    if (locked) {
      _locked.add(key);
    } else {
      _locked.remove(key);
    }
    _sessionUnlocked.remove(key);
    notifyListeners();
    await _prefs.setStringList(_kLocked, _locked.toList());
  }

  void unlock(String key) {
    _sessionUnlocked.add(key);
    notifyListeners();
  }

  void relockAll() {
    _sessionUnlocked.clear();
    notifyListeners();
  }
}
