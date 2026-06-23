import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../models/jellyfin_models.dart';
import '../../services/finamp_user_helper.dart';
import '../../services/jellyfin_api_helper.dart';
import '../../services/music_player_background_task.dart';
import '../error_snackbar.dart';
import 'youtube_video_progress_tile.dart';

class YoutubeContinueTab extends StatefulWidget {
  const YoutubeContinueTab({Key? key}) : super(key: key);

  @override
  State<YoutubeContinueTab> createState() => _YoutubeContinueTabState();
}

class _YoutubeContinueTabState extends State<YoutubeContinueTab>
    with AutomaticKeepAliveClientMixin {
  final _jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
  final _finampUserHelper = GetIt.instance<FinampUserHelper>();
  final _audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();

  bool _isLoading = true;
  List<BaseItemDto> _videos = [];
  StreamSubscription<PlaybackState>? _playbackSubscription;
  bool _wasPlaying = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadVideos();
    _playbackSubscription =
        _audioHandler.playbackState.listen(_onPlaybackStateChanged);
  }

  @override
  void dispose() {
    _playbackSubscription?.cancel();
    super.dispose();
  }

  void _onPlaybackStateChanged(PlaybackState state) {
    final isPlaying = state.playing;
    if (_wasPlaying && !isPlaying) {
      // Playback just stopped/paused — refresh to pick up the latest position.
      _loadVideos();
    }
    _wasPlaying = isPlaying;
  }

  Future<void> _loadVideos() async {
    setState(() => _isLoading = true);
    try {
      final currentView = _finampUserHelper.currentUser?.currentView;
      final videos = await _jellyfinApiHelper.getItems(
        parentItem: currentView,
        includeItemTypes: 'Video',
        filters: 'IsResumable',
        sortBy: 'DatePlayed',
        sortOrder: 'Descending',
        isGenres: false,
        recursive: true,
        limit: 100,
        startIndex: 0,
      );
      setState(() {
        _isLoading = false;
        _videos = videos ?? [];
      });
    } catch (e) {
      errorSnackbar(e, context);
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator.adaptive());
    }

    if (_videos.isEmpty) {
      return const Center(
        child: Text(
          'Nothing in progress yet.\nStart watching a video to resume it here.',
          textAlign: TextAlign.center,
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadVideos,
      child: ListView.builder(
        itemCount: _videos.length,
        itemBuilder: (_, index) => VideoProgressTile(item: _videos[index]),
      ),
    );
  }
}
