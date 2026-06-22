import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/services/offline_listen_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logging/logging.dart';

import '../models/finamp_models.dart';
import '../models/jellyfin_models.dart';
import 'downloads_helper.dart';
import 'finamp_settings_helper.dart';
import 'finamp_user_helper.dart';
import 'jellyfin_api_helper.dart';

// Largely copied from just_audio's DefaultShuffleOrder, but with a mildly
// stupid hack to insert() to make Play Next work
class FinampShuffleOrder extends ShuffleOrder {
  final Random _random;
  @override
  final indices = <int>[];

  FinampShuffleOrder({Random? random}) : _random = random ?? Random();

  @override
  void shuffle({int? initialIndex}) {
    assert(initialIndex == null || indices.contains(initialIndex));
    if (indices.length <= 1) return;
    indices.shuffle(_random);
    if (initialIndex == null) return;

    const initialPos = 0;
    final swapPos = indices.indexOf(initialIndex);
    // Swap the indices at initialPos and swapPos.
    final swapIndex = indices[initialPos];
    indices[initialPos] = initialIndex;
    indices[swapPos] = swapIndex;
  }

  @override
  void insert(int index, int count) {
    // Offset indices after insertion point.
    for (var i = 0; i < indices.length; i++) {
      if (indices[i] >= index) {
        indices[i] += count;
      }
    }

    final newIndices = List.generate(count, (i) => index + i);
    // This is the only modification from DefaultShuffleOrder: Only shuffle
    // inserted indices amongst themselves, but keep them contiguous
    newIndices.shuffle(_random);
    indices.insertAll(index, newIndices);
  }

  @override
  void removeRange(int start, int end) {
    final count = end - start;
    // Remove old indices.
    final oldIndices = List.generate(count, (i) => start + i).toSet();
    indices.removeWhere(oldIndices.contains);
    // Offset indices after deletion point.
    for (var i = 0; i < indices.length; i++) {
      if (indices[i] >= end) {
        indices[i] -= count;
      }
    }
  }

  @override
  void clear() {
    indices.clear();
  }
}

/// This provider handles the currently playing music so that multiple widgets
/// can control music.
class MusicPlayerBackgroundTask extends BaseAudioHandler {
  final _player = AudioPlayer(
    audioLoadConfiguration: AudioLoadConfiguration(
        androidLoadControl: AndroidLoadControl(
          minBufferDuration: FinampSettingsHelper.finampSettings.bufferDuration,
          maxBufferDuration: FinampSettingsHelper.finampSettings.bufferDuration,
          prioritizeTimeOverSizeThresholds: true,
        ),
        darwinLoadControl: DarwinLoadControl(
          preferredForwardBufferDuration:
              FinampSettingsHelper.finampSettings.bufferDuration,
        )),
  );
  ConcatenatingAudioSource _queueAudioSource = ConcatenatingAudioSource(
    children: [],
    shuffleOrder: FinampShuffleOrder(),
  );
  final _audioServiceBackgroundTaskLogger = Logger("MusicPlayerBackgroundTask");
  final _jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
  final _offlineListenLogHelper = GetIt.instance<OfflineListenLogHelper>();
  final _finampUserHelper = GetIt.instance<FinampUserHelper>();
  final _downloadsHelper = GetIt.instance<DownloadsHelper>();

  static const _browsableRootId = '__browsable_root__';
  static const _autoPlaylistsId = '__AA_PLAYLISTS__';
  static const _autoAlbumsId = '__AA_ALBUMS__';
  static const _autoArtistsId = '__AA_ARTISTS__';
  static const _autoFavoritesId = '__AA_FAVORITES__';
  static const _autoPlaylistPrefix = 'aa_playlist:';
  static const _autoAlbumPrefix = 'aa_album:';
  static const _autoArtistPrefix = 'aa_artist:';

  /// Set when shuffle mode is changed. If true, [onUpdateQueue] will create a
  /// shuffled [ConcatenatingAudioSource].
  bool shuffleNextQueue = false;

  /// Set when creating a new queue. Will be used to set the first index in a
  /// new queue.
  int? nextInitialIndex;

  /// Set to true when we're stopping the audio service. Used to avoid playback
  /// progress reporting.
  bool _isStopping = false;

  /// Holds the current sleep timer, if any. This is a ValueNotifier so that
  /// widgets like SleepTimerButton can update when the sleep timer is/isn't
  /// null.
  bool _sleepTimerIsSet = false;
  Duration _sleepTimerDuration = Duration.zero;
  final ValueNotifier<Timer?> _sleepTimer = ValueNotifier<Timer?>(null);

