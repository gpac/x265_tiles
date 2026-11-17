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
    8) format=yuv420p ;;
    10|12) format=yuv420p${depth}le ;;
    *) echo "Unsupported bit depth: $depth" >&2; exit 2 ;;
esac
tmp=$(mktemp -d)
trap 'for i in 0 1 2 3; do rm -f "$tmp/input$i.yuv" "$tmp/recon$i.yuv" "$tmp/tile$i.hevc"; done; rm -f "$tmp/input.yuv" "$tmp/recon.yuv" "$tmp/baseline.yuv" "$tmp/decoded.yuv" "$tmp/output.hevc" "$tmp/tiles.mp4" "$tmp/merged.hevc" "$tmp/zonefile" "$tmp/encoder.log" "$tmp/decoder.log" "$tmp/qp" "$tmp/reference-qp" "$tmp/full.md5" "$tmp/tile.md5" "$tmp/stats" "$tmp/stats.temp" "$tmp/stats.cutree" "$tmp/stats.cutree.temp"; rmdir "$tmp"' EXIT

ffmpeg -v error -f lavfi -i 'testsrc2=size=512x256:rate=25,scroll=horizontal=0.07:vertical=0.02' \
    -frames:v 24 -pix_fmt yuv420p -f rawvideo "$tmp/input.yuv"

encode()
{
    "$x265" --input "$tmp/input.yuv" --input-res 512x256 --fps 25 \
        --frames 24 --output-depth "$depth" --preset medium --ctu 32 \
        --recon "$tmp/recon.yuv" --output "$tmp/output.hevc" \
        "$@" >"$tmp/encoder.log" 2>&1
    "$decoder" -b "$tmp/output.hevc" -o "$tmp/decoded.yuv" >"$tmp/decoder.log" 2>&1
    cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
}

check_mcts()
{
    rm -f "$tmp/tiles.mp4" "$tmp/merged.hevc"
    gpac -i "$tmp/output.hevc" hevcsplit -o "$tmp/tiles.mp4" >"$tmp/encoder.log" 2>&1
    for tile in 0 1 2 3; do
        x=$((tile % 2 * 256))
        y=$((tile / 2 * 128))
        ffmpeg -y -v error -f rawvideo -pixel_format "$format" -video_size 512x256 \
            -framerate 25 -i "$tmp/recon.yuv" -vf "crop=256:128:$x:$y" \
            -f framemd5 "$tmp/full.md5"
        ffmpeg -y -v error -i "$tmp/tiles.mp4" -map "0:v:$tile" -f framemd5 "$tmp/tile.md5"
        cmp "$tmp/full.md5" "$tmp/tile.md5"
    done
    gpac -i "$tmp/tiles.mp4" hevcmerge:mrows -o "$tmp/merged.hevc" >"$tmp/encoder.log" 2>&1
    "$decoder" -b "$tmp/merged.hevc" -o "$tmp/decoded.yuv" >"$tmp/decoder.log" 2>&1
    cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
}

# Compare frame-level QPs with untiled x265, including overlapping zones.
zones='4,15,q=15/8,11,q=40/18,21,b=2'
encode --pools none --no-wpp --qp 28 --bframes 0 --zones "$zones"
sed -n 's/^POC *\([0-9]*\).*QP *\([0-9]*\) ).*/\1 \2/p' "$tmp/decoder.log" >"$tmp/reference-qp"
grep -q '^8 40$' "$tmp/reference-qp"
grep -q '^12 15$' "$tmp/reference-qp"
grep -q '^19 22$' "$tmp/reference-qp"

for threading in nowpp wpp; do
    if [ "$threading" = wpp ]; then threads='--pools 2 --wpp'; else threads='--pools none --no-wpp'; fi
    for mode in shared separate mcts; do
        case "$mode" in
            shared) tiles='--no-tile-slices' ;;
            separate) tiles='--slices-per-tile 2' ;;
            mcts) tiles='--mcts --slices-per-tile 2' ;;
        esac
        encode $threads --tile-columns 2 --tile-rows 2 $tiles --qp 28 --bframes 0 --zones "$zones"
        sed -n 's/^POC *\([0-9]*\).*QP *\([0-9]*\) ).*/\1 \2/p' "$tmp/decoder.log" >"$tmp/qp"
        cmp "$tmp/reference-qp" "$tmp/qp"
        if [ "$mode" = mcts ]; then check_mcts; fi

        encode $threads --tile-columns 2 --tile-rows 2 $tiles --crf 28 --zones '4,15,b=2'
        cp "$tmp/recon.yuv" "$tmp/baseline.yuv"
        encode $threads --tile-columns 2 --tile-rows 2 $tiles --crf 28
        if cmp -s "$tmp/recon.yuv" "$tmp/baseline.yuv"; then
            echo "CRF zone did not affect reconstruction" >&2
            exit 1
        fi

        echo "PASS: $depth-bit $threading $mode zones"
    done
