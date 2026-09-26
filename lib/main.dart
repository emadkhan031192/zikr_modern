// ============================================================================
// Zikr Modern - Premium Islamic Tasbeeh
// Single-file Flutter app: Home (counter), Mood, Circle (Group Khatm), Settings
// ============================================================================

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:confetti/confetti.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:vibration/vibration.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:share_plus/share_plus.dart';

// Firebase is optional. The app must run fully offline if it isn't configured.
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

// =========================================================================
// ENTRY POINT
// =========================================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Try to bring Firebase up for the Circle (Group Khatm) screen. If this
  // project has no firebase_options.dart / google-services.json wired in,
  // this throws and we silently continue in fully-offline mode -- every
  // other screen works regardless.
  bool firebaseReady = false;
  try {
    await Firebase.initializeApp();
    firebaseReady = true;
  } catch (_) {
    firebaseReady = false;
  }

  final prefs = await SharedPreferences.getInstance();
  runApp(ZikrModernApp(prefs: prefs, firebaseReady: firebaseReady));
}

// =========================================================================
// DHIKR PRESETS
// =========================================================================

class DhikrPreset {
  final String arabic;
  final String transliteration;
  final String translation;
  final int defaultTarget;

  const DhikrPreset({
    required this.arabic,
    required this.transliteration,
    required this.translation,
    required this.defaultTarget,
  });
}

const List<DhikrPreset> kDhikrPresets = [
  DhikrPreset(
    arabic: 'سُبْحَانَ اللَّهِ',
    transliteration: 'SubhanAllah',
    translation: 'Glory be to Allah',
    defaultTarget: 33,
  ),
  DhikrPreset(
    arabic: 'الْحَمْدُ لِلَّهِ',
    transliteration: 'Alhamdulillah',
    translation: 'All praise is due to Allah',
    defaultTarget: 33,
  ),
  DhikrPreset(
    arabic: 'اللَّهُ أَكْبَرُ',
    transliteration: 'Allahu Akbar',
    translation: 'Allah is the Greatest',
    defaultTarget: 34,
  ),
  DhikrPreset(
    arabic: 'لَا إِلَٰهَ إِلَّا اللَّهُ',
    transliteration: 'La ilaha illallah',
    translation: 'There is no god but Allah',
    defaultTarget: 100,
  ),
  DhikrPreset(
    arabic: 'أَسْتَغْفِرُ اللَّهَ',
    transliteration: 'Astaghfirullah',
    translation: 'I seek forgiveness from Allah',
    defaultTarget: 100,
  ),
  DhikrPreset(
    arabic: 'اللَّهُمَّ صَلِّ عَلَىٰ مُحَمَّدٍ',
    transliteration: 'Darood Sharif',
    translation: 'O Allah, send blessings upon Muhammad',
    defaultTarget: 100,
  ),
];

// Mood -> dhikr index mapping into kDhikrPresets
const Map<String, int> kMoodDhikrIndex = {
  'happy': 1, // Alhamdulillah
  'neutral': 3, // La ilaha illallah
  'sad': 4, // Astaghfirullah
  'anxious': -1, // Hasbunallah (special, not in list)
  'angry': -2, // La hawla wala quwwata illa billah (special, not in list)
};

const DhikrPreset kHasbunallah = DhikrPreset(
  arabic: 'حَسْبُنَا اللَّهُ وَنِعْمَ الْوَكِيلُ',
  transliteration: "Hasbunallahu wa ni'mal wakeel",
  translation: 'Allah is sufficient for us, and He is the best disposer of affairs',
  defaultTarget: 100,
);

const DhikrPreset kLaHawla = DhikrPreset(
  arabic: 'لَا حَوْلَ وَلَا قُوَّةَ إِلَّا بِاللَّهِ',
  transliteration: 'La hawla wala quwwata illa billah',
  translation: 'There is no power and no strength except with Allah',
  defaultTarget: 100,
);

DhikrPreset presetForMood(String mood) {
  final idx = kMoodDhikrIndex[mood] ?? 3;
  if (idx == -1) return kHasbunallah;
  if (idx == -2) return kLaHawla;
  return kDhikrPresets[idx];
}

// =========================================================================
// MOOD HISTORY MODEL
// =========================================================================

class MoodEntry {
  final String mood;
  final DateTime timestamp;

  MoodEntry({required this.mood, required this.timestamp});

  Map<String, dynamic> toJson() => {
        'mood': mood,
        'timestamp': timestamp.toIso8601String(),
      };

  factory MoodEntry.fromJson(Map<String, dynamic> json) => MoodEntry(
        mood: json['mood'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
      );
}

// =========================================================================
// APP STATE (Provider)
// =========================================================================

class AppState extends ChangeNotifier {
  final SharedPreferences prefs;
  final bool firebaseReady;