  List<int>? get shuffleIndices => _player.shuffleIndices;

  ValueListenable<Timer?> get sleepTimer => _sleepTimer;

  MusicPlayerBackgroundTask() {
    _audioServiceBackgroundTaskLogger.info("Starting audio service");

    // Propagate all events from the audio player to AudioService clients.
    _player.playbackEventStream.listen((event) async {
      final prevState = playbackState.valueOrNull;
      final prevIndex = prevState?.queueIndex;
      final prevItem = mediaItem.valueOrNull;
      final currentState = _transformEvent(event);
      final currentIndex = currentState.queueIndex;

      playbackState.add(currentState);

      if (currentIndex != null) {
        final currentItem = _getQueueItem(currentIndex);

        // Differences in queue index or item id are considered track changes
        if (currentIndex != prevIndex || currentItem.id != prevItem?.id) {
          mediaItem.add(currentItem);

          onTrackChanged(currentItem, currentState, prevItem, prevState);
        }
      }

      if (playbackState.valueOrNull != null &&
          playbackState.valueOrNull?.processingState !=
              AudioProcessingState.idle &&
          playbackState.valueOrNull?.processingState !=
              AudioProcessingState.completed &&
          !FinampSettingsHelper.finampSettings.isOffline &&
          !_isStopping) {
        await _updatePlaybackProgress();
      }
    });

    // Special processing for state transitions.
    _player.processingStateStream.listen((event) {
      if (event == ProcessingState.completed) {
        stop();
      }
    });

    // PlaybackEvent doesn't include shuffle/loops so we listen for changes here
    _player.shuffleModeEnabledStream.listen(
        (_) => playbackState.add(_transformEvent(_player.playbackEvent)));
    _player.loopModeStream.listen(
        (_) => playbackState.add(_transformEvent(_player.playbackEvent)));
  }

