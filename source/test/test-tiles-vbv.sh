#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 /path/to/x265 /path/to/TAppDecoder" >&2
    exit 2
fi

x265=$1
decoder=$2
tmp=$(mktemp -d)
trap 'rm -f "$tmp/input.yuv" "$tmp/output.hevc" "$tmp/recon.yuv" "$tmp/decoded.yuv" "$tmp/tiles.mp4" "$tmp/merged.hevc" "$tmp/encoder.log" "$tmp/decoder.log" "$tmp/trace.log" "$tmp/merged-trace.log" "$tmp/full.md5" "$tmp/tile.md5" "$tmp/stats" "$tmp/stats.cutree"; rmdir "$tmp"' EXIT

ffmpeg -v error -f lavfi \
    -i 'testsrc2=size=770x386:rate=10,noise=alls=60:allf=t+u,drawbox=x=0:y=0:w=iw:h=ih/2:color=black:t=fill' \
    -frames:v 24 -pix_fmt yuv420p -f rawvideo "$tmp/input.yuv"

encode()
{
    "$x265" --input "$tmp/input.yuv" --input-res 770x386 --fps 10 \
        --frames 24 --preset medium --ctu 32 --no-temporal-mvp \
        --tile-columns 256,256 --tile-rows 128,128 \
        --log-level debug --recon "$tmp/recon.yuv" --output "$tmp/output.hevc" \
        "$@" >"$tmp/encoder.log" 2>&1
    "$decoder" -b "$tmp/output.hevc" -o "$tmp/decoded.yuv" >"$tmp/decoder.log" 2>&1
    cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
}

check_buffer()
{
    # Conservatively count complete Annex B packets, including start codes and SEI.
    ffprobe -v error -select_streams v:0 -show_entries packet=size -of csv=p=0 "${1:-$tmp/output.hevc}" |
        awk 'BEGIN { fill = 225000; count = 0 }
             { fill -= $1 * 8; if (fill < 0) exit 1;
               fill += 25000; if (fill > 250000) fill = 250000; count++ }
             END { if (count != 24) exit 1 }'
    if grep -q 'VBV underflow' "$tmp/encoder.log"; then
        echo "Unexpected VBV underflow" >&2
        exit 1
    fi
}

for mode in nowpp wpp; do
    if [ "$mode" = nowpp ]; then
        threading='--pools none --no-wpp'
    else
        threading='--pools 2 --wpp'
    fi
    encode $threading --sao --sao-non-deblock --slices-per-tile 3 --mcts \
        --bitrate 250 --vbv-maxrate 250 --vbv-bufsize 250 \
        --qpstep 1 --rc-lookahead 0 --bframes 0 --no-cutree
    grep -q 'encode restart required for VBV' "$tmp/encoder.log"
    check_buffer

    rm -f "$tmp/tiles.mp4" "$tmp/merged.hevc"
    gpac -i "$tmp/output.hevc" hevcsplit -o "$tmp/tiles.mp4"
    ffmpeg -y -v error -f rawvideo -pixel_format yuv420p -video_size 770x386 \
        -framerate 10 -i "$tmp/recon.yuv" -vf 'crop=258:130:512:256' -f framemd5 "$tmp/full.md5"
    ffmpeg -y -v error -i "$tmp/tiles.mp4" -map 0:v:8 -f framemd5 "$tmp/tile.md5"
    cmp "$tmp/full.md5" "$tmp/tile.md5"
    gpac -i "$tmp/tiles.mp4" hevcmerge:mrows -o "$tmp/merged.hevc"
    "$decoder" -b "$tmp/merged.hevc" -o "$tmp/decoded.yuv" >"$tmp/decoder.log" 2>&1
    cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
    echo "PASS: $mode MCTS VBV restart, buffer and GPAC roundtrip"

    encode $threading --no-sao --slices-per-tile 3 --mcts \
        --bitrate 250 --vbv-maxrate 250 --vbv-bufsize 250 \
        --qpstep 1 --rc-lookahead 0 --bframes 0 --no-cutree
    grep -q 'encode restart required for VBV' "$tmp/encoder.log"
    check_buffer
    echo "PASS: $mode no-SAO VBV restart"
