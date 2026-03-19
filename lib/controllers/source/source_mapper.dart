import 'dart:async';

import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/controllers/source/source_controller.dart';
import 'package:anymex/models/Media/media.dart';
import 'package:anymex/utils/logger.dart';
import 'package:anymex_extension_runtime_bridge/anymex_extension_runtime_bridge.dart';
import 'package:fuzzywuzzy/fuzzywuzzy.dart';
import 'package:get/get.dart';

String _normalizeLight(String title) {
  return title.trim().toLowerCase();
}

bool _isInvalidTitle(String? title) {
  final value = (title ?? '').trim().toLowerCase();
  return value.isEmpty || value == '?' || value == '??' || value == 'null';
}

String _normalizeHeavy(String title) {
  String normalized =
      title.replaceAll(RegExp(r'\bseason\s*', caseSensitive: false), '');

  normalized =
      normalized.replaceAll(RegExp(r'[^a-zA-Z0-9\s]'), '').trim().toLowerCase();
  return normalized;
}

int? _extractSeasonNumber(String title) {
  final patterns = [
    RegExp(r'\b(\d+)(?:th|st|nd|rd)?\s*season\b', caseSensitive: false),
    RegExp(r'\bseason\s*(\d+)\b', caseSensitive: false),
    RegExp(r'\s(\d+)\b(?!\s*[a-zA-Z])'),
    RegExp(r'\b(\d+)(nd|rd|th|st)\b'),
  ];

  for (final pattern in patterns) {
    final match = pattern.firstMatch(title);
    if (match != null && match.group(1) != null) {
      return int.tryParse(match.group(1)!);
    }
  }
  return null;
}

double _calculateMatchScore(
  String sourceTitle,
  String targetTitle,
  int? sourceSeason,
  int? targetSeason,
) {
  if (sourceTitle.isEmpty) return 0.0;

  final tst = tokenSetRatio(sourceTitle, targetTitle) / 100.0;
  final pr = partialRatio(sourceTitle, targetTitle) / 100.0;
  final r = ratio(sourceTitle, targetTitle) / 100.0;

  double score = (tst * 0.4) + (pr * 0.3) + (r * 0.3);

  if (targetSeason != null && sourceSeason != null) {
    score += (targetSeason == sourceSeason) ? 0.3 : -0.1;
  }

  return score.clamp(0.0, 1.0);
}

Media createMediaFromExtension(DMedia data, ItemType type) {
  return Media(
    id: data.url ?? '',
    title: data.title ?? '',
    poster: data.cover ?? '',
    mediaType: type,
    serviceType: ServicesType.extensions,
  );
}

