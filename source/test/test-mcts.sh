#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 /path/to/x265" >&2
    exit 2
fi

x265=$1
tmp=$(mktemp -d)
trap 'rm -f "$tmp/input.yuv" "$tmp/output.hevc" "$tmp/cropped.hevc" "$tmp/recon.yuv" "$tmp/decoded.yuv" "$tmp/tiles.mp4" "$tmp/merged.hevc" "$tmp/full.md5" "$tmp/tile.md5" "$tmp/encoder.log" "$tmp/trace.log"; rmdir "$tmp"' EXIT

for sequence in normal moving; do
  if [ "$sequence" = moving ]; then
    filter='testsrc2=size=256x256:rate=30,scroll=horizontal=0.07:vertical=0.05'
  else
    filter='testsrc2=size=256x256:rate=30'
  fi
  ffmpeg -y -v error -f lavfi -i "$filter" \
      -frames:v 48 -pix_fmt yuv420p -f rawvideo "$tmp/input.yuv"
  for preset in ultrafast medium slow; do
    "$x265" --allow-non-conformance --input "$tmp/input.yuv" --input-res 256x256 --fps 30 \
        --frames 48 --preset "$preset" --pools none --no-wpp --no-sao \
        --deblock=0:0 --no-temporal-mvp --aq-mode 2 --cutree --qg-size 8 \
        --tile-columns 2 --tile-rows 2 --mcts \
        --recon "$tmp/recon.yuv" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
    ffmpeg -y -v error -i "$tmp/output.hevc" -pix_fmt yuv420p -f rawvideo "$tmp/decoded.yuv"
    cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
    gpac -i "$tmp/output.hevc" hevcsplit -o "$tmp/tiles.mp4"
    for tile in 0 1 2 3; do
        x=$((tile % 2 * 128))
        y=$((tile / 2 * 128))
        ffmpeg -y -v error -i "$tmp/output.hevc" -vf "crop=128:128:$x:$y" \
            -f framemd5 "$tmp/full.md5"
        ffmpeg -y -v error -i "$tmp/tiles.mp4" -map "0:v:$tile" \
            -f framemd5 "$tmp/tile.md5"
        cmp "$tmp/full.md5" "$tmp/tile.md5"
    done

    gpac -i "$tmp/tiles.mp4" hevcmerge:mrows -o "$tmp/merged.hevc"
    ffmpeg -y -v error -i "$tmp/merged.hevc" -pix_fmt yuv420p -f rawvideo "$tmp/decoded.yuv"
    cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
    echo "PASS: independently decoded tiles, $sequence $preset"
  done
done

for sao_option in --no-sao-non-deblock --sao-non-deblock; do
    "$x265" --allow-non-conformance --input "$tmp/input.yuv" --input-res 256x256 --fps 30 \
        --frames 16 --preset medium --pools none --no-wpp --sao "$sao_option" \
        --deblock=0:0 --no-temporal-mvp --aq-mode 2 --cutree --qg-size 8 \
        --tile-columns 2 --tile-rows 2 --mcts \
        --recon "$tmp/recon.yuv" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
    ffmpeg -y -v error -i "$tmp/output.hevc" -pix_fmt yuv420p -f rawvideo "$tmp/decoded.yuv"
    cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
    ffmpeg -hide_banner -loglevel trace -i "$tmp/output.hevc" \
        -c:v copy -bsf:v trace_headers -f null - 2>"$tmp/trace.log"
    grep -q 'sample_adaptive_offset_enabled_flag.* = 1' "$tmp/trace.log"
    grep -q 'slice_sao_luma_flag.* = 1' "$tmp/trace.log"
    grep -q 'loop_filter_across_tiles_enabled_flag.* = 0' "$tmp/trace.log"
    gpac -i "$tmp/output.hevc" hevcsplit -o "$tmp/tiles.mp4"
    for tile in 0 1 2 3; do
        x=$((tile % 2 * 128))
        y=$((tile / 2 * 128))
        ffmpeg -y -v error -i "$tmp/output.hevc" -vf "crop=128:128:$x:$y" \
            -f framemd5 "$tmp/full.md5"
        ffmpeg -y -v error -i "$tmp/tiles.mp4" -map "0:v:$tile" -f framemd5 "$tmp/tile.md5"
        cmp "$tmp/full.md5" "$tmp/tile.md5"
    done
    gpac -i "$tmp/tiles.mp4" hevcmerge:mrows -o "$tmp/merged.hevc"
    ffmpeg -y -v error -i "$tmp/merged.hevc" -pix_fmt yuv420p -f rawvideo "$tmp/decoded.yuv"
    cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
    echo "PASS: MCTS SAO $sao_option split and merge"
