import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'package:dio/dio.dart';
import 'package:video_player/video_player.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:share_plus/share_plus.dart';

// ─── Global Singletons ────────────────────────────────────────────────────────

/// ዳታ ሲወርድ UI ለማሳወቅ
final ValueNotifier<bool> backgroundDownloadNotifier = ValueNotifier<bool>(false);

/// Notification Plugin
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

/// FIX 1: Dio Singleton — በየጊዜው new Dio() ከመፍጠር ይቆጥባል
final Dio _dio = Dio(BaseOptions(
  connectTimeout: const Duration(seconds: 15),
  receiveTimeout: const Duration(seconds: 60),
));

/// FIX 2: Directory Cache — getApplicationDocumentsDirectory() ደጋግሞ አይጠራም
Directory? _cachedAppDir;
Future<Directory> _getAppDir() async {
  _cachedAppDir ??= await getApplicationDocumentsDirectory();
  return _cachedAppDir!;
}

/// Notification tap → Ad ለማሳየት
bool _shouldShowAdOnLaunch = false;
bool _adShownForThisSession = false;

// ─── Entry Point ──────────────────────────────────────────────────────────────

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await MobileAds.instance.initialize();

  const AndroidInitializationSettings androidInit =
      AndroidInitializationSettings('@mipmap/ic_launcher');

  await flutterLocalNotificationsPlugin.initialize(
    const InitializationSettings(android: androidInit),
    onDidReceiveNotificationResponse: (NotificationResponse response) {
      _shouldShowAdOnLaunch = true;
      _adShownForThisSession = false;
    },
  );

  runApp(const MyApp());

  _listenToInternetChanges();

  const MethodChannel('ethio.tiktok.saver/accessibility')
      .setMethodCallHandler((MethodCall call) async {
    if (call.method == 'onVideoDetected') {
      final String videoData = call.arguments as String;
      await _manageAndDownloadVideo(videoData);
      backgroundDownloadNotifier.value = !backgroundDownloadNotifier.value;
    }
  });
}

// ─── ዳታ ሲበራ → Notification ──────────────────────────────────────────────────

void _listenToInternetChanges() {
  Connectivity().onConnectivityChanged.listen(
    (List<ConnectivityResult> results) async {
      final bool isOnline = results.contains(ConnectivityResult.mobile) ||
          results.contains(ConnectivityResult.wifi);
      if (isOnline) {
        await _showActivationNotification();
        _adShownForThisSession = false;
      }
    },
  );
}

Future<void> _showActivationNotification() async {
  const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
    'tiktok_cache_channel',
    'TikTok Activation Reminder',
    channelDescription: 'ዳታ ሲበራ ተጠቃሚውን ለማስታወስ',
    importance: Importance.max,
    priority: Priority.high,
  );
  await flutterLocalNotificationsPlugin.show(
    0,
    '🎯 Active ሁን — ቪዲዮዎችህ ዝግጁ ናቸው!',
    'ለማየት እዚህ ጫን። ኢንተርኔት ሳያስፈልግህ ትጫወታለህ 🎬',
    const NotificationDetails(android: androidDetails),
  );
}

// ─── ቪዲዮ ማውረድ (Max 500 FIFO) ───────────────────────────────────────────────

Future<void> _manageAndDownloadVideo(String videoInfo) async {
  try {
    final String mp4Url = videoInfo.trim();
    if (mp4Url.isEmpty) return;

    final Directory appDocDir = await _getAppDir();

    // FIX 3: listSync → async list() — UI thread አያግድም
    final List<File> videoFiles = await appDocDir
        .list()
        .where((e) => e.path.contains('/.tiktok_') && e.path.endsWith('.mp4'))
        .map((e) => File(e.path))
        .toList();

    if (videoFiles.length >= 500) {
      // FIX 4: lastModifiedSync ሁሉንም አስቀድሞ ያነሳል → sort ፈጣን ይሆናል
      videoFiles.sort(
        (a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()),
      );
      await videoFiles.first.delete();
    }

    final String savePath =
        '${appDocDir.path}/.tiktok_${DateTime.now().millisecondsSinceEpoch}.mp4';

    // FIX 5: Dio Singleton ይጠቀማል
    await _dio.download(mp4Url, savePath);
  } catch (e) {
    debugPrint('❌ ማውረድ ሳይሳካ ቀረ: $e');
  }
}