done

encode --pools none --no-wpp --sao --sao-non-deblock --slices-per-tile 3 --mcts \
    --bitrate 250 --vbv-maxrate 250 --vbv-bufsize 250 --strict-cbr --hrd \
    --qpstep 1 --rc-lookahead 0 --bframes 0 --no-cutree
check_buffer
grep -q 'encode restart required for VBV' "$tmp/encoder.log"
ffmpeg -hide_banner -loglevel trace -i "$tmp/output.hevc" \
    -c:v copy -bsf:v trace_headers -f null - 2>"$tmp/trace.log"
grep -q 'nal_hrd_parameters_present_flag.* = 1' "$tmp/trace.log"
rm -f "$tmp/tiles.mp4" "$tmp/merged.hevc"
gpac -i "$tmp/output.hevc:keepfiller" hevcsplit -o "$tmp/tiles.mp4"
gpac -i "$tmp/tiles.mp4" hevcmerge:mrows -o "$tmp/merged.hevc"
"$decoder" -b "$tmp/merged.hevc" -o "$tmp/decoded.yuv" >"$tmp/decoder.log" 2>&1
cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
check_buffer "$tmp/merged.hevc"
ffmpeg -hide_banner -loglevel trace -i "$tmp/merged.hevc" \
    -c:v copy -bsf:v trace_headers -f null - 2>"$tmp/merged-trace.log"
for pattern in 'nal_unit_type.* = 38' 'Buffering Period' 'Picture Timing'; do
    original=$(grep -c "$pattern" "$tmp/trace.log")
    merged=$(grep -c "$pattern" "$tmp/merged-trace.log")
    [ "$original" -gt 0 ] && [ "$original" -eq "$merged" ]
done
echo "PASS: strict CBR, HRD and GPAC roundtrip"

encode --pools 2 --wpp --sao --slices-per-tile 3 --mcts \
    --bitrate 250 --vbv-maxrate 250 --vbv-bufsize 250 --const-vbv \
    --qpstep 1 --rc-lookahead 0 --bframes 0 --no-cutree
check_buffer
grep -q 'encode restart required for VBV' "$tmp/encoder.log"
echo "PASS: WPP constant-VBV restart"

encode --pools none --no-wpp --no-sao --no-tile-slices \
    --crf 28 --vbv-maxrate 400 --vbv-bufsize 800
echo "PASS: shared-slice capped CRF"

encode --pools 2 --wpp --sao --slices-per-tile 3 --mcts --crf 28 --level-idc 3.1
grep -q 'enabling VBV with vbv-bufsize' "$tmp/encoder.log"
ffmpeg -hide_banner -loglevel trace -i "$tmp/output.hevc" \
    -c:v copy -bsf:v trace_headers -f null - 2>"$tmp/trace.log"
grep -q 'general_level_idc.* = 93$' "$tmp/trace.log"
echo "PASS: level-implied VBV"

for pass in 1 2; do
    encode --pools 2 --wpp --sao --slices-per-tile 3 --mcts \
        --bitrate 400 --vbv-maxrate 500 --vbv-bufsize 800 --pass "$pass" --stats "$tmp/stats"
done
echo "PASS: two-pass constrained VBR"

encode --frames 8 --pools none --no-wpp --no-sao --slices-per-tile 3 --mcts \
    --bitrate 10 --vbv-maxrate 10 --vbv-bufsize 10 --qpmax 10 \
    --rc-lookahead 0 --bframes 0 --no-cutree
grep -q 'VBV underflow' "$tmp/encoder.log"
echo "PASS: infeasible VBV reports underflow"