done

for format in i400 i422 i444; do
    case "$format" in
      i400) pixel_format=gray ;;
      i422) pixel_format=yuv422p ;;
      i444) pixel_format=yuv444p ;;
    esac
    ffmpeg -y -v error -filter_threads 1 -f lavfi -i 'testsrc2=size=256x256:rate=30' \
        -frames:v 8 -pix_fmt "$pixel_format" -f rawvideo "$tmp/input.yuv"
    if [ "$format" = i444 ]; then lossless_option=--cu-lossless; else lossless_option=--no-cu-lossless; fi
    "$x265" --allow-non-conformance --input "$tmp/input.yuv" --input-res 256x256 --input-csp "$format" --fps 30 \
        --frames 8 --preset medium --pools none --no-wpp --sao \
        --deblock=0:0 --no-temporal-mvp --tile-columns 2 --tile-rows 2 --mcts "$lossless_option" \
        --recon "$tmp/recon.yuv" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
    ffmpeg -y -v error -i "$tmp/output.hevc" -pix_fmt "$pixel_format" -f rawvideo "$tmp/decoded.yuv"
    cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
    gpac -i "$tmp/output.hevc" hevcsplit -o "$tmp/tiles.mp4"
    for tile in 0 1 2 3; do
        x=$((tile % 2 * 128))
        y=$((tile / 2 * 128))
        ffmpeg -y -v error -i "$tmp/output.hevc" -vf "crop=128:128:$x:$y" \
            -f framemd5 "$tmp/full.md5"
        ffmpeg -y -v error -i "$tmp/tiles.mp4" -map "0:v:$tile" -f framemd5 "$tmp/tile.md5"
        cmp "$tmp/full.md5" "$tmp/tile.md5"
    done
    echo "PASS: MCTS SAO $format independent tiles"
done

ffmpeg -y -v error -f lavfi -i 'testsrc2=size=256x256:rate=30' \
    -frames:v 4 -pix_fmt yuv420p -f rawvideo "$tmp/input.yuv"
"$x265" --input "$tmp/input.yuv" --input-res 256x256 --fps 30 \
    --frames 4 --pools none --no-wpp --tile-columns 1 --tile-rows 1 --mcts \
    --recon "$tmp/recon.yuv" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
ffmpeg -y -v error -i "$tmp/output.hevc" -pix_fmt yuv420p -f rawvideo "$tmp/decoded.yuv"
cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
if "$x265" --input "$tmp/input.yuv" --input-res 256x256 --fps 30 \
    --frames 1 --pools none --no-wpp --mcts --slices-per-tile 2 \
    --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1; then
    echo "Multiple tile slices accepted for a single tile" >&2
    exit 1
fi
grep -q 'tile-slices requires more than one tile' "$tmp/encoder.log"
echo "PASS: single-tile MCTS and unsupported multiple tile slices"

for options in '--mcts --no-tile-slices' '--no-tile-slices --mcts' '--tile-slices --mcts'; do
    "$x265" --allow-non-conformance --input "$tmp/input.yuv" --input-res 256x256 --fps 30 \
        --frames 4 --preset ultrafast --pools none --no-wpp --no-sao \
        --no-temporal-mvp --tile-columns 2 --tile-rows 2 $options \
        --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
    gpac -i "$tmp/output.hevc" hevcsplit -o "$tmp/tiles.mp4"
    ffmpeg -y -v error -i "$tmp/output.hevc" -vf 'crop=128:128:128:128' \
        -f framemd5 "$tmp/full.md5"
    ffmpeg -y -v error -i "$tmp/tiles.mp4" -map 0:v:3 -f framemd5 "$tmp/tile.md5"
    cmp "$tmp/full.md5" "$tmp/tile.md5"
    echo "PASS: $options produces independent tile slices"
done

ffmpeg -y -v error -f lavfi -i 'testsrc2=size=258x194:rate=30' \
    -frames:v 12 -pix_fmt yuv420p -f rawvideo "$tmp/input.yuv"
