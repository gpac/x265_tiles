#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 /path/to/x265 /path/to/TAppDecoder" >&2
    exit 2
fi

x265=$1
decoder=$2
tmp=$(mktemp -d)
trap 'rm -f "$tmp/input.yuv" "$tmp/recon.yuv" "$tmp/decoded.yuv" "$tmp/output.hevc" "$tmp/merged.hevc" "$tmp/tiles.mp4" "$tmp/full.md5" "$tmp/tile.md5" "$tmp/trace.log" "$tmp/encoder.log" "$tmp/decoder.log"; rmdir "$tmp"' EXIT

ffmpeg -y -v error -f lavfi -i 'testsrc2=size=768x384:rate=30,scroll=horizontal=0.07:vertical=0.02' \
    -frames:v 48 -pix_fmt yuv420p -f rawvideo "$tmp/input.yuv"

for mode in mcts fast multi wpp rd6 nonuniform shared shared-wpp tile-slices; do
    columns=256,256
    tiles='0 1 2 3 4 5'
    case "$mode" in
      mcts) options='--frames 48 --preset medium --pools none --ctu 64 --no-wpp --tile-rows 2 --mcts' ;;
      fast) options='--frames 16 --preset ultrafast --bframes 0 --pools none --ctu 64 --no-wpp --tile-rows 2 --mcts' ;;
      multi) options='--frames 16 --preset medium --pools none --ctu 32 --no-wpp --tile-rows 128,256 --slices-per-tile 3 --mcts' ;;
      wpp) options='--frames 16 --preset medium --pools 2 --ctu 32 --wpp --tile-rows 128,256 --slices-per-tile 3 --mcts --crf 28 --vbv-maxrate 1000 --vbv-bufsize 2000' ;;
      rd6) options='--frames 8 --preset medium --rd 6 --pools none --ctu 64 --no-wpp --tile-rows 2 --mcts' ;;
      nonuniform) columns=256,512; tiles='0 1 2 3'; options='--frames 16 --preset medium --pools none --ctu 64 --no-wpp --tile-rows 128,256 --mcts' ;;
      shared) options='--frames 16 --preset medium --pools none --ctu 64 --no-wpp --tile-rows 2 --no-tile-slices' ;;
      shared-wpp) options='--frames 16 --preset medium --pools 2 --ctu 32 --wpp --tile-rows 128,256 --no-tile-slices' ;;
      tile-slices) options='--frames 16 --preset medium --pools none --ctu 64 --no-wpp --tile-rows 2 --tile-slices' ;;
    esac
    "$x265" --input "$tmp/input.yuv" --input-res 768x384 --fps 30 \
        --temporal-mvp --sao --tile-columns "$columns" $options \
        --recon "$tmp/recon.yuv" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
    "$decoder" -b "$tmp/output.hevc" -o "$tmp/decoded.yuv" >"$tmp/decoder.log" 2>&1
    cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
    ffmpeg -hide_banner -loglevel trace -i "$tmp/output.hevc" \
        -c:v copy -bsf:v trace_headers -f null - 2>"$tmp/trace.log"
    grep -q 'sps_temporal_mvp_enabled_flag.* = 1' "$tmp/trace.log"
    grep -q 'slice_temporal_mvp_enabled_flag.* = 1' "$tmp/trace.log"
    case "$mode" in
      shared|shared-wpp|tile-slices)
        echo "PASS: $mode tiled TMVP reference decode"
        continue ;;
    esac
    gpac -i "$tmp/output.hevc" hevcsplit -o "$tmp/tiles.mp4"
    for tile in $tiles; do
        if [ "$mode" = nonuniform ]; then
            if [ $((tile % 2)) -eq 0 ]; then x=0; width=256; else x=256; width=512; fi
            if [ "$tile" -lt 2 ]; then y=0; height=128; else y=128; height=256; fi
        else
            x=$((tile % 3 * 256))
            width=256
            if [ "$mode" = wpp ] || [ "$mode" = multi ]; then
                if [ "$tile" -lt 3 ]; then y=0; height=128; else y=128; height=256; fi
            else
                y=$((tile / 3 * 192))
                height=192
            fi
        fi
        ffmpeg -y -v error -f rawvideo -pixel_format yuv420p -video_size 768x384 \
            -framerate 30 -i "$tmp/recon.yuv" -vf "crop=$width:$height:$x:$y" \
            -f framemd5 "$tmp/full.md5"
        ffmpeg -y -v error -i "$tmp/tiles.mp4" -map "0:v:$tile" -f framemd5 "$tmp/tile.md5"
        cmp "$tmp/full.md5" "$tmp/tile.md5"
    done
    gpac -i "$tmp/tiles.mp4" hevcmerge:mrows -o "$tmp/merged.hevc"
    "$decoder" -b "$tmp/merged.hevc" -o "$tmp/decoded.yuv" >"$tmp/decoder.log" 2>&1
    cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
    echo "PASS: $mode TMVP decode, split and merge"
done