Future<Media?> mapMedia(
  List<String> animeId,
  RxString searchedTitle, {
  String? savedTitle,
}) async {
  final sourceController = Get.find<SourceController>();
  final isManga = animeId[0].split("*").last == "MANGA";
  final type = isManga ? ItemType.manga : ItemType.anime;

  String englishTitle = animeId[0].split("*").first.trim();
  String romajiTitle = (animeId.length > 1 ? animeId[1] : '').trim();

  if (_isInvalidTitle(englishTitle)) {
    englishTitle = '';
  }
  if (_isInvalidTitle(romajiTitle)) {
    romajiTitle = '';
  }
  if (englishTitle.isEmpty && romajiTitle.isNotEmpty) {
    englishTitle = romajiTitle;
  }
  if (romajiTitle.isEmpty && englishTitle.isNotEmpty) {
    romajiTitle = englishTitle;
  }

  final activeSource = isManga
      ? sourceController.activeMangaSource.value
      : sourceController.activeSource.value;

  if (activeSource == null) {
    Logger.i("No active source found!");
    return null;
  }

  double bestScore = 0;
  dynamic bestMatch;
  List<DMedia> fallbackResults = [];

  Future<void> search(
      String query, String sourceTitle, bool isHeavyNormalized) async {
    searchedTitle.value = "Searching: $sourceTitle";
    final results = (await activeSource.methods.search(query, 1, [])).list;
    if (results.isEmpty) return;

    final sourceSeason = _extractSeasonNumber(sourceTitle);

    for (final result in results) {
      final resultTitle = result.title ?? '';
      final normalizedResultTitle = isHeavyNormalized
          ? _normalizeHeavy(resultTitle.trim())
          : _normalizeLight(resultTitle.trim());

      searchedTitle.value = "Finding: $resultTitle";
      await Future.delayed(const Duration(milliseconds: 100));

      if (savedTitle != null &&
          _normalizeLight(resultTitle) == _normalizeLight(savedTitle)) {
        bestScore = 1.0;
        bestMatch = result;
        fallbackResults = results;
        print("Exact match with savedTitle: $resultTitle");
        return;
      }

      final resultSeason = _extractSeasonNumber(resultTitle);

      final score = _calculateMatchScore(
        isHeavyNormalized
            ? _normalizeHeavy(sourceTitle)
            : _normalizeLight(sourceTitle),
        normalizedResultTitle,
        sourceSeason,
        resultSeason,
      );

      if (score >= 0.95) {
        bestScore = score;
        bestMatch = result;
        fallbackResults = results;
        print("Perfect match: $resultTitle");
        return;
      }

      if (score > bestScore) {
        bestScore = score;
        bestMatch = result;
        fallbackResults = results;
      }
    }
  }

  if (savedTitle != null && savedTitle.isNotEmpty) {
    await search(savedTitle, savedTitle, false);
    if (bestScore >= 1.0 && bestMatch != null) {
      searchedTitle.value = "Found: ${bestMatch.title ?? ''}";
      return Media.froDMedia(bestMatch, type);
    }
  }

  if (englishTitle.isNotEmpty) {
    await search(englishTitle, englishTitle, false);
  }

  if (bestScore < 0.95 &&
      romajiTitle.isNotEmpty &&
      _normalizeLight(romajiTitle) != _normalizeLight(englishTitle)) {
    await search(romajiTitle, romajiTitle, false);
  }

  if (bestScore > 0.9 && bestMatch != null) {
    searchedTitle.value = "Found: ${bestMatch.title ?? ''}";
    print("Good match found: score ${bestScore.toStringAsFixed(3)}");
    return Media.froDMedia(bestMatch, type);
  }

  print("No good match found. Trying with heavy normalization...");
  bestScore = 0;
  bestMatch = null;

  if (savedTitle != null && savedTitle.isNotEmpty) {
    await search(_normalizeHeavy(savedTitle), savedTitle, true);
    if (bestScore >= 1.0 && bestMatch != null) {
      searchedTitle.value = "Found: ${bestMatch.title ?? ''}";
      return Media.froDMedia(bestMatch, type);
    }
  }

  if (englishTitle.isNotEmpty) {
    await search(_normalizeHeavy(englishTitle), englishTitle, true);
  }

  if (bestScore < 0.95 &&
      romajiTitle.isNotEmpty &&
      _normalizeLight(romajiTitle) != _normalizeLight(englishTitle)) {
    await search(_normalizeHeavy(romajiTitle), romajiTitle, true);
  }

  if (bestScore >= 0.7 && bestMatch != null) {
    searchedTitle.value = "Found: ${bestMatch.title ?? ''}";
    print(
        "Final match with heavy normalization: score ${bestScore.toStringAsFixed(3)}");
    return Media.froDMedia(bestMatch, type);
  }

  print("No good match. Best: ${bestScore.toStringAsFixed(3)}");
  searchedTitle.value = fallbackResults.isNotEmpty
      ? "Found: ${fallbackResults.first.title ?? 'Unknown Title'}"
      : "No Match Found";

  return fallbackResults.isNotEmpty
      ? Media.froDMedia(fallbackResults.first, type)
      : Media(serviceType: ServicesType.anilist);
}