"$x265" --allow-non-conformance --input "$tmp/input.yuv" --input-res 258x194 --fps 30 \
    --frames 12 --preset medium --pools none --no-wpp --sao \
    --deblock=0:0 --no-temporal-mvp --aq-mode 2 --cutree --qg-size 8 \
    --tile-columns 3 --tile-rows 2 --mcts \
    --recon "$tmp/recon.yuv" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
ffmpeg -y -v error -i "$tmp/output.hevc" -pix_fmt yuv420p -f rawvideo "$tmp/decoded.yuv"
cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
for crop in original larger extreme four-sided; do
    left=0; top=0
    if [ "$crop" = original ]; then
        input="$tmp/output.hevc"; edge_width=66; edge_height=66
    else
        if [ "$crop" = larger ]; then
            right=12; bottom=10; edge_width=60; edge_height=62
        elif [ "$crop" = extreme ]; then
            right=70; bottom=70; edge_width=2; edge_height=2
        else
            left=2; top=2; right=6; bottom=6; edge_width=66; edge_height=66
        fi
        ffmpeg -y -v error -i "$tmp/output.hevc" -c copy \
            -bsf:v "hevc_metadata=crop_left=$left:crop_top=$top:crop_right=$right:crop_bottom=$bottom" "$tmp/cropped.hevc"
        input="$tmp/cropped.hevc"
    fi
    gpac -i "$input" hevcsplit -o "$tmp/tiles.mp4"
    for tile in 0 1 2 3 4 5; do
        case $((tile % 3)) in
          0) x=0; width=$((64 - left)) ;;
          1) x=$((64 - left)); width=128 ;;
          2) x=$((192 - left)); width=$edge_width ;;
        esac
        if [ "$tile" -lt 3 ]; then y=0; height=$((128 - top)); else y=$((128 - top)); height=$edge_height; fi
        ffmpeg -y -v error -i "$input" -vf "crop=$width:$height:$x:$y" \
            -f framemd5 "$tmp/full.md5"
        ffmpeg -y -v error -i "$tmp/tiles.mp4" -map "0:v:$tile" \
            -f framemd5 "$tmp/tile.md5"
        cmp "$tmp/full.md5" "$tmp/tile.md5"
    done
    if [ "$crop" = four-sided ]; then
        echo "PASS: independently decoded four-sided cropped tiles"
        continue
    fi
    gpac -i "$tmp/tiles.mp4" hevcmerge:mrows -o "$tmp/merged.hevc"
    ffmpeg -y -v error -i "$input" -f framemd5 "$tmp/full.md5"
    ffmpeg -y -v error -i "$tmp/merged.hevc" -f framemd5 "$tmp/tile.md5"
    cmp "$tmp/full.md5" "$tmp/tile.md5"
    echo "PASS: independently decoded and merged $crop cropped edge tiles"
done

ffmpeg -y -v error -i "$tmp/output.hevc" -c copy \
    -bsf:v 'hevc_metadata=crop_right=74:crop_bottom=6' "$tmp/cropped.hevc"
status=0
gpac -i "$tmp/cropped.hevc" hevcsplit -o "$tmp/tiles.mp4" >"$tmp/encoder.log" 2>&1 || status=$?
if [ "$status" -ge 128 ] || ! grep -q 'Tile is entirely outside the conformance window' "$tmp/encoder.log"; then
    echo "Fully cropped tile was not rejected cleanly" >&2
    exit 1
fi
echo "PASS: fully cropped tile rejected without crashing"

ffmpeg -y -v error -f lavfi -i 'testsrc2=size=768x1408:rate=30' \
    -frames:v 1 -pix_fmt yuv420p -f rawvideo "$tmp/input.yuv"
"$x265" --allow-non-conformance --input "$tmp/input.yuv" --input-res 768x1408 --fps 30 \
    --frames 1 --preset ultrafast --pools none --ctu 64 --no-wpp --sao \
    --no-temporal-mvp --tile-columns 12 --tile-rows 22 --tile-slices --mcts \
    --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
gpac -i "$tmp/output.hevc" hevcsplit -o "$tmp/tiles.mp4"
track_count=$(ffprobe -v error -select_streams v -show_entries stream=index \
    -of csv=p=0 "$tmp/tiles.mp4" | wc -l)
