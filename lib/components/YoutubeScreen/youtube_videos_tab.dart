import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../models/jellyfin_models.dart';
import '../../services/finamp_user_helper.dart';
import '../../services/jellyfin_api_helper.dart';
import '../AlbumScreen/song_list_tile.dart';
import '../error_snackbar.dart';

class YoutubeVideosTab extends StatefulWidget {
  const YoutubeVideosTab({Key? key}) : super(key: key);

  @override
  State<YoutubeVideosTab> createState() => _YoutubeVideosTabState();
}

class _YoutubeVideosTabState extends State<YoutubeVideosTab>
    with AutomaticKeepAliveClientMixin {
  final _jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
  final _finampUserHelper = GetIt.instance<FinampUserHelper>();

  bool _isLoading = true;
  // Each entry is either a _ChannelHeader or a BaseItemDto (video)
  List<Object> _flatList = [];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadVideos();
  }

  Future<void> _loadVideos() async {
    setState(() => _isLoading = true);
    try {
      final currentView = _finampUserHelper.currentUser?.currentView;

      // Step 1: fetch channel folders to build a folderId -> name map
      final folders = await _jellyfinApiHelper.getItems(
        parentItem: currentView,
        includeItemTypes: 'Folder',
        isGenres: false,
        limit: 10000,
        startIndex: 0,
      );

      final folderNames = <String, String>{};
      for (final folder in folders ?? []) {
        if (folder.id != null) {
          folderNames[folder.id!] = folder.name ?? 'Unknown Channel';
        }
      }

      // Step 2: fetch all videos sorted by date descending
      final videos = await _jellyfinApiHelper.getItems(
        parentItem: currentView,
        includeItemTypes: 'Video',
        sortBy: 'PremiereDate',
        sortOrder: 'Descending',
        isGenres: false,
        limit: 10000,
        startIndex: 0,
      );

      if (videos == null || videos.isEmpty) {
        setState(() {
          _isLoading = false;
          _flatList = [];
        });
        return;
      }

      // Stamp each video with its channel name so SongListTile can display it
      for (final video in videos) {
        video.channelName = folderNames[video.parentId];
      }

      // Group videos by parentId (= channel folder)
      final grouped = <String, List<BaseItemDto>>{};
      for (final video in videos) {
        final key = video.parentId ?? 'unknown';
        grouped.putIfAbsent(key, () => []).add(video);
      }

      // Sort groups alphabetically by channel name
      final sortedKeys = grouped.keys.toList()
        ..sort((a, b) =>
            (folderNames[a] ?? a).toLowerCase().compareTo(
                  (folderNames[b] ?? b).toLowerCase(),
                ));

      final List<Object> flatList = [];
      for (final folderId in sortedKeys) {
        final channelVideos = grouped[folderId]!;
        flatList.add(_ChannelHeader(
          name: folderNames[folderId] ?? 'Unknown Channel',
          count: channelVideos.length,
        ));
        flatList.addAll(channelVideos);
      }

      setState(() {
        _isLoading = false;
        _flatList = flatList;
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

    if (_flatList.isEmpty) {
      return const Center(child: Text('No videos found.'));
    }

    return RefreshIndicator(
      onRefresh: _loadVideos,
      child: ListView.builder(
        itemCount: _flatList.length,
        itemBuilder: (context, index) {
          final item = _flatList[index];
          if (item is _ChannelHeader) {
            return _ChannelHeaderTile(header: item);
          } else if (item is BaseItemDto) {
            return SongListTile(item: item, isSong: true);
          }
          return const SizedBox.shrink();
        },
      ),
    );
  }
}

class _ChannelHeader {
  final String name;
  final int count;
  const _ChannelHeader({required this.name, required this.count});
}

class _ChannelHeaderTile extends StatelessWidget {
  const _ChannelHeaderTile({required this.header});

  final _ChannelHeader header;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              header.name,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '${header.count}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}