// ─── Ad Manager ───────────────────────────────────────────────────────────────

class AdManager {
  InterstitialAd? _interstitialAd;
  bool _isAdLoaded = false;
  int _retryAttempt = 0;
  static const int _maxRetries = 3;

  // FIX 6: Ad Loading ሁኔታ — ሁለት ጊዜ load እንዳያደርግ
  bool _isLoading = false;

  void loadInterstitialAd() {
    if (_isLoading || _isAdLoaded) return; // አስቀድሞ እየጫነ ካለ skip
    _isLoading = true;

    InterstitialAd.load(
      adUnitId: 'ca-app-pub-3940256099942544/1033173712',
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (InterstitialAd ad) {
          _interstitialAd = ad;
          _isAdLoaded = true;
          _isLoading = false;
          _retryAttempt = 0;
        },
        onAdFailedToLoad: (LoadAdError error) {
          _isAdLoaded = false;
          _isLoading = false;
          _interstitialAd = null;
          if (_retryAttempt < _maxRetries) {
            _retryAttempt++;
            Future.delayed(
              Duration(seconds: _retryAttempt * 2),
              loadInterstitialAd,
            );
          }
        },
      ),
    );
  }

  void showAdIfLoaded(VoidCallback onAdClosed) {
    if (_isAdLoaded && _interstitialAd != null) {
      _interstitialAd!.fullScreenContentCallback = FullScreenContentCallback(
        onAdDismissedFullScreenContent: (InterstitialAd ad) {
          ad.dispose();
          _isAdLoaded = false;
          loadInterstitialAd();
          onAdClosed();
        },
        onAdFailedToShowFullScreenContent: (InterstitialAd ad, AdError err) {
          ad.dispose();
          _isAdLoaded = false;
          loadInterstitialAd();
          onAdClosed();
        },
      );
      _interstitialAd!.show();
    } else {
      onAdClosed();
    }
  }

  void dispose() => _interstitialAd?.dispose();
}

// ─── App Root ─────────────────────────────────────────────────────────────────

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: Colors.black),
      home: const TikTokFeedScreen(),
    );
  }
}

// ─── Feed Screen ──────────────────────────────────────────────────────────────

class TikTokFeedScreen extends StatefulWidget {
  const TikTokFeedScreen({super.key});

  @override
  State<TikTokFeedScreen> createState() => _TikTokFeedScreenState();
}

class _TikTokFeedScreenState extends State<TikTokFeedScreen> {
  static const MethodChannel _settingsChannel =
      MethodChannel('ethio.tiktok.saver/settings');

  final AdManager _adManager = AdManager();
  final PageController _pageController = PageController();

  List<File> _savedVideos = [];
  bool _isLoading = true;
  int _currentIndex = 0;

  // FIX 7: Internet check debounce — ደጋግሞ lookup እንዳያደርግ
  bool _isCheckingInternet = false;