if [ "$track_count" -ne 264 ]; then
    echo "Expected 264 split tile tracks, got $track_count" >&2
    exit 1
fi
ffmpeg -y -v error -i "$tmp/output.hevc" -vf 'crop=64:64:704:1344' \
    -f framemd5 "$tmp/full.md5"
ffmpeg -y -v error -i "$tmp/tiles.mp4" -map 0:v:263 -f framemd5 "$tmp/tile.md5"
cmp "$tmp/full.md5" "$tmp/tile.md5"
echo "PASS: 264 independently encoded tiles across 22 rows"

ffmpeg -y -v error -f lavfi -i 'testsrc2=size=770x194:rate=5' \
    -frames:v 4 -pix_fmt yuv420p -f rawvideo "$tmp/input.yuv"
"$x265" --input "$tmp/input.yuv" --input-res 770x194 --fps 5 \
    --frames 4 --preset ultrafast --pools none --ctu 64 --no-wpp --no-sao \
    --no-temporal-mvp --tile-columns 256,256 --tile-rows 64,64 --mcts \
    --recon "$tmp/recon.yuv" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
ffmpeg -y -v error -i "$tmp/output.hevc" -pix_fmt yuv420p -f rawvideo "$tmp/decoded.yuv"
cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
ffmpeg -hide_banner -loglevel trace -i "$tmp/output.hevc" \
    -c:v copy -bsf:v trace_headers -f null - 2>"$tmp/trace.log"
grep -q 'uniform_spacing_flag.* = 0' "$tmp/trace.log"
gpac -i "$tmp/output.hevc" hevcsplit -o "$tmp/tiles.mp4"
for tile in 0 1 2 3 4 5 6 7 8; do
    case $((tile % 3)) in
      0) x=0; width=256 ;;
      1) x=256; width=256 ;;
      2) x=512; width=258 ;;
    esac
    case $((tile / 3)) in
      0) y=0; height=64 ;;
      1) y=64; height=64 ;;
      2) y=128; height=66 ;;
    esac
    ffmpeg -y -v error -i "$tmp/output.hevc" -vf "crop=$width:$height:$x:$y" \
        -f framemd5 "$tmp/full.md5"
    ffmpeg -y -v error -i "$tmp/tiles.mp4" -map "0:v:$tile" -f framemd5 "$tmp/tile.md5"
    cmp "$tmp/full.md5" "$tmp/tile.md5"
done
gpac -i "$tmp/tiles.mp4" hevcmerge:mrows -o "$tmp/merged.hevc"
ffmpeg -y -v error -i "$tmp/merged.hevc" -pix_fmt yuv420p -f rawvideo "$tmp/decoded.yuv"
cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
echo "PASS: non-uniform inferred and cropped tiles split and merge"

"$x265" --input "$tmp/input.yuv" --input-res 770x194 --fps 5 \
    --frames 4 --preset medium --pools none --ctu 32 --no-wpp --sao \
    --no-temporal-mvp --tile-columns 256,256 --slices-per-tile 3 --mcts \
    --recon "$tmp/recon.yuv" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
ffmpeg -y -v error -i "$tmp/output.hevc" -pix_fmt yuv420p -f rawvideo "$tmp/decoded.yuv"
cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
gpac -i "$tmp/output.hevc" hevcsplit -o "$tmp/tiles.mp4"
for tile in 0 1 2; do
    case "$tile" in
      0) x=0; width=256 ;;
      1) x=256; width=256 ;;
      2) x=512; width=258 ;;
    esac
    ffmpeg -y -v error -i "$tmp/output.hevc" -vf "crop=$width:194:$x:0" -f framemd5 "$tmp/full.md5"
    ffmpeg -y -v error -i "$tmp/tiles.mp4" -map "0:v:$tile" -f framemd5 "$tmp/tile.md5"
    cmp "$tmp/full.md5" "$tmp/tile.md5"
done
gpac -i "$tmp/tiles.mp4" hevcmerge:mrows -o "$tmp/merged.hevc"
ffmpeg -y -v error -i "$tmp/merged.hevc" -pix_fmt yuv420p -f rawvideo "$tmp/decoded.yuv"
cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
echo "PASS: multiple independent slices per tile split and merge"