  @override
  Future<void> play() {
    // If a sleep timer has been set and the timer went off
    //  causing play to pause, if the user starts to play
    //  audio again, and the sleep timer hasn't been explicitly
    //  turned off, then reset the sleep timer.
    // This is useful if the sleep timer pauses play too early
    //  and the user wants to continue listening
    if (_sleepTimerIsSet && _sleepTimer.value == null) {
      // restart the sleep timer for another period
      setSleepTimer(_sleepTimerDuration);
    }

    return _player.play();
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    try {
      _audioServiceBackgroundTaskLogger.info("Stopping audio service");

      _isStopping = true;

      // Tell Jellyfin we're no longer playing audio if we're online
      if (!FinampSettingsHelper.finampSettings.isOffline) {
        final playbackInfo = generateCurrentPlaybackProgressInfo();
        if (playbackInfo != null) {
          await _jellyfinApiHelper.stopPlaybackProgress(playbackInfo);
        }
      } else {
        final currentIndex = _player.currentIndex;
        if (_queueAudioSource.length != 0 && currentIndex != null) {
          final item = _getQueueItem(currentIndex);
          _offlineListenLogHelper.logOfflineListen(item);
        }
      }

      // Stop playing audio.
      await _player.stop();

      // Seek to the start of the first item in the queue
      await _player.seek(Duration.zero, index: 0);

      _sleepTimerIsSet = false;
      _sleepTimerDuration = Duration.zero;

      _sleepTimer.value?.cancel();
      _sleepTimer.value = null;

      await super.stop();

      // await _player.dispose();
      // await _eventSubscription?.cancel();
      // // It is important to wait for this state to be broadcast before we shut
      // // down the task. If we don't, the background task will be destroyed before
      // // the message gets sent to the UI.
      // await _broadcastState();
      // // Shut down this background task
      // await super.stop();

      _isStopping = false;
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  @override
  @Deprecated("Use addQueueItems instead")
  Future<void> addQueueItem(MediaItem mediaItem) async {
    addQueueItems([mediaItem]);
  }

  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {
    try {
      final sources =
          await Future.wait(mediaItems.map((i) => _mediaItemToAudioSource(i)));
      await _queueAudioSource.addAll(sources);
      queue.add(_queueFromSource());
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  Future<void> insertQueueItemsNext(List<MediaItem> mediaItems) async {
    try {
      var idx = _player.currentIndex;
      if (idx != null) {
        if (_player.shuffleModeEnabled) {
          var next = _player.shuffleIndices?.indexOf(idx);
          idx = next == -1 || next == null ? null : next + 1;
        } else {
          ++idx;
        }
      }
      idx ??= 0;

      final sources =
          await Future.wait(mediaItems.map((i) => _mediaItemToAudioSource(i)));
      await _queueAudioSource.insertAll(idx, sources);
      queue.add(_queueFromSource());
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  @override
  Future<void> updateQueue(List<MediaItem> newQueue) async {
    try {
      // Convert the MediaItems to AudioSources
      List<AudioSource> audioSources = [];
      for (final mediaItem in newQueue) {
        audioSources.add(await _mediaItemToAudioSource(mediaItem));
      }

      // Create a new ConcatenatingAudioSource with the new queue.
      _queueAudioSource = ConcatenatingAudioSource(
        children: audioSources,
        shuffleOrder: FinampShuffleOrder(),
      );

      try {
        await _player.setAudioSource(
          _queueAudioSource,
          initialIndex: nextInitialIndex,
        );
      } on PlayerException catch (e) {
        _audioServiceBackgroundTaskLogger
            .severe("Player error code ${e.code}: ${e.message}");
      } on PlayerInterruptedException catch (e) {
        _audioServiceBackgroundTaskLogger
            .warning("Player interrupted: ${e.message}");
      } catch (e) {
        _audioServiceBackgroundTaskLogger
            .severe("Player error ${e.toString()}");
      }
      queue.add(_queueFromSource());

      // Sets the media item for the new queue. This will be whatever is
      // currently playing from the new queue (for example, the first song in
      // an album). If the player is shuffling, set the index to the player's
      // current index. Otherwise, set it to nextInitialIndex. nextInitialIndex
      // is much more stable than the current index as we know the value is set
      // when running this function.
      if (_player.shuffleModeEnabled) {
        if (_player.currentIndex == null) {
          _audioServiceBackgroundTaskLogger.severe(
              "_player.currentIndex is null during onUpdateQueue, not setting new media item");
        } else {
          mediaItem.add(_getQueueItem(_player.currentIndex!));
        }
      } else {
        if (nextInitialIndex == null) {
          _audioServiceBackgroundTaskLogger.severe(
              "nextInitialIndex is null during onUpdateQueue, not setting new media item");
        } else {
          mediaItem.add(_getQueueItem(nextInitialIndex!));
        }
      }

      shuffleNextQueue = false;
      nextInitialIndex = null;
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  @override
  Future<void> skipToPrevious() async {
    try {
      if (!_player.hasPrevious || _player.position.inSeconds >= 5) {
        await _player.seek(Duration.zero, index: _player.currentIndex);
      } else {
        await _player.seek(Duration.zero, index: _player.previousIndex);
      }
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  @override
  Future<void> skipToNext() async {
    try {
      await _player.seekToNext();
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  Future<void> skipToIndex(int index) async {
    try {
      await _player.seek(Duration.zero, index: index);
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  @override
  Future<void> seek(Duration position) async {
    try {
      await _player.seek(position);
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  Future<void> seekRelative(Duration offset) async {
    try {
      var newPosition = _player.position + offset;
      if (newPosition < Duration.zero) newPosition = Duration.zero;
      final duration = _player.duration;
      if (duration != null && newPosition > duration) newPosition = duration;
      await _player.seek(newPosition);
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    try {
      switch (shuffleMode) {
        case AudioServiceShuffleMode.all:
          await _player.setShuffleModeEnabled(true);
          shuffleNextQueue = true;
          break;
        case AudioServiceShuffleMode.none:
          await _player.setShuffleModeEnabled(false);
          shuffleNextQueue = false;
          break;
        default:
          return Future.error(
              "Unsupported AudioServiceRepeatMode! Recieved ${shuffleMode.toString()}, requires all or none.");
      }
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    try {
      switch (repeatMode) {
        case AudioServiceRepeatMode.all:
          await _player.setLoopMode(LoopMode.all);
          break;
        case AudioServiceRepeatMode.none:
          await _player.setLoopMode(LoopMode.off);
          break;
        case AudioServiceRepeatMode.one:
          await _player.setLoopMode(LoopMode.one);
          break;
        default:
          return Future.error(
            "Unsupported AudioServiceRepeatMode! Received ${repeatMode.toString()}, requires all, none, or one.",
          );
      }
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  @override
  Future<void> removeQueueItemAt(int index) async {
    try {
      await _queueAudioSource.removeAt(index);
      queue.add(_queueFromSource());
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  // ── Android Auto / MediaBrowser browsing ──────────────────────────────────

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    if (_finampUserHelper.currentUser == null) return [];
    try {
      switch (parentMediaId) {
        case _browsableRootId:
          return _getAutoRootItems();
        case _autoPlaylistsId:
          return _getAutoPlaylists();
        case _autoAlbumsId:
          return _getAutoAlbums();
        case _autoArtistsId:
          return _getAutoArtists();
        case _autoFavoritesId:
          return _getAutoFavoriteSongs();
        default:
          if (parentMediaId.startsWith(_autoPlaylistPrefix)) {
            return _getAutoPlaylistSongs(
                parentMediaId.substring(_autoPlaylistPrefix.length));
          } else if (parentMediaId.startsWith(_autoAlbumPrefix)) {
            return _getAutoAlbumSongs(
                parentMediaId.substring(_autoAlbumPrefix.length));
          } else if (parentMediaId.startsWith(_autoArtistPrefix)) {
            return _getAutoArtistSongs(
                parentMediaId.substring(_autoArtistPrefix.length));
          }
          return [];
      }
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe('getChildren error: $e');
      return [];
    }
  }

  @override
  Future<void> playMediaItem(MediaItem mediaItem) async {
    try {
      final parentId = mediaItem.extras?['autoParentId'] as String?;
      final parentType = mediaItem.extras?['autoParentType'] as String?;
      final startIndex = (mediaItem.extras?['autoQueueIndex'] as int?) ?? 0;

      List<BaseItemDto>? songs;

      if (parentType == 'playlist') {
        songs = await _jellyfinApiHelper.getItems(
          parentItem: BaseItemDto(id: parentId!, type: 'Playlist'),
          includeItemTypes: 'Audio',
          isGenres: false,
        );
      } else if (parentType == 'album') {
        songs = await _jellyfinApiHelper.getItems(
          parentItem: BaseItemDto(id: parentId!),
          includeItemTypes: 'Audio',
          isGenres: false,
          sortBy: 'ParentIndexNumber,IndexNumber',
        );
      } else if (parentType == 'artist') {
        songs = await _jellyfinApiHelper.getItems(
          parentItem: BaseItemDto(id: parentId!, type: 'MusicArtist'),
          includeItemTypes: 'Audio',
          isGenres: false,
          sortBy: 'Random',
          limit: 100,
        );
      } else if (parentType == 'favorites') {
        songs = await _jellyfinApiHelper.getItems(
          parentItem: _finampUserHelper.currentUser!.currentView,
          includeItemTypes: 'Audio',
          isGenres: false,
          filters: 'IsFavorite',
          sortBy: 'Random',
        );
      } else {
        final rawJson = mediaItem.extras?['itemJson'];
        if (rawJson != null) {
          songs = [BaseItemDto.fromJson(Map<String, dynamic>.from(rawJson as Map))];
        }
      }

      if (songs != null && songs.isNotEmpty) {
        final queue = <MediaItem>[];
        for (final song in songs) {
          try {
            queue.add(await _buildPlaybackMediaItem(song));
          } catch (e) {
            _audioServiceBackgroundTaskLogger
                .warning('Skipping song ${song.id}: $e');
          }
        }
        if (queue.isEmpty) return;
        setNextInitialIndex(startIndex.clamp(0, queue.length - 1));
        await updateQueue(queue);
        await setShuffleMode(AudioServiceShuffleMode.none);
        play();
      }
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe('playMediaItem error: $e');
    }
  }

  @override
  Future<List<MediaItem>> search(
    String query, [
    Map<String, dynamic>? extras,
  ]) async {
    if (_finampUserHelper.currentUser == null) return [];
    try {
      final songs = await _jellyfinApiHelper.getItems(
        searchTerm: query,
        parentItem: _finampUserHelper.currentUser!.currentView,
        includeItemTypes: 'Audio',
        isGenres: false,
        recursive: true,
        limit: 50,
      );
      if (songs == null) return [];
      return songs
          .map((song) => _buildBrowseSongItem(song, 0, null, null))
          .toList();
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe('search error: $e');
      return [];
    }
  }

  List<MediaItem> _getAutoRootItems() {
    const listHint = 1; // CONTENT_STYLE_LIST_ITEM_HINT_VALUE
    const gridHint = 2; // CONTENT_STYLE_GRID_ITEM_HINT_VALUE
    return [
      MediaItem(
        id: _autoPlaylistsId,
        title: 'Playlists',
        playable: false,
        extras: {
          'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT': listHint,
          'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': listHint,
        },
      ),
      MediaItem(
        id: _autoAlbumsId,
        title: 'Albums',
        playable: false,
        extras: {
          'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT': gridHint,
          'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': listHint,
        },
      ),
      MediaItem(
        id: _autoArtistsId,
        title: 'Artists',
        playable: false,
        extras: {
          'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT': listHint,
          'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': listHint,
        },
      ),
      MediaItem(
        id: _autoFavoritesId,
        title: 'Favorites',
        playable: false,
        extras: {
          'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT': listHint,
          'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': listHint,
        },
      ),
    ];
  }

  Future<List<MediaItem>> _getAutoPlaylists() async {
    final view = _finampUserHelper.currentUser!.currentView;
    final playlists = await _jellyfinApiHelper.getItems(
      parentItem: view,
      includeItemTypes: 'Playlist',
      isGenres: false,
      sortBy: 'SortName',
    );
    if (playlists == null) return [];
    return playlists
        .map((p) => MediaItem(
              id: '$_autoPlaylistPrefix${p.id}',
              title: p.name ?? 'Unknown Playlist',
              artUri: _jellyfinApiHelper.getImageUrl(item: p),
              playable: false,
              extras: const {
                'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': 1,
              },
            ))
        .toList();
  }

  Future<List<MediaItem>> _getAutoPlaylistSongs(String playlistId) async {
    final songs = await _jellyfinApiHelper.getItems(
      parentItem: BaseItemDto(id: playlistId, type: 'Playlist'),
      includeItemTypes: 'Audio',
      isGenres: false,
    );
    if (songs == null) return [];
    return List.generate(
        songs.length, (i) => _buildBrowseSongItem(songs[i], i, playlistId, 'playlist'));
  }

  Future<List<MediaItem>> _getAutoAlbums() async {
    final view = _finampUserHelper.currentUser!.currentView;
    final albums = await _jellyfinApiHelper.getItems(
      parentItem: view,
      includeItemTypes: 'MusicAlbum',
      isGenres: false,
      sortBy: 'SortName',
      recursive: true,
    );
    if (albums == null) return [];
    return albums
        .map((a) => MediaItem(
              id: '$_autoAlbumPrefix${a.id}',
              title: a.name ?? 'Unknown Album',
              artist: a.albumArtist,
              artUri: _jellyfinApiHelper.getImageUrl(item: a),
              playable: false,
              extras: const {
                'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': 1,
              },
            ))
        .toList();
  }

  Future<List<MediaItem>> _getAutoAlbumSongs(String albumId) async {
    final songs = await _jellyfinApiHelper.getItems(
      parentItem: BaseItemDto(id: albumId),
      includeItemTypes: 'Audio',
      isGenres: false,
      sortBy: 'ParentIndexNumber,IndexNumber',
    );
    if (songs == null) return [];
    return List.generate(
        songs.length, (i) => _buildBrowseSongItem(songs[i], i, albumId, 'album'));
  }

  Future<List<MediaItem>> _getAutoArtists() async {
    final view = _finampUserHelper.currentUser!.currentView;
    final artists = await _jellyfinApiHelper.getItems(
      parentItem: view,
      includeItemTypes: 'MusicArtist',
      isGenres: false,
      sortBy: 'SortName',
    );
    if (artists == null) return [];
    return artists
        .map((a) => MediaItem(
              id: '$_autoArtistPrefix${a.id}',
              title: a.name ?? 'Unknown Artist',
              artUri: _jellyfinApiHelper.getImageUrl(item: a),
              playable: false,
              extras: const {
                'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': 1,
              },
            ))
        .toList();
  }

  Future<List<MediaItem>> _getAutoArtistSongs(String artistId) async {
    final songs = await _jellyfinApiHelper.getItems(
      parentItem: BaseItemDto(id: artistId, type: 'MusicArtist'),
      includeItemTypes: 'Audio',
      isGenres: false,
      sortBy: 'Random',
      limit: 100,
    );
    if (songs == null) return [];
    return List.generate(
        songs.length, (i) => _buildBrowseSongItem(songs[i], i, artistId, 'artist'));
  }

  Future<List<MediaItem>> _getAutoFavoriteSongs() async {
    final songs = await _jellyfinApiHelper.getItems(
      parentItem: _finampUserHelper.currentUser!.currentView,
      includeItemTypes: 'Audio',
      isGenres: false,
      filters: 'IsFavorite',
      sortBy: 'Random',
    );
    if (songs == null) return [];
    return List.generate(
        songs.length, (i) => _buildBrowseSongItem(songs[i], i, null, 'favorites'));
  }

  MediaItem _buildBrowseSongItem(
    BaseItemDto song,
    int index,
    String? parentId,
    String? parentType,
  ) {
    return MediaItem(
      id: 'aa_song:${song.id}',
      title: song.name ?? 'Unknown',
      album: song.album,
      artist: song.artists?.join(', ') ?? song.albumArtist,
      artUri: _jellyfinApiHelper.getImageUrl(item: song),
      duration: song.runTimeTicks == null
          ? null
          : Duration(microseconds: song.runTimeTicks! ~/ 10),
      playable: true,
      extras: {
        'itemJson': song.toJson(),
        'shouldTranscode': FinampSettingsHelper.finampSettings.shouldTranscode,
        'isOffline': FinampSettingsHelper.finampSettings.isOffline,
        'downloadedSongJson': null,
        if (parentId != null) 'autoParentId': parentId,
        if (parentType != null) 'autoParentType': parentType,
        'autoQueueIndex': index,
        'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': 1,
      },
    );
  }

  Future<MediaItem> _buildPlaybackMediaItem(BaseItemDto item) async {
    final downloadedSong = _downloadsHelper.getDownloadedSong(item.id);
    final isDownloaded = downloadedSong == null
        ? false
        : await _downloadsHelper.verifyDownloadedSong(downloadedSong);

    return MediaItem(
      id: item.id,
      album: item.album ?? 'Unknown Album',
      artist: item.artists?.join(', ') ?? item.albumArtist,
      artUri: _downloadsHelper.getDownloadedImage(item)?.file.uri ??
          _jellyfinApiHelper.getImageUrl(item: item),
      title: item.name ?? 'Unknown',
      duration: item.runTimeTicks == null
          ? null
          : Duration(microseconds: item.runTimeTicks! ~/ 10),
      extras: {
        'itemJson': item.toJson(),
        'shouldTranscode': FinampSettingsHelper.finampSettings.shouldTranscode,
        'downloadedSongJson': isDownloaded ? downloadedSong.toJson() : null,
        'isOffline': FinampSettingsHelper.finampSettings.isOffline,
      },
    );
  }

  // ──────────────────────────────────────────────────────────────────────────

  /// Report track changes to the Jellyfin Server if the user is not offline.
  Future<void> onTrackChanged(
    MediaItem currentItem,
    PlaybackState currentState,
    MediaItem? previousItem,
    PlaybackState? previousState,
  ) async {
    final isOffline = FinampSettingsHelper.finampSettings.isOffline;

    if (previousItem != null &&
        previousState != null &&
        // don't submit stop events for idle tracks (at position 0 and not playing)
        (previousState.playing ||
            previousState.updatePosition != Duration.zero)) {
      if (!isOffline) {
        final playbackData = generatePlaybackProgressInfoFromState(
          previousItem,
          previousState,
        );

        if (playbackData != null) {
          try {
            await _jellyfinApiHelper.stopPlaybackProgress(playbackData);
          } catch (e) {
            _offlineListenLogHelper.logOfflineListen(previousItem);
          }
        }
      } else {
        _offlineListenLogHelper.logOfflineListen(previousItem);
      }
    }

    if (!isOffline) {
      final playbackData = generatePlaybackProgressInfoFromState(
        currentItem,
        currentState,
      );

      if (playbackData != null) {
        await _jellyfinApiHelper.reportPlaybackStart(playbackData);
      }
    }
  }

  /// Generates PlaybackProgressInfo for the supplied item and player info.
  PlaybackProgressInfo? generatePlaybackProgressInfo(
    MediaItem item, {
    required bool isPaused,
    required bool isMuted,
    required Duration playerPosition,
    required String repeatMode,
    required bool includeNowPlayingQueue,
  }) {
    try {
      return PlaybackProgressInfo(
        itemId: item.extras!["itemJson"]["Id"],
        isPaused: isPaused,
        isMuted: isMuted,
        positionTicks: playerPosition.inMicroseconds * 10,
        repeatMode: repeatMode,
        playMethod: item.extras!["shouldTranscode"] ?? false
            ? "Transcode"
            : "DirectPlay",
        // We don't send the queue since it seems useless and it can cause
        // issues with large queues.
        // https://github.com/jmshrv/finamp/issues/387

        // nowPlayingQueue: includeNowPlayingQueue
        //     ? _queueFromSource()
        //         .map(
        //           (e) => QueueItem(
        //               id: e.extras!["itemJson"]["Id"], playlistItemId: e.id),
        //         )
        //         .toList()
        //     : null,
      );
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      rethrow;
    }
  }

  /// Generates PlaybackProgressInfo from current player info.
  /// Returns null if _queue is empty.
  /// If an item is not supplied, the current queue index will be used.
  PlaybackProgressInfo? generateCurrentPlaybackProgressInfo() {
    final currentIndex = _player.currentIndex;
    if (_queueAudioSource.length == 0 || currentIndex == null) {
      // This function relies on _queue having items,
      // so we return null if it's empty or no index is played
      // and no custom item was passed to avoid more errors.
      return null;
    }
    final item = _getQueueItem(currentIndex);

    return generatePlaybackProgressInfo(
      item,
      isPaused: !_player.playing,
      isMuted: _player.volume == 0,
      playerPosition: _player.position,
      repeatMode: _jellyfinRepeatModeFromLoopMode(_player.loopMode),
      includeNowPlayingQueue: false,
    );
  }

  /// Generates PlaybackProgressInfo for the supplied item and playback state.
  PlaybackProgressInfo? generatePlaybackProgressInfoFromState(
    MediaItem item,
    PlaybackState state,
  ) {
    final duration = item.duration;
    return generatePlaybackProgressInfo(
      item,
      isPaused: !state.playing,
      // always consider as unmuted
      isMuted: false,
      // ensure the (extrapolated) position doesn't exceed the duration
      playerPosition: duration != null && state.position > duration
          ? duration
          : state.position,
      repeatMode: _jellyfinRepeatModeFromRepeatMode(state.repeatMode),
      includeNowPlayingQueue: true,
    );
  }

  void setNextInitialIndex(int index) {
    nextInitialIndex = index;
  }

  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    // When we're moving an item forwards, we need to reduce newIndex by 1
    // to account for the current item being removed before re-insertion.
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    await _queueAudioSource.move(oldIndex, newIndex);
    queue.add(_queueFromSource());
    _audioServiceBackgroundTaskLogger.log(Level.INFO, "Published queue");
  }

  /// Sets the sleep timer with the given [duration].
  Timer setSleepTimer(Duration duration) {
    _sleepTimerIsSet = true;
    _sleepTimerDuration = duration;

    _sleepTimer.value = Timer(duration, () async {
      _sleepTimer.value = null;
      return await pause();
    });
    return _sleepTimer.value!;
  }

  /// Cancels the sleep timer and clears it.
  void clearSleepTimer() {
    _sleepTimerIsSet = false;
    _sleepTimerDuration = Duration.zero;

    _sleepTimer.value?.cancel();
    _sleepTimer.value = null;
  }

  /// Transform a just_audio event into an audio_service state.
  ///
  /// This method is used from the constructor. Every event received from the
  /// just_audio player will be transformed into an audio_service state so that
  /// it can be broadcast to audio_service clients.
  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 3],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: event.currentIndex,
      shuffleMode: _player.shuffleModeEnabled
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
      repeatMode: _audioServiceRepeatMode(_player.loopMode),
    );
  }

  Future<void> _updatePlaybackProgress() async {
    try {
      JellyfinApiHelper jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();

      final playbackInfo = generateCurrentPlaybackProgressInfo();
      if (playbackInfo != null) {
        await jellyfinApiHelper.updatePlaybackProgress(playbackInfo);
      }
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  MediaItem _getQueueItem(int index) {
    return _queueAudioSource.sequence[index].tag as MediaItem;
  }

  List<MediaItem> _queueFromSource() {
    return _queueAudioSource.sequence.map((e) => e.tag as MediaItem).toList();
  }

  /// Syncs the list of MediaItems (_queue) with the internal queue of the player.
  /// Called by onAddQueueItem and onUpdateQueue.
  Future<AudioSource> _mediaItemToAudioSource(MediaItem mediaItem) async {
    if (mediaItem.extras!["downloadedSongJson"] == null) {
      // If DownloadedSong wasn't passed, we assume that the item is not
      // downloaded.

      // If offline, we throw an error so that we don't accidentally stream from
      // the internet. See the big comment in _songUri() to see why this was
      // passed in extras.
      if (mediaItem.extras!["isOffline"]) {
        return Future.error(
            "Offline mode enabled but downloaded song not found.");
      } else {
        // Video items must always use the HLS audio path — direct play returns
        // the full video container which just_audio can't handle for audio-only.
        final isVideoItem =
            mediaItem.extras!["itemJson"]["Type"] == "Video";
        if (mediaItem.extras!["shouldTranscode"] == true || isVideoItem) {
          return HlsAudioSource(await _songUri(mediaItem), tag: mediaItem);
        } else {
          return AudioSource.uri(await _songUri(mediaItem), tag: mediaItem);
        }
      }
    } else {
      // We have to deserialize this because Dart is stupid and can't handle
      // sending classes through isolates.
      final downloadedSong =
          DownloadedSong.fromJson(mediaItem.extras!["downloadedSongJson"]);

      // Path verification and stuff is done in AudioServiceHelper, so this path
      // should be valid.
      final downloadUri = Uri.file(downloadedSong.file.path);
      return AudioSource.uri(downloadUri, tag: mediaItem);
    }
  }

  Future<Uri> _songUri(MediaItem mediaItem) async {
    // We need the platform to be Android or iOS to get device info
    assert(Platform.isAndroid || Platform.isIOS,
        "_songUri() only supports Android and iOS");

    // When creating the MediaItem (usually in AudioServiceHelper), we specify
    // whether or not to transcode. We used to pull from FinampSettings here,
    // but since audio_service runs in an isolate (or at least, it does until
    // 0.18), the value would be wrong if changed while a song was playing since
    // Hive is bad at multi-isolate stuff.

    final parsedBaseUrl = Uri.parse(_finampUserHelper.currentUser!.baseUrl);

    List<String> builtPath = List.from(parsedBaseUrl.pathSegments);

    Map<String, String> queryParameters =
        Map.from(parsedBaseUrl.queryParameters);

    // We include the user token as a query parameter because just_audio used to
    // have issues with headers in HLS, and this solution still works fine
    queryParameters["ApiKey"] = _finampUserHelper.currentUser!.accessToken;

    final isVideoItem = mediaItem.extras!["itemJson"]["Type"] == "Video";
    if (mediaItem.extras!["shouldTranscode"] || isVideoItem) {
      builtPath.addAll([
        "Audio",
        mediaItem.extras!["itemJson"]["Id"],
        "main.m3u8",
      ]);

      queryParameters.addAll({
        "audioCodec": "aac",
        // Ideally we'd use 48kHz when the source is, realistically it doesn't
        // matter too much
        "audioSampleRate": "44100",
        "maxAudioBitDepth": "16",
        "audioBitRate":
            FinampSettingsHelper.finampSettings.transcodeBitrate.toString(),
      });
    } else {
      builtPath.addAll([
        "Items",
        mediaItem.extras!["itemJson"]["Id"],
        "File",
      ]);
    }

    return Uri(
      host: parsedBaseUrl.host,
      port: parsedBaseUrl.port,
      scheme: parsedBaseUrl.scheme,
      userInfo: parsedBaseUrl.userInfo,
      pathSegments: builtPath,
      queryParameters: queryParameters,
    );
  }
}

AudioServiceRepeatMode _audioServiceRepeatMode(LoopMode loopMode) {
  switch (loopMode) {
    case LoopMode.off:
      return AudioServiceRepeatMode.none;
    case LoopMode.one:
      return AudioServiceRepeatMode.one;
    case LoopMode.all:
      return AudioServiceRepeatMode.all;
  }
}

String _jellyfinRepeatModeFromLoopMode(LoopMode loopMode) {
  switch (loopMode) {
    case LoopMode.off:
      return "RepeatNone";
    case LoopMode.one:
      return "RepeatOne";
    case LoopMode.all:
      return "RepeatAll";
  }
}

String _jellyfinRepeatModeFromRepeatMode(AudioServiceRepeatMode repeatMode) {
  switch (repeatMode) {
    case AudioServiceRepeatMode.none:
      return "RepeatNone";
    case AudioServiceRepeatMode.one:
      return "RepeatOne";
    case AudioServiceRepeatMode.all:
    case AudioServiceRepeatMode.group:
      return "RepeatAll";
  }
}