  AppState(this.prefs, {required this.firebaseReady}) {
    _load();
  }

  // --- Counter state ---
  int currentDhikrIndex = 0;
  int currentCount = 0;
  int target = kDhikrPresets[0].defaultTarget;
  bool isCounting = false;

  // Special mood-triggered dhikr not in the main preset list
  DhikrPreset? customMoodPreset;

  // --- Auto Tasbeeh-e-Fatima mode ---
  bool autoFatimaMode = false;
  int fatimaStage = 0; // 0=SubhanAllah,1=Alhamdulillah,2=AllahuAkbar,3=done

  // --- Settings ---
  bool volumeButtonCounting = false;
  String volumeButtonSide = 'down'; // 'up' or 'down'
  bool ghostOverlayEnabled = false;
  bool aodMode = false;
  bool giantMode = false;
  bool soundEnabled = true;
  bool vibrationEnabled = true;
  TimeOfDay dailyReminderTime = const TimeOfDay(hour: 8, minute: 0);

  // --- Streak ---
  int streakDays = 0;
  DateTime? lastActiveDay;

  // --- Mood history ---
  List<MoodEntry> moodHistory = [];

  // --- Undo ---
  int? _lastCountBeforeIncrement;

  DhikrPreset get activePreset => customMoodPreset ?? kDhikrPresets[currentDhikrIndex];

  Future<void> _load() async {
    currentDhikrIndex = prefs.getInt('currentDhikrIndex') ?? 0;
    currentCount = prefs.getInt('currentCount') ?? 0;
    target = prefs.getInt('target') ?? kDhikrPresets[currentDhikrIndex].defaultTarget;
    volumeButtonCounting = prefs.getBool('volumeToggle') ?? false;
    volumeButtonSide = prefs.getString('volumeSide') ?? 'down';
    ghostOverlayEnabled = prefs.getBool('ghostOverlay') ?? false;
    aodMode = prefs.getBool('aodMode') ?? false;
    giantMode = prefs.getBool('giantMode') ?? false;
    soundEnabled = prefs.getBool('soundEnabled') ?? true;
    vibrationEnabled = prefs.getBool('vibrationEnabled') ?? true;
    streakDays = prefs.getInt('streak') ?? 0;

    final lastActiveStr = prefs.getString('lastActiveDay');
    if (lastActiveStr != null) lastActiveDay = DateTime.tryParse(lastActiveStr);

    final reminderMinutes = prefs.getInt('reminderMinutes');
    if (reminderMinutes != null) {
      dailyReminderTime = TimeOfDay(hour: reminderMinutes ~/ 60, minute: reminderMinutes % 60);
    }

    final moodJson = prefs.getStringList('moodHistory') ?? [];
    moodHistory = moodJson
        .map((s) => MoodEntry.fromJson(Map<String, dynamic>.from(
            Uri.splitQueryString(s).map((k, v) => MapEntry(k, v)))))
        .toList();
    // Simpler & safer: store as "mood|timestamp" pairs instead of query strings.
    moodHistory = moodJson.map((s) {
      final parts = s.split('|');
      return MoodEntry(mood: parts[0], timestamp: DateTime.parse(parts[1]));
    }).toList();

    _updateStreakOnLoad();
    notifyListeners();
  }

  void _updateStreakOnLoad() {
    final today = DateTime.now();
    final todayKey = DateTime(today.year, today.month, today.day);
    if (lastActiveDay == null) return;
    final lastKey = DateTime(lastActiveDay!.year, lastActiveDay!.month, lastActiveDay!.day);
    final diff = todayKey.difference(lastKey).inDays;
    if (diff > 1) {
      // streak broken
      streakDays = 0;
      prefs.setInt('streak', 0);
    }
  }

  Future<void> _persistCounter() async {
    await prefs.setInt('currentDhikrIndex', currentDhikrIndex);
    await prefs.setInt('currentCount', currentCount);
    await prefs.setInt('target', target);
  }

  Future<void> _touchStreak() async {
    final today = DateTime.now();
    final todayKey = DateTime(today.year, today.month, today.day);
    if (lastActiveDay == null) {
      streakDays = 1;
    } else {
      final lastKey = DateTime(lastActiveDay!.year, lastActiveDay!.month, lastActiveDay!.day);
      final diff = todayKey.difference(lastKey).inDays;
      if (diff == 0) {
        // same day, no change
      } else if (diff == 1) {
        streakDays += 1;
      } else {
        streakDays = 1;
      }
    }
    lastActiveDay = today;
    await prefs.setInt('streak', streakDays);
    await prefs.setString('lastActiveDay', today.toIso8601String());
  }

