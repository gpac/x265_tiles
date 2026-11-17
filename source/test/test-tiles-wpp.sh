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

ffmpeg -y -v error -f lavfi -i 'testsrc2=size=770x386:rate=5,scroll=horizontal=0.02:vertical=0.01' \
    -frames:v 4 -pix_fmt yuv420p -f rawvideo "$tmp/input.yuv"
for mode in shared separate; do
    if [ "$mode" = shared ]; then
        slice_options="--no-tile-slices"
    else
        slice_options="--slices-per-tile 3 --mcts"
    fi
    "$x265" --input "$tmp/input.yuv" --input-res 770x386 --fps 5 \
        --frames 4 --preset medium --pools 2 --ctu 32 --wpp --sao \
        --deblock=0:0 --no-temporal-mvp --tile-columns 256,256 --tile-rows 128,128 \
        $slice_options --recon "$tmp/recon.yuv" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
    "$decoder" -b "$tmp/output.hevc" -o "$tmp/decoded.yuv" >"$tmp/decoder.log" 2>&1
    cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
    ffmpeg -hide_banner -loglevel trace -i "$tmp/output.hevc" \
        -c:v copy -bsf:v trace_headers -f null - 2>"$tmp/trace.log"
    grep -q 'general_profile_idc.* = 5' "$tmp/trace.log"
    for constraint in 14bit 12bit 10bit 8bit; do
        grep -q "general_max_${constraint}_constraint_flag.* = 1" "$tmp/trace.log"
    done
    for constraint in 422chroma 420chroma monochrome; do
        grep -q "general_max_${constraint}_constraint_flag.* = 0" "$tmp/trace.log"
    done
    grep -q 'general_intra_constraint_flag.* = 0' "$tmp/trace.log"
    grep -q 'general_one_picture_only_constraint_flag.* = 0' "$tmp/trace.log"
    grep -q 'general_lower_bit_rate_constraint_flag.* = 1' "$tmp/trace.log"
    grep -q 'entropy_coding_sync_enabled_flag.* = 1' "$tmp/trace.log"
    if [ "$mode" = shared ]; then tile_filter=1; else tile_filter=0; fi
    grep -q "loop_filter_across_tiles_enabled_flag.* = $tile_filter" "$tmp/trace.log"
    grep -q 'num_entry_point_offsets.* = [1-9]' "$tmp/trace.log"
    grep -q 'column_width_minus1\[0\].* = 7$' "$tmp/trace.log"
    grep -q 'column_width_minus1\[1\].* = 7$' "$tmp/trace.log"
    grep -q 'row_height_minus1\[0\].* = 3$' "$tmp/trace.log"
    grep -q 'row_height_minus1\[1\].* = 3$' "$tmp/trace.log"
    count=$(grep -c 'first_slice_segment_in_pic_flag' "$tmp/trace.log")
    if [ "$mode" = shared ]; then
        [ "$count" -eq 4 ]
        echo "PASS: shared-slice tiled WPP reference decode"
        continue
    fi
    [ "$count" -eq 108 ]
    gpac -i "$tmp/output.hevc" hevcsplit -o "$tmp/tiles.mp4"
    for tile in 0 1 2 3 4 5 6 7 8; do
        case $((tile % 3)) in
          0) x=0; width=256 ;;
          1) x=256; width=256 ;;
          2) x=512; width=258 ;;
        esac
        case $((tile / 3)) in
          0) y=0; height=128 ;;
          1) y=128; height=128 ;;
          2) y=256; height=130 ;;
        esac
        ffmpeg -y -v error -f rawvideo -pixel_format yuv420p -video_size 770x386 \
            -framerate 5 -i "$tmp/recon.yuv" -vf "crop=$width:$height:$x:$y" \
            -f framemd5 "$tmp/full.md5"
        ffmpeg -y -v error -i "$tmp/tiles.mp4" -map "0:v:$tile" -f framemd5 "$tmp/tile.md5"
        cmp "$tmp/full.md5" "$tmp/tile.md5"
    done

    gpac -i "$tmp/tiles.mp4" hevcmerge:mrows -o "$tmp/merged.hevc"
    "$decoder" -b "$tmp/merged.hevc" -o "$tmp/decoded.yuv" >"$tmp/decoder.log" 2>&1
    cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
    echo "PASS: multi-slice tiled WPP split and merge"
done

for options in '--pools none' '--pools 2 --profile main'; do
    if "$x265" --input "$tmp/input.yuv" --input-res 770x386 --fps 5 \
        --frames 1 --preset ultrafast --ctu 32 --wpp --no-temporal-mvp \
        --tile-columns 2 $options --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1; then
        echo "Incompatible tiled WPP configuration accepted: $options" >&2
        exit 1
    fi
    case "$options" in
      *'--profile'*) grep -q 'automatically selected high-throughput profile' "$tmp/encoder.log" ;;
      *) grep -q 'tiles with WPP require a thread pool' "$tmp/encoder.log" ;;
    esac
done
echo "PASS: incompatible tiled WPP configurations rejected"
