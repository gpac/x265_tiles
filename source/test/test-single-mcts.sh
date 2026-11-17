#!/bin/sh
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "Usage: $0 /path/to/x265 /path/to/TAppDecoder [8|10|12]" >&2
    exit 2
fi

x265=$1
decoder=$2
depth=${3:-8}
case "$depth" in
    8) pixel_format=yuv420p; profile=main ;;
    10|12) pixel_format=yuv420p${depth}le; profile=main$depth ;;
    *) echo "Unsupported bit depth: $depth" >&2; exit 2 ;;
esac
tmp=$(mktemp -d)
trap 'for i in 0 1 2 3; do rm -f "$tmp/input$i.yuv" "$tmp/recon$i.yuv" "$tmp/decoded$i.yuv" "$tmp/tile$i.hevc"; done; rm -f "$tmp/cropped.yuv" "$tmp/merged.hevc" "$tmp/merged.yuv" "$tmp/full.md5" "$tmp/tile.md5" "$tmp/trace.log" "$tmp/encoder.log" "$tmp/decoder.log"; rmdir "$tmp"' EXIT

for i in 0 1 2 3; do
    x=$((i % 2 * 256))
    y=$((i / 2 * 128))
    ffmpeg -y -v error -f lavfi -i 'testsrc2=size=512x256:rate=30,scroll=horizontal=0.07:vertical=0.02' \
        -vf "crop=256:128:$x:$y" -frames:v 24 -pix_fmt yuv420p -f rawvideo "$tmp/input$i.yuv"
done

for mode in nowpp wpp no-tmvp; do
    if [ "$mode" = wpp ]; then threading='--pools 2 --wpp'; else threading='--pools none --no-wpp'; fi
    if [ "$mode" = no-tmvp ]; then prediction='--no-temporal-mvp --no-sao'; else prediction='--temporal-mvp --sao'; fi
    for i in 0 1 2 3; do
        "$x265" --input "$tmp/input$i.yuv" --input-res 256x128 --fps 30 \
            --frames 24 --output-depth "$depth" --preset medium --ctu 64 $threading --mcts $prediction \
            --repeat-headers --bframes 3 --b-adapt 0 \
            --keyint 24 --min-keyint 24 --scenecut 0 \
            --recon "$tmp/recon$i.yuv" --output "$tmp/tile$i.hevc" >"$tmp/encoder.log" 2>&1
        "$decoder" -b "$tmp/tile$i.hevc" -o "$tmp/decoded$i.yuv" >"$tmp/decoder.log" 2>&1
        cmp "$tmp/recon$i.yuv" "$tmp/decoded$i.yuv"
    done
    ffmpeg -hide_banner -loglevel trace -i "$tmp/tile0.hevc" \
        -c:v copy -bsf:v trace_headers -f null - 2>"$tmp/trace.log"
    if [ "$mode" = no-tmvp ]; then tmvp=0; else tmvp=1; fi
    grep -q "sps_temporal_mvp_enabled_flag.* = $tmvp" "$tmp/trace.log"
    grep -q 'loop_filter_across_slices_enabled_flag.* = 0' "$tmp/trace.log"
    if [ "$mode" = wpp ]; then
        grep -q 'general_profile_idc.* = 5' "$tmp/trace.log"
    fi
    gpac -i "$tmp/tile0.hevc:#CropOrigin=0x0" -i "$tmp/tile1.hevc:#CropOrigin=256x0" \
        -i "$tmp/tile2.hevc:#CropOrigin=0x128" -i "$tmp/tile3.hevc:#CropOrigin=256x128" \
        hevcmerge:mrows -o "$tmp/merged.hevc"
    "$decoder" -b "$tmp/merged.hevc" -o "$tmp/merged.yuv" >"$tmp/decoder.log" 2>&1
    for i in 0 1 2 3; do
        x=$((i % 2 * 256))
        y=$((i / 2 * 128))
        ffmpeg -y -v error -f rawvideo -pixel_format "$pixel_format" -video_size 512x256 \
            -framerate 30 -i "$tmp/merged.yuv" -vf "crop=256:128:$x:$y" -f framemd5 "$tmp/full.md5"
        ffmpeg -y -v error -f rawvideo -pixel_format "$pixel_format" -video_size 256x128 \
            -framerate 30 -i "$tmp/recon$i.yuv" -f framemd5 "$tmp/tile.md5"
        cmp "$tmp/full.md5" "$tmp/tile.md5"
    done
    echo "PASS: independently encoded $depth-bit single-tile MCTS, $mode"
done

for slices in --tile-slices --no-tile-slices; do
    "$x265" --input "$tmp/input0.yuv" --input-res 256x128 --fps 30 \
        --frames 4 --output-depth "$depth" --pools none --no-wpp --mcts "$slices" \
        --output "$tmp/tile0.hevc" >"$tmp/encoder.log" 2>&1
done
if "$x265" --input "$tmp/input0.yuv" --input-res 256x128 --fps 30 \
    --frames 1 --output-depth "$depth" --pools 2 --wpp --mcts --profile "$profile" \
    --output "$tmp/tile0.hevc" >"$tmp/encoder.log" 2>&1; then
    echo "Explicit profile accepted for MCTS with WPP" >&2
    exit 1
fi
grep -q 'mcts with WPP requires the automatically selected high-throughput profile' "$tmp/encoder.log"
if "$x265" --input "$tmp/input0.yuv" --input-res 256x128 --fps 30 \
    --frames 1 --output-depth "$depth" --pools 2 --wpp --mcts --slices 2 \
    --output "$tmp/tile0.hevc" >"$tmp/encoder.log" 2>&1; then
    echo "Multiple slices accepted for single-tile MCTS" >&2
    exit 1
fi
grep -q 'mcts requires --slices 1' "$tmp/encoder.log"
echo "PASS: single-tile slice options and WPP profile validation"

ffmpeg -y -v error -f lavfi -i 'testsrc2=size=258x194:rate=30,scroll=horizontal=0.07:vertical=0.02' \
    -frames:v 16 -pix_fmt yuv420p -f rawvideo "$tmp/cropped.yuv"
"$x265" --input "$tmp/cropped.yuv" --input-res 258x194 --fps 30 \
    --frames 16 --output-depth "$depth" --pools none --no-wpp --mcts --sao --temporal-mvp \
    --recon "$tmp/recon0.yuv" --output "$tmp/tile0.hevc" >"$tmp/encoder.log" 2>&1
"$decoder" -b "$tmp/tile0.hevc" -o "$tmp/decoded0.yuv" >"$tmp/decoder.log" 2>&1
cmp "$tmp/recon0.yuv" "$tmp/decoded0.yuv"
echo "PASS: single-tile MCTS with cropped coded picture"