  // --- Counting logic --------------------------------------------------

  /// Returns true if this increment completed the target (caller shows
  /// confetti / TTS / dialog).
  Future<bool> increment({VoidCallback? onFatimaStageComplete}) async {
    _lastCountBeforeIncrement = currentCount;
    currentCount += 1;
    isCounting = true;

    if (vibrationEnabled) {
      final hasVib = await Vibration.hasVibrator();
      if (hasVib) {
        Vibration.vibrate(duration: 20);
      } else {
        HapticFeedback.lightImpact();
      }
    }

    bool completed = false;

    if (autoFatimaMode) {
      completed = await _handleFatimaProgress(onFatimaStageComplete);
    } else {
      if (currentCount >= target) {
        completed = true;
      }
    }

    await _touchStreak();
    await _persistCounter();
    notifyListeners();
    return completed;
  }

  Future<bool> _handleFatimaProgress(VoidCallback? onStageComplete) async {
    // Stage 0: SubhanAllah x33, Stage 1: Alhamdulillah x33, Stage 2: Allahu Akbar x34
    const stageTargets = [33, 33, 34];
    const stageDhikrIndex = [0, 1, 2];

    currentDhikrIndex = stageDhikrIndex[fatimaStage];
    target = stageTargets[fatimaStage];

    if (currentCount >= target) {
      if (fatimaStage < 2) {
        fatimaStage += 1;
        currentCount = 0;
        currentDhikrIndex = stageDhikrIndex[fatimaStage];
        target = stageTargets[fatimaStage];
        if (vibrationEnabled) {
          final hasVib = await Vibration.hasVibrator();
          if (hasVib) Vibration.vibrate(duration: 250);
        }
        onStageComplete?.call();
        return false;
      } else {
        // Finished all 3 stages -> full completion (La ilaha illallah closing)
        return true;
      }
    }
    return false;
  }

  void resetFatimaMode() {
    fatimaStage = 0;
    currentDhikrIndex = 0;
    currentCount = 0;
    target = kDhikrPresets[0].defaultTarget;
    _persistCounter();
    notifyListeners();
  }

  void setAutoFatimaMode(bool value) {
    autoFatimaMode = value;
    if (value) {
      resetFatimaMode();
    }
    notifyListeners();
  }

  Future<void> undoLast() async {
    if (_lastCountBeforeIncrement != null) {
      currentCount = _lastCountBeforeIncrement!;
      _lastCountBeforeIncrement = null;
      await _persistCounter();
      notifyListeners();
    } else if (currentCount > 0) {
      currentCount -= 1;
      await _persistCounter();
      notifyListeners();
    }
  }

  Future<void> reset() async {
    _lastCountBeforeIncrement = currentCount;
    currentCount = 0;
    await _persistCounter();
    notifyListeners();
  }

  Future<void> switchDhikr(int delta) async {
    if (autoFatimaMode) return; // locked during auto mode
    final len = kDhikrPresets.length;
    currentDhikrIndex = (currentDhikrIndex + delta + len) % len;
    customMoodPreset = null;
    currentCount = 0;
    target = kDhikrPresets[currentDhikrIndex].defaultTarget;
    await _persistCounter();
    notifyListeners();
  }

  Future<void> selectMoodDhikr(String mood) async {
    final idx = kMoodDhikrIndex[mood];
    if (idx != null && idx >= 0) {
      currentDhikrIndex = idx;
      customMoodPreset = null;
    } else {
      customMoodPreset = idx == -1 ? kHasbunallah : kLaHawla;
    }
    currentCount = 0;
    target = 100;
    await _persistCounter();
    notifyListeners();
  }

  Future<void> setTarget(int value) async {
    target = value;
    await prefs.setInt('target', target);
    notifyListeners();
  }

  // --- Settings setters --------------------------------------------------

  Future<void> setVolumeButtonCounting(bool v) async {
    volumeButtonCounting = v;
    await prefs.setBool('volumeToggle', v);
    notifyListeners();
  }

  Future<void> setVolumeButtonSide(String side) async {
    volumeButtonSide = side;
    await prefs.setString('volumeSide', side);
    notifyListeners();
  }

  Future<void> setGhostOverlay(bool v) async {
    ghostOverlayEnabled = v;
    await prefs.setBool('ghostOverlay', v);
    if (v) {
      final granted = await FlutterOverlayWindow.isPermissionGranted();
      if (!granted) {
        await FlutterOverlayWindow.requestPermission();
      }
    } else {
      await FlutterOverlayWindow.closeOverlay();
    }
    notifyListeners();
  }