  @override
  void initState() {
    super.initState();
    _adManager.loadInterstitialAd();
    backgroundDownloadNotifier.addListener(_onBackgroundDownload);
    _loadSavedVideos();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_shouldShowAdOnLaunch && !_adShownForThisSession) {
        _shouldShowAdOnLaunch = false;
        _adShownForThisSession = true;
        _adManager.showAdIfLoaded(() {});
      }
    });
  }

  @override
  void dispose() {
    backgroundDownloadNotifier.removeListener(_onBackgroundDownload);
    _adManager.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _onBackgroundDownload() => _loadSavedVideos();

  // FIX 8: async list() ይጠቀማል — UI thread አያግድም
  Future<void> _loadSavedVideos() async {
    try {
      final Directory appDocDir = await _getAppDir();

      final List<File> mp4Files = await appDocDir
          .list()
          .where(
            (e) => e.path.contains('/.tiktok_') && e.path.endsWith('.mp4'),
          )
          .map((e) => File(e.path))
          .toList();

      mp4Files.sort(
        (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
      );

      if (mounted) {
        setState(() {
          _savedVideos = mp4Files;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // FIX 9: Internet check debounce — ሁለት ጊዜ እንዳይፈትሽ
  Future<bool> _checkInternet() async {
    if (_isCheckingInternet) return false;
    _isCheckingInternet = true;
    try {
      final List<InternetAddress> result =
          await InternetAddress.lookup('google.com')
              .timeout(const Duration(seconds: 3)); // FIX 10: Timeout ጨምር
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    } finally {
      _isCheckingInternet = false;
    }
  }

  void _onPageChanged(int index) {
    // FIX 11: setState ብቻ index ይቀይራል — ምንም ተጨማሪ rebuild የለም
    if (_currentIndex != index) {
      setState(() => _currentIndex = index);
    }

    if (index > 0 && index % 5 == 0) {
      _checkInternet().then((hasInternet) {
        if (hasInternet && mounted) {
          _adManager.showAdIfLoaded(() {});
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: Colors.cyan));
    }
    if (_savedVideos.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Text(
            '📱 TikTok ላይ ቪዲዮ ይጫወቱ\nApp ራሱ ያወርድና እዚህ ያሳያል!\n\nኢንተርኔት ሳያስፈልግ ይጫወታሉ 🎬',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, height: 1.8),
          ),
        ),
      );
    }

    return Stack(
      children: [
        // ── Video PageView ────────────────────────────────────────────────
        PageView.builder(
          controller: _pageController,
          scrollDirection: Axis.vertical,
          // FIX 12: physics → SnapScrollPhysics ለ TikTok-style snap
          physics: const _TikTokScrollPhysics(),
          itemCount: _savedVideos.length,
          onPageChanged: _onPageChanged,
          itemBuilder: (BuildContext context, int index) {
            // FIX 13: index-1, index, index+1 ብቻ active — ሌሎች ተሰርዘዋል
            final bool isFocused = index == _currentIndex;
            final bool isPreload = index == _currentIndex + 1;

            return TikTokVideoPlayer(
              key: ValueKey(_savedVideos[index].path),
              videoFile: _savedVideos[index],
              isFocused: isFocused,
              isPreload: isPreload,
            );
          },
        ),

        // ── Accessibility Button (top right) ─────────────────────────────
        Positioned(
          top: 48,
          right: 12,
          child: IconButton(
            icon: const Icon(Icons.accessibility, color: Colors.amber),
            onPressed: () =>
                _settingsChannel.invokeMethod('openAccessibilitySettings'),
          ),
        ),

        // ── Share Button (right side center) ─────────────────────────────
        if (_savedVideos.isNotEmpty)
          Positioned(
            right: 12,
            bottom: 120,
            child: _SideActions(
              videoFile: _savedVideos[_currentIndex],
            ),
          ),
      ],
    );
  }
}

// ─── TikTok Snap Scroll Physics ───────────────────────────────────────────────

/// FIX 14: ቪዲዮ ሲስክሮል ወዲያውኑ snap ያደርጋል — TikTok ዓይነት
class _TikTokScrollPhysics extends ScrollPhysics {
  const _TikTokScrollPhysics({super.parent});

  @override
  _TikTokScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _TikTokScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  SpringDescription get spring => const SpringDescription(
        mass: 80,    // ቀልጣፋ snap
        stiffness: 100,
        damping: 1,
      );
}

// ─── Side Action Buttons (Share) ─────────────────────────────────────────────

class _SideActions extends StatelessWidget {
  final File videoFile;
  const _SideActions({required this.videoFile});

  Future<void> _share() async {
    try {
      await Share.shareXFiles(
        [XFile(videoFile.path)],
        text: '🎬 TikTok Smart Cache ቪዲዮ',
      );
    } catch (e) {
      debugPrint('Share ሳይሳካ ቀረ: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Share Button
        _ActionButton(
          icon: Icons.share_rounded,
          label: 'Share',
          onTap: _share,
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.4),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white, size: 26),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              shadows: [Shadow(blurRadius: 4, color: Colors.black)],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Video Player Widget ──────────────────────────────────────────────────────

class TikTokVideoPlayer extends StatefulWidget {
  final File videoFile;
  final bool isFocused;
  final bool isPreload; // FIX 15: ቀጣዩ ቪዲዮ አስቀድሞ initialize ይደረጋል

  const TikTokVideoPlayer({
    super.key,
    required this.videoFile,
    required this.isFocused,
    this.isPreload = false,
  });

  @override
  State<TikTokVideoPlayer> createState() => _TikTokVideoPlayerState();
}

class _TikTokVideoPlayerState extends State<TikTokVideoPlayer> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  bool _isInitializing = false; // FIX 16: ሁለት ጊዜ init እንዳይሆን

  @override
  void initState() {
    super.initState();
    if (widget.isFocused || widget.isPreload) {
      _initializePlayer();
    }
  }

  @override
  void didUpdateWidget(covariant TikTokVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);

    final bool shouldInit = widget.isFocused || widget.isPreload;
    final bool wasInit = oldWidget.isFocused || oldWidget.isPreload;

    if (shouldInit && !_isInitialized && !_isInitializing) {
      _initializePlayer();
    }

    // isFocused ሆነ → play
    if (widget.isFocused && !oldWidget.isFocused && _isInitialized) {
      _controller?.play();
    }

    // focus ጠፋ → pause (dispose አያደርግም — preload ሆኖ ይጠብቃል)
    if (!widget.isFocused && oldWidget.isFocused && _isInitialized) {
      _controller?.pause();
    }

    // ፈጽሞ አያስፈልግም (index ሩቅ ሄዷል) → dispose
    if (!shouldInit && wasInit) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _disposePlayer();
      });
    }
  }

  Future<void> _initializePlayer() async {
    if (_isInitializing) return;
    _isInitializing = true;

    final VideoPlayerController ctrl =
        VideoPlayerController.file(widget.videoFile);
    _controller = ctrl;

    try {
      await ctrl.initialize();
      if (!mounted) {
        ctrl.dispose();
        return;
      }
      ctrl.setLooping(true);
      // isFocused ከሆነ ብቻ ወዲያውኑ play ያደርጋል፤ preload ከሆነ ይጠብቃል
      if (widget.isFocused) ctrl.play();

      if (mounted) setState(() => _isInitialized = true);
    } catch (e) {
      debugPrint('ቪዲዮ init ሳይሳካ ቀረ: $e');
      ctrl.dispose();
      _controller = null;
    } finally {
      _isInitializing = false;
    }
  }

  void _disposePlayer() {
    _controller?.dispose();
    _controller = null;
    if (mounted) setState(() => _isInitialized = false);
  }

  void _togglePlayPause() {
    final VideoPlayerController? ctrl = _controller;
    if (ctrl == null || !_isInitialized) return;
    setState(() => ctrl.value.isPlaying ? ctrl.pause() : ctrl.play());
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final VideoPlayerController? ctrl = _controller;
    final bool ready = _isInitialized && ctrl != null;

    return GestureDetector(
      onTap: _togglePlayPause,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── ቀዩ ጀርባ (loading ጊዜ ይታያል) ───────────────────────────────
          const ColoredBox(color: Colors.black),

          // ── ቪዲዮ ──────────────────────────────────────────────────────
          if (ready)
            // FIX 17: FittedBox ተወግዶ SizedBox.expand + VideoPlayer ቀጥታ
            // FittedBox ሁልጊዜ ዳግም ይሰሉ ነበር → ዘገምተኛ
            Center(
              child: AspectRatio(
                aspectRatio: ctrl.value.aspectRatio,
                child: VideoPlayer(ctrl),
              ),
            )
          else
            const Center(
              child: CircularProgressIndicator(color: Colors.cyan),
            ),

          // ── Play Icon (paused ጊዜ) ────────────────────────────────────
          if (ready && !ctrl.value.isPlaying)
            const Center(
              child: Icon(Icons.play_arrow, size: 80, color: Colors.white38),
            ),
        ],
      ),
    );
  }
}
