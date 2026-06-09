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
      final videos = await _jellyfinApiHelper.getItems(
        parentItem: _finampUserHelper.currentUser?.currentView,
        includeItemTypes: 'Video',
        sortBy: 'ChannelId,PremiereDate',
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

      // Group by channelId, preserving server sort order of channels
      final grouped = <String, List<BaseItemDto>>{};
      final channelOrder = <String>[];

      for (final video in videos) {
        final key = video.channelId ?? 'unknown';
        if (!grouped.containsKey(key)) {
          grouped[key] = [];
          channelOrder.add(key);
        }
        grouped[key]!.add(video);
      }

      final List<Object> flatList = [];
      for (final channelId in channelOrder) {
        final channelVideos = grouped[channelId]!;
        flatList.add(_ChannelHeader(
          name: channelVideos.first.channelName ?? 'Unknown Channel',
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