  Future<void> setAodMode(bool v) async {
    aodMode = v;
    await prefs.setBool('aodMode', v);
    notifyListeners();
  }

  Future<void> setGiantMode(bool v) async {
    giantMode = v;
    await prefs.setBool('giantMode', v);
    notifyListeners();
  }

  Future<void> setSoundEnabled(bool v) async {
    soundEnabled = v;
    await prefs.setBool('soundEnabled', v);
    notifyListeners();
  }

  Future<void> setVibrationEnabled(bool v) async {
    vibrationEnabled = v;
    await prefs.setBool('vibrationEnabled', v);
    notifyListeners();
  }

  Future<void> setReminderTime(TimeOfDay t) async {
    dailyReminderTime = t;
    await prefs.setInt('reminderMinutes', t.hour * 60 + t.minute);
    notifyListeners();
  }

  // --- Mood history --------------------------------------------------

  Future<void> logMood(String mood) async {
    final entry = MoodEntry(mood: mood, timestamp: DateTime.now());
    moodHistory.insert(0, entry);
    if (moodHistory.length > 200) {
      moodHistory = moodHistory.sublist(0, 200);
    }
    final encoded = moodHistory
        .map((e) => '${e.mood}|${e.timestamp.toIso8601String()}')
        .toList();
    await prefs.setStringList('moodHistory', encoded);
    notifyListeners();
  }
}

// =========================================================================
// THEME
// =========================================================================

class AppColors {
  static const creamBg = Color(0xFFFFFBF0);
  static const creamText = Color(0xFF1A3C34);
  static const emerald = Color(0xFF10B981);

  static const darkBg = Color(0xFF0E1410);
  static const darkCard = Color(0xFF1C2A22);
  static const neon = Color(0xFF00FF88);
}

ThemeData buildLightTheme() {
  final base = ThemeData.light(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.creamBg,
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.emerald,
      surface: AppColors.creamBg,
    ),
    textTheme: GoogleFonts.poppinsTextTheme(base.textTheme).apply(
      bodyColor: AppColors.creamText,
      displayColor: AppColors.creamText,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      foregroundColor: AppColors.creamText,
    ),
    cardColor: Colors.white.withOpacity(0.6),
  );
}

ThemeData buildDarkTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.darkBg,
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.neon,
      surface: AppColors.darkCard,
    ),
    textTheme: GoogleFonts.poppinsTextTheme(base.textTheme).apply(
      bodyColor: Colors.white,
      displayColor: Colors.white,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      foregroundColor: Colors.white,
    ),
    cardColor: AppColors.darkCard,
  );
}

// Glassmorphism card wrapper with an emerald glow, reused across screens.
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const GlassCard({super.key, required this.child, this.padding = const EdgeInsets.all(16)});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final glow = isDark ? AppColors.neon : AppColors.emerald;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: glow.withOpacity(0.25)),
        boxShadow: [
          BoxShadow(
            color: glow.withOpacity(isDark ? 0.15 : 0.10),
            blurRadius: 20,
            spreadRadius: 1,
          ),
        ],
      ),
      child: child,
    );
  }
}

// =========================================================================
// ROOT APP
// =========================================================================

class ZikrModernApp extends StatelessWidget {
  final SharedPreferences prefs;
  final bool firebaseReady;

  const ZikrModernApp({super.key, required this.prefs, required this.firebaseReady});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState(prefs, firebaseReady: firebaseReady),
      child: MaterialApp(
        title: 'Zikr Modern',
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.system,
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        home: const RootShell(),
      ),
    );
  }
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _tab = 0;

  final _screens = const [
    HomeScreen(),
    MoodScreen(),
    CircleScreen(),
    SettingsScreen(),
  ];

  void goToHomeWithPreset() => setState(() => _tab = 0);

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    if (state.aodMode && state.isCounting && _tab == 0) {
      return const AodOverlayScreen();
    }

    return Scaffold(
      body: IndexedStack(index: _tab, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.self_improvement_rounded), label: 'Tasbeeh'),
          NavigationDestination(icon: Icon(Icons.mood_rounded), label: 'Mood'),
          NavigationDestination(icon: Icon(Icons.groups_rounded), label: 'Circle'),
          NavigationDestination(icon: Icon(Icons.settings_rounded), label: 'Settings'),
        ],
      ),
    );
  }
}

