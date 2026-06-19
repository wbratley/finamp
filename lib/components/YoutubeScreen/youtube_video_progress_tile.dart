import 'package:flutter/material.dart';

import '../../models/jellyfin_models.dart';
import '../AlbumScreen/song_list_tile.dart';

class VideoProgressTile extends StatelessWidget {
  const VideoProgressTile({Key? key, required this.item}) : super(key: key);

  final BaseItemDto item;

  @override
  Widget build(BuildContext context) {
    final runTimeTicks = item.runTimeTicks ?? 0;
    final positionTicks = item.userData?.playbackPositionTicks ?? 0;
    final played = item.userData?.played ?? false;

    final progress = (runTimeTicks > 0 && positionTicks > 0)
        ? (positionTicks / runTimeTicks).clamp(0.0, 1.0)
        : 0.0;
    final showBar = progress > 0 && !played;

    return Stack(
      children: [
        SongListTile(item: item, isSong: true),
        if (showBar)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 2,
              backgroundColor: Colors.transparent,
              color: Theme.of(context).colorScheme.primary.withOpacity(0.7),
            ),
          ),
        if (played)
          Positioned(
            left: 54,
            top: 6,
            child: Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.check,
                size: 11,
                color: Theme.of(context).colorScheme.onPrimary,
              ),
            ),
          ),
      ],
    );
  }
}