done

encode --pools 4 --frame-threads 3 --wpp --qp 28 --bframes 0 --zones "$zones"
sed -n 's/^POC *\([0-9]*\).*QP *\([0-9]*\) ).*/\1 \2/p' "$tmp/decoder.log" >"$tmp/reference-qp"
encode --pools 4 --frame-threads 3 --wpp --tile-columns 2 --tile-rows 2 --mcts \
    --qp 28 --bframes 0 --zones "$zones"
grep -q 'frame threads / pool features.*3 / wpp' "$tmp/encoder.log"
sed -n 's/^POC *\([0-9]*\).*QP *\([0-9]*\) ).*/\1 \2/p' "$tmp/decoder.log" >"$tmp/qp"
cmp "$tmp/reference-qp" "$tmp/qp"
check_mcts
echo "PASS: $depth-bit MCTS zones with multiple frame threads"

encode --pools 2 --wpp --tile-columns 2 --tile-rows 2 --mcts \
    --bitrate 500 --vbv-maxrate 600 --vbv-bufsize 1000 --zones '4,15,b=1.5'
check_mcts
echo "PASS: $depth-bit MCTS single-pass VBV zones"

for pass in 1 2; do
    encode --pools 2 --wpp --tile-columns 2 --tile-rows 2 --mcts \
        --bitrate 500 --vbv-maxrate 600 --vbv-bufsize 1000 \
        --zones '4,15,b=1.5/8,11,q=25' --pass "$pass" --stats "$tmp/stats"
done
check_mcts
echo "PASS: $depth-bit MCTS two-pass VBV zones"

for tile in 0 1 2 3; do
    x=$((tile % 2 * 256))
    y=$((tile / 2 * 128))
    ffmpeg -y -v error -f rawvideo -pixel_format yuv420p -video_size 512x256 \
        -framerate 25 -i "$tmp/input.yuv" -vf "crop=256:128:$x:$y" \
        -f rawvideo "$tmp/input$tile.yuv"
    "$x265" --input "$tmp/input$tile.yuv" --input-res 256x128 --fps 25 \
        --frames 24 --output-depth "$depth" --preset medium --ctu 32 \
        --pools 2 --wpp --mcts --qp 28 --bframes 0 --scenecut 0 \
        --keyint 24 --min-keyint 24 --repeat-headers --zones "4,15,q=$((18 + tile * 4))" \
        --recon "$tmp/recon$tile.yuv" --output "$tmp/tile$tile.hevc" >"$tmp/encoder.log" 2>&1
    "$decoder" -b "$tmp/tile$tile.hevc" -o "$tmp/decoded.yuv" >"$tmp/decoder.log" 2>&1
    cmp "$tmp/recon$tile.yuv" "$tmp/decoded.yuv"
done
gpac -i "$tmp/tile0.hevc:#CropOrigin=0x0" -i "$tmp/tile1.hevc:#CropOrigin=256x0" \
    -i "$tmp/tile2.hevc:#CropOrigin=0x128" -i "$tmp/tile3.hevc:#CropOrigin=256x128" \
    hevcmerge:mrows -o "$tmp/merged.hevc" >"$tmp/encoder.log" 2>&1
"$decoder" -b "$tmp/merged.hevc" -o "$tmp/decoded.yuv" >"$tmp/decoder.log" 2>&1
for tile in 0 1 2 3; do
    x=$((tile % 2 * 256))
    y=$((tile / 2 * 128))
    ffmpeg -y -v error -f rawvideo -pixel_format "$format" -video_size 512x256 \
        -framerate 25 -i "$tmp/decoded.yuv" -vf "crop=256:128:$x:$y" -f framemd5 "$tmp/full.md5"
    ffmpeg -y -v error -f rawvideo -pixel_format "$format" -video_size 256x128 \
        -framerate 25 -i "$tmp/recon$tile.yuv" -f framemd5 "$tmp/tile.md5"
    cmp "$tmp/full.md5" "$tmp/tile.md5"
done
echo "PASS: $depth-bit independently encoded MCTS zones and merge"

printf '0 --crf 30\n8 --crf 18\n' >"$tmp/zonefile"
if "$x265" --input "$tmp/input.yuv" --input-res 512x256 --fps 25 \
    --frames 24 --output-depth "$depth" --tile-columns 2 --tile-rows 2 --mcts \
    --zonefile "$tmp/zonefile" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1; then
    echo "Zonefile unexpectedly accepted with tiles" >&2
    exit 1
fi
grep -q 'tiles currently do not support zonefile reconfiguration' "$tmp/encoder.log"
echo "PASS: $depth-bit zonefile rejected with tiles"