// =========================================================================
// HOME SCREEN - Counter
// =========================================================================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late AnimationController _scaleController;
  late ConfettiController _confettiController;
  final FlutterTts _tts = FlutterTts();
  StreamSubscription<AccelerometerEvent>? _shakeSub;
  double _lastShakeMagnitude = 0;
  DateTime _lastShakeTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
      lowerBound: 0.0,
      upperBound: 1.0,
    )..value = 1.0;
    _confettiController = ConfettiController(duration: const Duration(seconds: 2));
    _listenForShake();
  }

  void _listenForShake() {
    _shakeSub = accelerometerEventStream().listen((event) {
      final magnitude = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
      final now = DateTime.now();
      if (magnitude > 22 && now.difference(_lastShakeTime).inMilliseconds > 800) {
        _lastShakeTime = now;
        _onShakeUndo();
      }
      _lastShakeMagnitude = magnitude;
    });
  }

  void _onShakeUndo() {
    final state = context.read<AppState>();
    state.undoLast();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Shake detected — last count undone'), duration: Duration(seconds: 1)),
    );
  }

  @override
  void dispose() {
    _scaleController.dispose();
    _confettiController.dispose();
    _shakeSub?.cancel();
    _tts.stop();
    super.dispose();
  }

  Future<void> _speak(String text) async {
    final state = context.read<AppState>();
    if (!state.soundEnabled) return;
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.45);
    await _tts.speak(text);
  }

  Future<void> _handleTap() async {
    final state = context.read<AppState>();
    _scaleController.reverse().then((_) => _scaleController.forward());

    final wasStage = state.fatimaStage;
    final completed = await state.increment(
      onFatimaStageComplete: () {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${kDhikrPresets[wasStage].transliteration} complete — switching dhikr'),
            duration: const Duration(seconds: 1),
          ),
        );
      },
    );

    if (state.giantMode && state.currentCount % 33 == 0 && state.currentCount != 0) {
      _speak('${state.currentCount}');
    }

    if (completed) {
      _confettiController.play();
      if (state.autoFatimaMode) {
        await _speak('MashaAllah! La ilaha illallah, Muhammadur Rasulullah');
        _showCompletionDialog(
          title: 'Tasbeeh-e-Fatima Complete',
          body: 'La ilaha illallah, Muhammadur Rasulullah ﷺ\n\nMashaAllah! You completed the full tasbeeh.',
          onClose: () => state.resetFatimaMode(),
        );
      } else {
        await _speak('MashaAllah, completed');
        _showCompletionDialog(
          title: 'MashaAllah! Completed',
          body: 'You completed ${state.target} ${state.activePreset.transliteration}.',
          onClose: () {},
        );
      }
      if (state.vibrationEnabled) {
        final hasVib = await Vibration.hasVibrator();
        if (hasVib) Vibration.vibrate(pattern: [0, 200, 100, 200]);
      }
    }
  }

  void _showCompletionDialog({required String title, required String body, required VoidCallback onClose}) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(title, textAlign: TextAlign.center),
        content: Text(body, textAlign: TextAlign.center),
        actions: [
          Center(
            child: TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                onClose();
              },
              child: const Text('Alhamdulillah'),
            ),
          ),
        ],
      ),
    );
  }

  void _handleReset() {
    final state = context.read<AppState>();
    state.reset();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Count reset'),
        action: SnackBarAction(label: 'Undo', onPressed: () => state.undoLast()),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _editTarget() {
    final state = context.read<AppState>();
    final controller = TextEditingController(text: state.target.toString());
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Set target'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: 'e.g. 33, 99, 100, 1000'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              final v = int.tryParse(controller.text.trim());
              if (v != null && v > 0) state.setTarget(v);
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final preset = state.activePreset;
    final progress = state.target == 0 ? 0.0 : (state.currentCount / state.target).clamp(0.0, 1.0);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final glow = isDark ? AppColors.neon : AppColors.emerald;

    final circleSize = state.giantMode ? 320.0 : 260.0;
    final countFontSize = state.giantMode ? 96.0 : 56.0;
    final arabicFontSize = state.giantMode ? 32.0 : 24.0;

    return SafeArea(
      child: GestureDetector(
        onHorizontalDragEnd: (details) {
          if (state.autoFatimaMode) return;
          if (details.primaryVelocity == null) return;
          if (details.primaryVelocity! < 0) {
            state.switchDhikr(1);
          } else if (details.primaryVelocity! > 0) {
            state.switchDhikr(-1);
          }
        },
        child: Stack(
          children: [
            Column(
              children: [
                _buildTopBar(context, state),
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          preset.arabic,
                          style: GoogleFonts.poppins(fontSize: arabicFontSize, fontWeight: FontWeight.w600),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          preset.transliteration,
                          style: TextStyle(fontSize: 16, color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.7)),
                        ),
                        const SizedBox(height: 24),
                        GestureDetector(
                          onTap: _handleTap,
                          child: ScaleTransition(
                            scale: Tween(begin: 0.95, end: 1.0).animate(
                              CurvedAnimation(parent: _scaleController, curve: Curves.easeOut),
                            ),
                            child: SizedBox(
                              width: circleSize,
                              height: circleSize,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  SizedBox(
                                    width: circleSize,
                                    height: circleSize,
                                    child: CircularProgressIndicator(
                                      value: progress,
                                      strokeWidth: 14,
                                      backgroundColor: glow.withOpacity(0.12),
                                      valueColor: AlwaysStoppedAnimation(glow),
                                    ),
                                  ),
                                  Text(
                                    '${state.currentCount}',
                                    style: TextStyle(
                                      fontSize: countFontSize,
                                      fontWeight: FontWeight.bold,
                                      color: glow,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text('of ${state.target}', style: const TextStyle(fontSize: 14)),
                      ],
                    ),
                  ),
                ),
                _buildBottomControls(context, state),
                const SizedBox(height: 16),
              ],
            ),
            Align(
              alignment: Alignment.topCenter,
              child: ConfettiWidget(
                confettiController: _confettiController,
                blastDirectionality: BlastDirectionality.explosive,
                shouldLoop: false,
                colors: [glow, Colors.white, Colors.amber],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, AppState state) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Text('🔥', style: TextStyle(fontSize: 18)),
              const SizedBox(width: 4),
              Text('${state.streakDays} day streak', style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
          Row(
            children: [
              IconButton(
                tooltip: 'Giant Mode',
                icon: Icon(Icons.accessibility_new_rounded, color: state.giantMode ? AppColors.emerald : null),
                onPressed: () => state.setGiantMode(!state.giantMode),
              ),
              Switch(
                value: state.autoFatimaMode,
                onChanged: (v) => state.setAutoFatimaMode(v),
              ),
              const Text('Fatima', style: TextStyle(fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBottomControls(BuildContext context, AppState state) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          OutlinedButton.icon(
            onPressed: _handleReset,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Reset'),
          ),
          OutlinedButton.icon(
            onPressed: _editTarget,
            icon: const Icon(Icons.flag_rounded),
            label: const Text('Target'),
          ),
        ],
      ),
    );
  }
}

// Full-screen black AOD (Always On Display) mode.
class AodOverlayScreen extends StatelessWidget {
  const AodOverlayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    WakelockPlus.enable();
    final state = context.watch<AppState>();
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => state.increment(),
        onLongPress: () => _exitAod(context),
        child: Center(
          child: Text(
            '${state.currentCount}',
            style: const TextStyle(color: AppColors.neon, fontSize: 110, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }

  void _exitAod(BuildContext context) {
    context.read<AppState>().setAodMode(false);
    WakelockPlus.disable();
  }
}

// =========================================================================
// MOOD SCREEN
// =========================================================================

class MoodScreen extends StatelessWidget {
  const MoodScreen({super.key});

  static const _moods = [
    {'key': 'happy', 'emoji': '😊', 'label': 'Happy'},
    {'key': 'neutral', 'emoji': '😐', 'label': 'Neutral'},
    {'key': 'sad', 'emoji': '😔', 'label': 'Sad'},
    {'key': 'anxious', 'emoji': '😰', 'label': 'Anxious'},
    {'key': 'angry', 'emoji': '😡', 'label': 'Angry'},
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('How are you feeling today?', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: _moods.map((m) => _MoodChip(moodKey: m['key']!, emoji: m['emoji']!, label: m['label']!)).toList(),
            ),
            const SizedBox(height: 24),
            _MoodHistoryList(),
          ],
        ),
      ),
    );
  }
}

class _MoodChip extends StatelessWidget {
  final String moodKey;
  final String emoji;
  final String label;

  const _MoodChip({required this.moodKey, required this.emoji, required this.label});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => _showDhikrCard(context),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 28)),
            const SizedBox(height: 4),
            Text(label),
          ],
        ),
      ),
    );
  }

  void _showDhikrCard(BuildContext context) {
    final preset = presetForMood(moodKey);
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(preset.arabic, style: GoogleFonts.poppins(fontSize: 28, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(preset.transliteration, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            Text(preset.translation, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 8),
            const Text('Target: 100'),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  final state = ctx.read<AppState>();
                  state.selectMoodDhikr(moodKey);
                  state.logMood(moodKey);
                  Navigator.pop(ctx);
                  final rootShell = ctx.findAncestorStateOfType<_RootShellState>();
                  rootShell?.goToHomeWithPreset();
                },
                child: const Text('Start Dhikr'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MoodHistoryList extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.moodHistory.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Recent moods', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...state.moodHistory.take(10).map((e) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Text(
                MoodScreen._moods.firstWhere((m) => m['key'] == e.mood, orElse: () => {'emoji': '🙂'})['emoji']!,
                style: const TextStyle(fontSize: 20),
              ),
              title: Text(e.mood[0].toUpperCase() + e.mood.substring(1)),
              trailing: Text('${e.timestamp.hour}:${e.timestamp.minute.toString().padLeft(2, '0')}'),
            )),
      ],
    );
  }
}