/// Try searching a single source with a timeout.
/// Returns null if the source doesn't find a good match or times out.
Future<Media?> _trySourceWithTimeout(
  Source source,
  List<String> animeId,
  RxString searchedTitle,
  String? savedTitle,
  ItemType type,
  Duration timeout,
) async {
  try {
    final sourceController = Get.find<SourceController>();
    final isManga = animeId[0].split("*").last == "MANGA";

    String englishTitle = animeId[0].split("*").first.trim();
    String romajiTitle = (animeId.length > 1 ? animeId[1] : '').trim();

    if (_isInvalidTitle(englishTitle)) englishTitle = '';
    if (_isInvalidTitle(romajiTitle)) romajiTitle = '';
    if (englishTitle.isEmpty && romajiTitle.isNotEmpty) {
      englishTitle = romajiTitle;
    }
    if (romajiTitle.isEmpty && englishTitle.isNotEmpty) {
      romajiTitle = englishTitle;
    }

    final query = savedTitle ?? englishTitle;
    if (query.isEmpty) return null;

    searchedTitle.value = "Searching: ${source.name ?? ''}...";

    final results = await source.methods
        .search(query, 1, [])
        .timeout(timeout, onTimeout: () {
      throw TimeoutException('Source ${source.name} timed out');
    });

    if (results.list.isEmpty) return null;

    // Use fuzzy matching to find best result
    double bestScore = 0;
    dynamic bestMatch;

    for (final result in results.list) {
      final resultTitle = result.title ?? '';
      if (resultTitle.isEmpty) continue;

      // Check exact saved title match
      if (savedTitle != null &&
          _normalizeLight(resultTitle) == _normalizeLight(savedTitle)) {
        searchedTitle.value = "Found: $resultTitle";
        return Media.froDMedia(result, type);
      }

      final score = _calculateMatchScore(
        _normalizeLight(englishTitle),
        _normalizeLight(resultTitle),
        _extractSeasonNumber(englishTitle),
        _extractSeasonNumber(resultTitle),
      );

      if (score > bestScore) {
        bestScore = score;
        bestMatch = result;
      }
    }

    // Also try romaji if different from english
    if (bestScore < 0.9 &&
        romajiTitle.isNotEmpty &&
        _normalizeLight(romajiTitle) != _normalizeLight(englishTitle)) {
      final romajiResults = await source.methods
          .search(romajiTitle, 1, [])
          .timeout(timeout, onTimeout: () {
        throw TimeoutException('Source ${source.name} romaji timed out');
      });

      for (final result in romajiResults.list) {
        final resultTitle = result.title ?? '';
        if (resultTitle.isEmpty) continue;

        final score = _calculateMatchScore(
          _normalizeLight(romajiTitle),
          _normalizeLight(resultTitle),
          _extractSeasonNumber(romajiTitle),
          _extractSeasonNumber(resultTitle),
        );

        if (score > bestScore) {
          bestScore = score;
          bestMatch = result;
        }
      }
    }

    if (bestScore >= 0.7 && bestMatch != null) {
      searchedTitle.value = "Found: ${bestMatch.title ?? ''}";
      return Media.froDMedia(bestMatch, type);
    }

    return null;
  } on TimeoutException {
    searchedTitle.value = "${source.name ?? 'Source'} timed out";
    return null;
  } catch (e) {
    searchedTitle.value = "${source.name ?? 'Source'} failed";
    return null;
  }
}

/// Auto-next/fallback search across all installed sources.
/// Tries the active source first, then iterates through remaining sources.
/// Stops when a match is found or [cancelSearch] is set to true.
/// Returns a tuple of (matched Media, Source that found it).
Future<(Media?, Source?)> mapMediaWithFallback(
  List<String> animeId,
  RxString searchedTitle, {
  String? savedTitle,
  required ItemType type,
  required RxBool cancelSearch,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final sourceCtrl = Get.find<SourceController>();
  final sources = sourceCtrl.getInstalledExtensions(type);

  final isManga = type == ItemType.manga || type == ItemType.novel;
  final activeSource = isManga
      ? sourceCtrl.activeMangaSource.value
      : sourceCtrl.activeSource.value;

  // 1. Try the active (or saved) source first
  if (activeSource != null && !cancelSearch.value) {
    searchedTitle.value = "Searching: ${activeSource.name ?? ''}...";
    final result = await _trySourceWithTimeout(
        activeSource, animeId, searchedTitle, savedTitle, type, timeout);
    if (result != null && result.id.toString().isNotEmpty) {
      return (result, activeSource);
    }
  }

  // 2. Auto-next: iterate remaining installed sources
  for (final source in sources) {
    if (cancelSearch.value) {
      searchedTitle.value = "Search paused";
      break;
    }
    if (source.id == activeSource?.id) continue; // already tried

    searchedTitle.value = "Trying: ${source.name ?? 'Unknown'}...";

    final result = await _trySourceWithTimeout(
        source, animeId, searchedTitle, savedTitle, type, timeout);
    if (result != null && result.id.toString().isNotEmpty) {
      // Switch active source to the one that found results (per-title, Option B)
      sourceCtrl.setActiveSource(source);
      return (result, source);
    }
  }

  searchedTitle.value = "No Match Found";
  return (null, null);
}
