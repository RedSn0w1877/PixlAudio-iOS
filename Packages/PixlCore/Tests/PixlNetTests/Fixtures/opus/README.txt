sine-440hz-3s.webm: ffmpeg 8.1 -f lavfi -i sine=frequency=440:duration=3 -ac 2 -c:a libopus -b:a 64k -cues_to_front 1 -f webm
(Cues before the Clusters like YouTube itag 251; the last block is a BlockGroup with DiscardPadding 13.5 ms.)
ffmpeg decodes it to exactly 144000 frames. OpusRemuxTests builds the other layouts from its packets.