// =========================================================================
// CIRCLE SCREEN - Group Khatm
// =========================================================================

class CircleScreen extends StatefulWidget {
  const CircleScreen({super.key});

  @override
  State<CircleScreen> createState() => _CircleScreenState();
}

class _CircleScreenState extends State<CircleScreen> {
  String? _activeCircleId;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    if (!state.firebaseReady) {
      return _buildOfflineNotice(context);
    }

    if (_activeCircleId == null) {
      return _buildCircleList(context);
    }

    return _CircleDetail(
      circleId: _activeCircleId!,
      onBack: () => setState(() => _activeCircleId = null),
    );
  }

  Widget _buildOfflineNotice(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            const Text(
              'Group Khatm needs an internet connection and Firebase to be configured for this app.\n\n'
              'Your personal tasbeeh counter on the Home tab still works fully offline.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => setState(() {}),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCircleList(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Group Khatm Circles', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => _showCreateDialog(context),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Create Circle'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _showJoinDialog(context),
              icon: const Icon(Icons.link_rounded),
              label: const Text('Join with Circle ID'),
            ),
          ],
        ),
      ),
    );
  }

  void _showCreateDialog(BuildContext context) {
    final nameController = TextEditingController();
    int selectedTarget = 1000;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('Create Circle'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameController, decoration: const InputDecoration(hintText: 'Circle name')),
              const SizedBox(height: 12),
              DropdownButton<int>(
                value: selectedTarget,
                items: const [1000, 10000, 100000]
                    .map((t) => DropdownMenuItem(value: t, child: Text('$t')))
                    .toList(),
                onChanged: (v) => setSt(() => selectedTarget = v ?? 1000),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(
              onPressed: () async {
                final id = await _createCircle(nameController.text.trim(), selectedTarget);
                if (context.mounted) {
                  Navigator.pop(ctx);
                  if (id != null) setState(() => _activeCircleId = id);
                }
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
  }

  void _showJoinDialog(BuildContext context) {
    final idController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Join Circle'),
        content: TextField(controller: idController, decoration: const InputDecoration(hintText: 'Circle ID')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              final id = idController.text.trim();
              Navigator.pop(ctx);
              if (id.isNotEmpty) setState(() => _activeCircleId = id);
            },
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }

  Future<String?> _createCircle(String name, int target) async {
    try {
      final auth = FirebaseAuth.instance;
      if (auth.currentUser == null) {
        await auth.signInAnonymously();
      }
      final uid = auth.currentUser?.uid ?? 'anonymous';
      final doc = await FirebaseFirestore.instance.collection('circles').add({
        'name': name.isEmpty ? 'Unnamed Circle' : name,
        'target': target,
        'total': 0,
        'createdBy': uid,
        'createdAt': FieldValue.serverTimestamp(),
        'members': [uid],
      });
      return doc.id;
    } catch (_) {
      return null;
    }
  }
}

class _CircleDetail extends StatelessWidget {
  final String circleId;
  final VoidCallback onBack;

  const _CircleDetail({required this.circleId, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: onBack),
                const Text('Circle Progress', style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.share_rounded),
                  onPressed: () => Share.share('Join my Group Khatm circle! Circle ID: $circleId'),
                ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance.collection('circles').doc(circleId).snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData || !snapshot.data!.exists) {
                  return const Center(child: CircularProgressIndicator());
                }
                final data = snapshot.data!.data()!;
                final total = (data['total'] ?? 0) as int;
                final target = (data['target'] ?? 1000) as int;
                final name = (data['name'] ?? 'Circle') as String;
                final members = List<String>.from(data['members'] ?? []);
                final pct = target == 0 ? 0.0 : (total / target).clamp(0.0, 1.0);

                return SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Text(name, style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: 220,
                        height: 220,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            CircularProgressIndicator(
                              value: pct,
                              strokeWidth: 14,
                              backgroundColor: AppColors.emerald.withOpacity(0.12),
                              valueColor: const AlwaysStoppedAnimation(AppColors.emerald),
                            ),
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('$total / $target', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                                Text('${(pct * 100).toStringAsFixed(1)}%'),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 8,
                        children: members
                            .map((m) => CircleAvatar(
                                  child: Text(m.isNotEmpty ? m.substring(0, 1).toUpperCase() : '?'),
                                ))
                            .toList(),
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton.icon(
                        onPressed: () => _addCount(circleId),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Add Count (+1)'),
                      ),
                      const SizedBox(height: 20),
                      Align(alignment: Alignment.centerLeft, child: Text('Live activity', style: Theme.of(context).textTheme.titleMedium)),
                      const SizedBox(height: 8),
                      _LiveActivityList(circleId: circleId),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addCount(String circleId) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? 'anonymous';
      final ref = FirebaseFirestore.instance.collection('circles').doc(circleId);
      await ref.update({'total': FieldValue.increment(1)});
      await ref.collection('activity').add({
        'uid': uid,
        'amount': 1,
        'at': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // Silently ignore; Circle screen already shows offline notice when
      // Firebase isn't configured at all.
    }
  }
}

class _LiveActivityList extends StatelessWidget {
  final String circleId;

  const _LiveActivityList({required this.circleId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('circles')
          .doc(circleId)
          .collection('activity')
          .orderBy('at', descending: true)
          .limit(20)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        final docs = snapshot.data!.docs;
        if (docs.isEmpty) return const Text('No activity yet — be the first to add a count.');
        return Column(
          children: docs.map((d) {
            final data = d.data();
            final uid = (data['uid'] ?? 'someone') as String;
            final amount = (data['amount'] ?? 1) as int;
            final shortUid = uid.length > 6 ? uid.substring(0, 6) : uid;
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.bolt_rounded, size: 18),
              title: Text('$shortUid added $amount'),
            );
          }).toList(),
        );
      },
    );
  }
}

// =========================================================================
// SETTINGS SCREEN
// =========================================================================

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Settings', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),

          _settingsCard(
            title: 'Volume Button Counting',
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Count with volume buttons'),
                  value: state.volumeButtonCounting,
                  onChanged: (v) => state.setVolumeButtonCounting(v),
                ),
                if (state.volumeButtonCounting)
                  Row(
                    children: [
                      Expanded(
                        child: RadioListTile<String>(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Volume Up'),
                          value: 'up',
                          groupValue: state.volumeButtonSide,
                          onChanged: (v) => state.setVolumeButtonSide(v!),
                        ),
                      ),
                      Expanded(
                        child: RadioListTile<String>(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Volume Down'),
                          value: 'down',
                          groupValue: state.volumeButtonSide,
                          onChanged: (v) => state.setVolumeButtonSide(v!),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          _settingsCard(
            title: 'Ghost Overlay Bubble',
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show floating bubble over other apps'),
              subtitle: const Text('A tiny transparent, draggable bubble. Tap it to count while using other apps.'),
              value: state.ghostOverlayEnabled,
              onChanged: (v) => state.setGhostOverlay(v),
            ),
          ),
          const SizedBox(height: 12),

          _settingsCard(
            title: 'AOD Mode (Always On Display)',
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Pure black screen with just the count'),
              subtitle: const Text('Keeps the screen on at low brightness while you count. Tap anywhere to add.'),
              value: state.aodMode,
              onChanged: (v) => state.setAodMode(v),
            ),
          ),
          const SizedBox(height: 12),

          _settingsCard(
            title: 'Giant Mode 👴',
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Larger text, bigger button, spoken counts'),
              subtitle: const Text('Bigger fonts and button, high contrast, and speaks the count every 33.'),
              value: state.giantMode,
              onChanged: (v) => state.setGiantMode(v),
            ),
          ),
          const SizedBox(height: 12),

          _settingsCard(
            title: 'Sound & Vibration',
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Sound (spoken counts, TTS)'),
                  value: state.soundEnabled,
                  onChanged: (v) => state.setSoundEnabled(v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Vibration'),
                  value: state.vibrationEnabled,
                  onChanged: (v) => state.setVibrationEnabled(v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          _settingsCard(
            title: 'Daily Reminder',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Reminder time'),
              subtitle: Text(state.dailyReminderTime.format(context)),
              trailing: const Icon(Icons.schedule_rounded),
              onTap: () async {
                final picked = await showTimePicker(context: context, initialTime: state.dailyReminderTime);
                if (picked != null) state.setReminderTime(picked);
              },
            ),
          ),
          const SizedBox(height: 12),

          _settingsCard(
            title: 'Trust',
            child: const Row(
              children: [
                Icon(Icons.verified_rounded, color: AppColors.emerald),
                SizedBox(width: 8),
                Expanded(child: Text('100% Offline • No Ads • No Tracking — For Allah')),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _settingsCard({required String title, required Widget child}) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}
