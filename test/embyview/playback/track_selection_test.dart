import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/models/series_track_preference.dart';
import 'package:moonfin/embyview/contracts/preferences.dart';
import 'package:moonfin/embyview/playback/track_selection.dart';
import 'package:moonfin/util/playback_track_selection.dart';

void main() {
  group('rankTrackLanguage', () {
    test('distinguishes simplified Chinese, traditional Chinese, and Cantonese', () {
      expect(
        compareTrackLanguageRank(
          rankTrackLanguage(const ['zh', 'en'], language: 'chi', title: '简体中文')!,
          rankTrackLanguage(const ['zh', 'en'], language: 'chi', title: '繁体中文')!,
        ),
        lessThan(0),
      );
      expect(
        compareTrackLanguageRank(
          rankTrackLanguage(const ['zh', 'en'], language: 'chi', title: '繁体中文')!,
          rankTrackLanguage(const ['zh', 'en'], language: 'eng', title: 'English')!,
        ),
        lessThan(0),
      );
      expect(
        compareTrackLanguageRank(
          rankTrackLanguage(const ['zh-hant', 'zh', 'en'], language: 'chi', title: '繁体中文')!,
          rankTrackLanguage(const ['zh-hant', 'zh', 'en'], language: 'chi', title: '简体中文')!,
        ),
        lessThan(0),
      );
      expect(
        rankTrackLanguage(const ['zh-hant', 'en'], language: 'chi', title: '简体中文'),
        isNull,
      );
      expect(
        rankTrackLanguage(const ['yue', 'zh'], language: 'chi', title: '粤语 5.1')?.index,
        0,
      );
      expect(
        rankTrackLanguage(const ['yue', 'zh'], language: 'chi', title: '国语 5.1')?.index,
        1,
      );
      expect(
        rankTrackLanguage(const ['zh'], language: 'chi', title: '粤语 5.1'),
        isNull,
      );
    });
  });

  group('selectEmbyViewAudioIndex', () {
    final streams = <Map<String, dynamic>>[
      {'Type': 'Audio', 'Index': 1, 'Language': 'eng', 'Channels': 6, 'IsDefault': true, 'Title': 'English 5.1'},
      {'Type': 'Audio', 'Index': 2, 'Language': 'jpn', 'Channels': 2, 'Title': 'Japanese Stereo'},
      {'Type': 'Audio', 'Index': 3, 'Language': 'chi', 'Channels': 6, 'Title': '国语 5.1'},
      {'Type': 'Audio', 'Index': 4, 'Language': 'chi', 'Channels': 2, 'Title': '粤语 2.0'},
      {'Type': 'Audio', 'Index': 5, 'Language': 'jpn', 'Channels': 2, 'Title': 'Director Commentary'},
    ];

    test('follows media default when audioLanguages is empty', () {
      expect(
        selectEmbyViewAudioIndex(
          audioStreams: streams,
          prefs: const LocalPreferences(audioLanguages: []),
        ),
        1,
      );
    });

    test('matches ordered audioLanguages including Cantonese', () {
      expect(
        selectEmbyViewAudioIndex(
          audioStreams: streams,
          prefs: const LocalPreferences(audioLanguages: ['ja', 'zh']),
        ),
        2,
      );
      expect(
        selectEmbyViewAudioIndex(
          audioStreams: streams,
          prefs: const LocalPreferences(audioLanguages: ['yue', 'zh']),
        ),
        4,
      );
      expect(
        selectEmbyViewAudioIndex(
          audioStreams: streams,
          prefs: const LocalPreferences(audioLanguages: ['kor', 'zh']),
        ),
        3,
      );
      // Falls back to default when no language matches.
      expect(
        selectEmbyViewAudioIndex(
          audioStreams: streams,
          prefs: const LocalPreferences(audioLanguages: ['kor']),
        ),
        1,
      );
    });

    test('preserves explicit pick > series memory > session carry over global defaults', () {
      expect(
        selectEmbyViewAudioIndex(
          audioStreams: streams,
          prefs: const LocalPreferences(audioLanguages: ['ja']),
          explicitIndex: 3,
          seriesPref: const SeriesTrackPreference(language: 'eng', title: 'english 5.1'),
          session: const SessionTrackChoices(audioLanguage: 'chi'),
        ),
        3,
      );
      expect(
        selectEmbyViewAudioIndex(
          audioStreams: streams,
          prefs: const LocalPreferences(audioLanguages: ['ja']),
          seriesPref: const SeriesTrackPreference(language: 'eng', title: 'english 5.1'),
          session: const SessionTrackChoices(audioLanguage: 'chi'),
        ),
        1,
      );
      expect(
        selectEmbyViewAudioIndex(
          audioStreams: streams,
          prefs: const LocalPreferences(audioLanguages: ['ja']),
          session: const SessionTrackChoices(audioLanguage: 'chi', audioTitle: '国语 5.1'),
        ),
        3,
      );
    });
  });

  group('selectEmbyViewSubtitleIndex', () {
    final audioStreams = <Map<String, dynamic>>[
      {'Type': 'Audio', 'Index': 1, 'Language': 'chi', 'Title': '国语', 'IsDefault': true},
      {'Type': 'Audio', 'Index': 2, 'Language': 'jpn', 'Title': 'Japanese'},
    ];
    final subtitleStreams = <Map<String, dynamic>>[
      {'Type': 'Subtitle', 'Index': 10, 'Language': 'eng', 'Title': 'English', 'IsDefault': true},
      {'Type': 'Subtitle', 'Index': 11, 'Language': 'chi', 'Title': '简体中文 (Forced)', 'IsForced': true},
      {'Type': 'Subtitle', 'Index': 12, 'Language': 'chi', 'Title': '简体中文'},
      {'Type': 'Subtitle', 'Index': 13, 'Language': 'chi', 'Title': '繁体中文'},
      {'Type': 'Subtitle', 'Index': 14, 'Language': 'jpn', 'Title': 'Japanese'},
    ];

    test('always mode picks highest-priority language and skips forced when full exists', () {
      expect(
        selectEmbyViewSubtitleIndex(
          subtitleStreams: subtitleStreams,
          audioStreams: audioStreams,
          prefs: const LocalPreferences(
            subtitleLanguages: ['zh', 'ja', 'en'],
            subtitleAutoMode: SubtitleAutoMode.always,
          ),
        ),
        12,
      );
      expect(
        selectEmbyViewSubtitleIndex(
          subtitleStreams: subtitleStreams,
          audioStreams: audioStreams,
          prefs: const LocalPreferences(
            subtitleLanguages: ['zh-hant', 'zh'],
            subtitleAutoMode: SubtitleAutoMode.always,
          ),
        ),
        13,
      );
      expect(
        selectEmbyViewSubtitleIndex(
          subtitleStreams: subtitleStreams,
          audioStreams: audioStreams,
          prefs: const LocalPreferences(
            subtitleLanguages: ['ja', 'zh'],
            subtitleAutoMode: SubtitleAutoMode.always,
          ),
        ),
        14,
      );
    });

    test('foreignOnly disables subtitles for native audio and enables for foreign audio', () {
      expect(
        selectEmbyViewSubtitleIndex(
          subtitleStreams: subtitleStreams,
          audioStreams: audioStreams,
          prefs: const LocalPreferences(
            audioLanguages: [],
            subtitleLanguages: ['zh', 'en'],
            subtitleAutoMode: SubtitleAutoMode.foreignOnly,
          ),
        ),
        -1,
      );
      expect(
        selectEmbyViewSubtitleIndex(
          subtitleStreams: subtitleStreams,
          audioStreams: audioStreams,
          prefs: const LocalPreferences(
            audioLanguages: ['ja'],
            subtitleLanguages: ['zh', 'en'],
            subtitleAutoMode: SubtitleAutoMode.foreignOnly,
          ),
        ),
        -1,
      );
      expect(
        selectEmbyViewSubtitleIndex(
          subtitleStreams: subtitleStreams,
          audioStreams: [
            {'Type': 'Audio', 'Index': 2, 'Language': 'jpn', 'Title': 'Japanese', 'IsDefault': true},
          ],
          prefs: const LocalPreferences(
            audioLanguages: ['zh'],
            subtitleLanguages: ['zh', 'en'],
            subtitleAutoMode: SubtitleAutoMode.foreignOnly,
          ),
        ),
        12,
      );
    });

    test('off mode and series/session explicit off disable subtitles', () {
      expect(
        selectEmbyViewSubtitleIndex(
          subtitleStreams: subtitleStreams,
          audioStreams: audioStreams,
          prefs: const LocalPreferences(subtitleAutoMode: SubtitleAutoMode.off),
        ),
        -1,
      );
      expect(
        selectEmbyViewSubtitleIndex(
          subtitleStreams: subtitleStreams,
          audioStreams: audioStreams,
          prefs: const LocalPreferences(subtitleAutoMode: SubtitleAutoMode.always),
          seriesSubtitlePref: SeriesTrackPreference.none,
        ),
        -1,
      );
      expect(
        selectEmbyViewSubtitleIndex(
          subtitleStreams: subtitleStreams,
          audioStreams: audioStreams,
          prefs: const LocalPreferences(subtitleAutoMode: SubtitleAutoMode.always),
          session: const SessionTrackChoices(subtitleEnabled: false),
        ),
        -1,
      );
    });
  });
}
