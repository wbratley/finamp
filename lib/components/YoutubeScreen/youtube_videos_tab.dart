import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../models/jellyfin_models.dart';
import '../../services/finamp_user_helper.dart';
import '../../services/jellyfin_api_helper.dart';
import '../error_snackbar.dart';
import 'youtube_video_progress_tile.dart';

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

      // Step 1: fetch only the direct child folders (channel level).
      // Pinchflat structure: Library/<Channel>/<Date Subfolder>/<video>
      // recursive: false prevents date subfolders from appearing as channels.
      final channels = await _jellyfinApiHelper.getItems(
        parentItem: currentView,
        includeItemTypes: 'Folder',
        sortBy: 'SortName',
        sortOrder: 'Ascending',
        isGenres: false,
        recursive: false,
        limit: 10000,
        startIndex: 0,
      );

      if (channels == null || channels.isEmpty) {
        setState(() {
          _isLoading = false;
          _flatList = [];
        });
        return;
      }

      // Step 2: fetch each channel's videos in parallel (recursive so date
      // subfolders are traversed automatically).
      final videoLists = await Future.wait(
        channels.map((channel) => _jellyfinApiHelper.getItems(
              parentItem: channel,
              includeItemTypes: 'Video',
              sortBy: 'PremiereDate',
              sortOrder: 'Descending',
              isGenres: false,
              limit: 10000,
              startIndex: 0,
            )),
      );

      // Step 3: build flat list — channel header followed by its videos.
      final List<Object> flatList = [];
      for (int i = 0; i < channels.length; i++) {
        final channel = channels[i];
        final videos = videoLists[i] ?? [];
        if (videos.isEmpty) continue;

        // Stamp channel name so SongListTile subtitle renders correctly
        for (final video in videos) {
          video.channelName = channel.name;
        }

        flatList.add(_ChannelHeader(
          name: channel.name ?? 'Unknown Channel',
          count: videos.length,
        ));
        flatList.addAll(videos);
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
            return VideoProgressTile(item: item);
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
