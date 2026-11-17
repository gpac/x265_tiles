#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 /path/to/svt-enabled/x265" >&2
    exit 2
fi

x265=$1
tmp=$(mktemp -d)
trap 'rm -f "$tmp/input.yuv" "$tmp/output.hevc" "$tmp/encoder.log" "$tmp/trace.log" "$tmp/tiles.mp4" "$tmp/merged.hevc" "$tmp/full.md5" "$tmp/tile.md5"; rmdir "$tmp"' EXIT

ffmpeg -v error -f lavfi -i 'testsrc2=size=1024x512:rate=25' \
    -frames:v 8 -pix_fmt yuv420p -f rawvideo "$tmp/input.yuv"

for grid in 2x2 3x1; do
    columns=${grid%x*}
    rows=${grid#*x}
    for mode in shared separate; do
        if [ "$mode" = separate ]; then
            slice_option=--tile-slices
            filter_option=--no-loop-filter-across-tiles
        else
            slice_option=--no-tile-slices
            filter_option=
        fi
        "$x265" --input "$tmp/input.yuv" --input-res 1024x512 --fps 25 \
            --frames 8 --svt --tile-columns "$columns" --tile-rows "$rows" \
            "$slice_option" $filter_option \
            --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
        ffmpeg -v error -xerror -i "$tmp/output.hevc" -f null -
        ffmpeg -hide_banner -loglevel trace -i "$tmp/output.hevc" \
            -c:v copy -bsf:v trace_headers -f null - 2>"$tmp/trace.log"
        grep -q 'tiles_enabled_flag.* = 1' "$tmp/trace.log"
        grep -q "num_tile_columns_minus1.* = $((columns - 1))\$" "$tmp/trace.log"
        grep -q "num_tile_rows_minus1.* = $((rows - 1))\$" "$tmp/trace.log"
        grep -q 'uniform_spacing_flag.* = 1$' "$tmp/trace.log"
        grep -q 'loop_filter_across_tiles_enabled_flag.* = 0$' "$tmp/trace.log"
        count=$(grep -c 'first_slice_segment_in_pic_flag' "$tmp/trace.log")
        if [ "$mode" = separate ]; then
            [ "$count" -eq "$((8 * columns * rows))" ]
        else
            [ "$count" -eq 8 ]
            grep -q "num_entry_point_offsets.* = $((columns * rows - 1))\$" "$tmp/trace.log"
        fi
        echo "PASS: SVT $grid $mode"
    done
done

ffmpeg -y -v error -f lavfi -i 'testsrc2=size=1024x512:rate=25,scroll=horizontal=0.07:vertical=0.05' \
    -frames:v 24 -pix_fmt yuv420p -f rawvideo "$tmp/input.yuv"
for options in '--svt --mcts --no-tile-slices' '--no-tile-slices --mcts --svt'; do
    "$x265" --input "$tmp/input.yuv" --input-res 1024x512 --fps 25 \
        --frames 24 --tile-columns 2 --tile-rows 2 $options \
        --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
    grep -q 'SVT-HEVC MCTS disables temporal motion-vector prediction' "$tmp/encoder.log"
    ffmpeg -hide_banner -loglevel trace -i "$tmp/output.hevc" \
        -c:v copy -bsf:v trace_headers -f null - 2>"$tmp/trace.log"
    grep -q 'sps_temporal_mvp_enabled_flag.* = 0$' "$tmp/trace.log"
    grep -q 'loop_filter_across_tiles_enabled_flag.* = 0$' "$tmp/trace.log"
    count=$(grep -c 'first_slice_segment_in_pic_flag' "$tmp/trace.log")
    [ "$count" -eq 96 ]
    gpac -i "$tmp/output.hevc" hevcsplit -o "$tmp/tiles.mp4"
    for tile in 0 1 2 3; do
        x=$((tile % 2 * 512))
        y=$((tile / 2 * 256))
        ffmpeg -y -v error -xerror -i "$tmp/output.hevc" -vf "crop=512:256:$x:$y" \
            -f framemd5 "$tmp/full.md5"
        ffmpeg -y -v error -xerror -i "$tmp/tiles.mp4" -map "0:v:$tile" \
            -f framemd5 "$tmp/tile.md5"
        cmp "$tmp/full.md5" "$tmp/tile.md5"
    done
    gpac -i "$tmp/tiles.mp4" hevcmerge:mrows -o "$tmp/merged.hevc"
    ffmpeg -y -v error -xerror -i "$tmp/output.hevc" -f framemd5 "$tmp/full.md5"
    ffmpeg -y -v error -xerror -i "$tmp/merged.hevc" -f framemd5 "$tmp/tile.md5"
    cmp "$tmp/full.md5" "$tmp/tile.md5"
    echo "PASS: SVT MCTS independently decoded tiles ($options)"
done

"$x265" --input "$tmp/input.yuv" --input-res 1024x512 --fps 25 \
    --frames 8 --svt --mcts --tile-slices --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
grep -q 'SVT-HEVC MCTS disables temporal motion-vector prediction' "$tmp/encoder.log"
ffmpeg -hide_banner -loglevel trace -i "$tmp/output.hevc" \
    -c:v copy -bsf:v trace_headers -f null - 2>"$tmp/trace.log"
grep -q 'tiles_enabled_flag.* = 0$' "$tmp/trace.log"
grep -q 'sps_temporal_mvp_enabled_flag.* = 0$' "$tmp/trace.log"
ffmpeg -v error -xerror -i "$tmp/output.hevc" -f null -
echo "PASS: SVT single-tile MCTS"

for test_case in \
    '--svt --tile-columns 256,256|SVT-HEVC integration does not support non-uniform tiles' \
    '--svt --tile-rows 128,128|SVT-HEVC integration does not support non-uniform tiles' \
    '--svt --tile-columns 2 --slices-per-tile 2|SVT-HEVC integration does not support multiple slices' \
    '--svt --tile-columns 2 --slices 2|SVT-HEVC integration does not support multiple slices' \
    '--svt --tile-columns 2 --loop-filter-across-tiles|SVT-HEVC does not support loop filtering' \
    '--svt --mcts --loop-filter-across-tiles|SVT-HEVC does not support loop filtering' \
    '--svt --mcts --tile-columns 2 --slices-per-tile 2|SVT-HEVC integration does not support multiple slices' \
    '--svt --mcts --tile-columns 256,256|SVT-HEVC integration does not support non-uniform tiles' \
    '--svt --tile-slices|SVT-HEVC tile slices require multiple tiles' \
    '--svt --tile-columns 21|SVT-HEVC tile counts must be' \
    '--svt --tile-rows 0|SVT-HEVC tile counts must be'; do
    options=${test_case%%|*}
    error=${test_case#*|}
    if "$x265" --input "$tmp/input.yuv" --input-res 1024x512 --fps 25 \
        --frames 1 $options --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1; then
        echo "SVT unexpectedly accepted $options" >&2
        exit 1
    else
        status=$?
    fi
    [ "$status" -eq 1 ]
    grep -q "$error" "$tmp/encoder.log"
done
echo "PASS: unsupported SVT tile configurations rejected"

if "$x265" --input "$tmp/input.yuv" --input-res 1024x512 --fps 25 \
    --frames 1 --svt --tile-columns 10 --output "$tmp/output.hevc" \
    >"$tmp/encoder.log" 2>&1; then
    echo "SVT unexpectedly accepted tiles narrower than its minimum" >&2
    exit 1
else
    status=$?
fi
[ "$status" -eq 2 ]
grep -q 'Error while configuring encoder parameters' "$tmp/encoder.log"
echo "PASS: SVT backend validation failure exits cleanly"
