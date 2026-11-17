#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 /path/to/x265" >&2
    exit 2
fi

x265=$1
tmp=$(mktemp -d)
trap 'rm -f "$tmp/input.yuv" "$tmp/output.hevc" "$tmp/recon.yuv" "$tmp/decoded.yuv" "$tmp/trace.log" "$tmp/encoder.log"; rmdir "$tmp"' EXIT

ffmpeg -v error -f lavfi -i 'testsrc2=size=258x194:rate=5' \
    -frames:v 8 -pix_fmt yuv420p -f rawvideo "$tmp/input.yuv"

for grid in 1x1 1x2 2x1 2x2 3x2; do
    columns=${grid%x*}
    rows=${grid#*x}
    for preset in ultrafast medium; do
      for mode in shared separate; do
        if [ "$mode" = separate ]; then
            [ "$grid" != 1x1 ] || continue
            slice_option=--tile-slices
        else
            slice_option=--no-tile-slices
        fi
        "$x265" --allow-non-conformance --input "$tmp/input.yuv" --input-res 258x194 --fps 5 \
            --frames 8 --preset "$preset" --pools none --no-wpp --no-sao \
            --no-deblock --no-temporal-mvp --aq-mode 0 --no-cutree \
            --tile-columns "$columns" --tile-rows "$rows" "$slice_option" \
            --recon "$tmp/recon.yuv" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
        ffmpeg -y -v error -i "$tmp/output.hevc" -pix_fmt yuv420p -f rawvideo "$tmp/decoded.yuv"
        cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
        ffmpeg -hide_banner -loglevel trace -i "$tmp/output.hevc" \
            -c:v copy -bsf:v trace_headers -f null - 2>"$tmp/trace.log"
        if [ "$grid" = 1x1 ]; then
            grep -q 'tiles_enabled_flag.* = 0' "$tmp/trace.log"
        else
            grep -q 'tiles_enabled_flag.* = 1' "$tmp/trace.log"
            grep -q "num_tile_columns_minus1.* = $((columns - 1))\$" "$tmp/trace.log"
            grep -q "num_tile_rows_minus1.* = $((rows - 1))\$" "$tmp/trace.log"
            if [ "$mode" = separate ]; then
                grep -q 'num_entry_point_offsets.* = 0$' "$tmp/trace.log"
                count=$(grep -c 'first_slice_segment_in_pic_flag' "$tmp/trace.log")
                [ "$count" -eq "$((8 * columns * rows))" ]
            else
                grep -q "num_entry_point_offsets.* = $((columns * rows - 1))\$" "$tmp/trace.log"
            fi
        fi
        echo "PASS: $grid $preset $mode"
      done
    done
done

for slice_option in --no-tile-slices --tile-slices; do
    "$x265" --allow-non-conformance --input "$tmp/input.yuv" --input-res 258x194 --fps 5 \
        --frames 8 --preset medium --pools none --no-wpp --no-sao \
        --deblock=0:0 --no-temporal-mvp --aq-mode 0 --no-cutree \
        --tile-columns 3 --tile-rows 2 "$slice_option" \
        --recon "$tmp/recon.yuv" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
    ffmpeg -y -v error -i "$tmp/output.hevc" -pix_fmt yuv420p -f rawvideo "$tmp/decoded.yuv"
    cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
    echo "PASS: 3x2 filtered $slice_option"
done

for slice_option in --no-tile-slices --tile-slices; do
    "$x265" --allow-non-conformance --input "$tmp/input.yuv" --input-res 258x194 --fps 5 \
        --frames 8 --preset medium --pools none --no-wpp --no-sao \
        --deblock=0:0 --no-temporal-mvp --aq-mode 2 --cutree --qg-size 8 \
        --tile-columns 3 --tile-rows 2 "$slice_option" \
        --recon "$tmp/recon.yuv" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
    ffmpeg -y -v error -i "$tmp/output.hevc" -pix_fmt yuv420p -f rawvideo "$tmp/decoded.yuv"
    cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
    echo "PASS: 3x2 adaptive QP $slice_option"
done

for grid_mode in '1 1 --no-tile-slices' '3 2 --no-tile-slices' '3 2 --tile-slices'; do
    set -- $grid_mode
    columns=$1
    rows=$2
    slice_option=$3
    for sao_option in --no-sao-non-deblock --sao-non-deblock; do
        "$x265" --allow-non-conformance --input "$tmp/input.yuv" --input-res 258x194 --fps 5 \
            --frames 8 --preset medium --pools none --no-wpp --sao "$sao_option" \
            --deblock=0:0 --no-temporal-mvp --aq-mode 2 --cutree --qg-size 8 \
            --tile-columns "$columns" --tile-rows "$rows" "$slice_option" \
            --recon "$tmp/recon.yuv" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
        ffmpeg -y -v error -i "$tmp/output.hevc" -pix_fmt yuv420p -f rawvideo "$tmp/decoded.yuv"
        cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
        echo "PASS: ${columns}x${rows} SAO $slice_option $sao_option"
    done
done

for slice_option in --no-tile-slices --tile-slices; do
    "$x265" --allow-non-conformance --input "$tmp/input.yuv" --input-res 258x194 --fps 5 \
        --frames 8 --preset medium --pools none --no-wpp --sao --selective-sao 1 \
        --no-deblock --no-temporal-mvp --tile-columns 3 --tile-rows 2 "$slice_option" \
        --recon "$tmp/recon.yuv" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
    ffmpeg -y -v error -i "$tmp/output.hevc" -pix_fmt yuv420p -f rawvideo "$tmp/decoded.yuv"
    cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
    echo "PASS: 3x2 selective SAO $slice_option without deblocking"
done

if "$x265" --allow-non-conformance --input "$tmp/input.yuv" --input-res 258x194 --fps 5 \
    --frames 1 --tile-columns 2 --slices 2 --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1; then
    echo "Tiles accepted unsupported picture slices" >&2
    exit 1
fi
grep -q 'tiles currently require --slices 1' "$tmp/encoder.log"
if "$x265" --allow-non-conformance --input "$tmp/input.yuv" --input-res 258x194 --fps 5 \
    --frames 1 --no-wpp --no-sao --no-deblock --no-temporal-mvp \
    --aq-mode 0 --no-cutree --tile-columns 100 --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1; then
    echo "Tiles accepted an invalid grid" >&2
    exit 1
fi
echo "PASS: invalid tile configurations rejected"

for dimensions in '64,' '64,foo' '64,,64' '64,33' '64,64,200' '64,999999999999999999999999'; do
    if "$x265" --allow-non-conformance --input "$tmp/input.yuv" --input-res 258x194 --fps 5 \
        --frames 1 --preset ultrafast --pools none --no-wpp --no-sao --no-temporal-mvp \
        --tile-columns "$dimensions" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1; then
        echo "Invalid tile dimensions accepted: $dimensions" >&2
        exit 1
    fi
done
if "$x265" --input "$tmp/input.yuv" --input-res 258x194 --fps 5 \
    --frames 1 --preset ultrafast --pools none --no-wpp --no-sao --no-temporal-mvp \
    --tile-columns 64,64 --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1; then
    echo "Narrow tiles accepted without --allow-non-conformance" >&2
    exit 1
fi
echo "PASS: invalid and non-conformant dimensions rejected"

if "$x265" --allow-non-conformance --input "$tmp/input.yuv" --input-res 258x194 --fps 5 \
    --frames 1 --preset ultrafast --pools none --ctu 32 --no-wpp --no-sao --no-temporal-mvp \
    --tile-columns 2 --tile-rows 64,64 --slices-per-tile 3 \
    --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1; then
    echo "Too many slices per tile accepted" >&2
    exit 1
fi

for slices in --no-tile-slices --tile-slices; do
    for dimensions in '64,64' '64,64,130'; do
        "$x265" --allow-non-conformance --input "$tmp/input.yuv" --input-res 258x194 --fps 5 \
            --frames 8 --preset medium --pools none --ctu 32 --no-wpp --sao \
            --no-temporal-mvp --tile-columns "$dimensions" --tile-rows 64,64 "$slices" \
            --recon "$tmp/recon.yuv" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
        ffmpeg -y -v error -i "$tmp/output.hevc" -pix_fmt yuv420p -f rawvideo "$tmp/decoded.yuv"
        cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
        echo "PASS: non-uniform $dimensions $slices SAO"
    done
done
ffmpeg -hide_banner -loglevel trace -i "$tmp/output.hevc" \
    -c:v copy -bsf:v trace_headers -f null - 2>"$tmp/trace.log"
grep -q 'general_profile_idc.* = 0' "$tmp/trace.log"
for profile in 1 2 4 5; do
    grep -q "general_profile_compatibility_flag\\[$profile\\].* = 0" "$tmp/trace.log"
done
echo "PASS: non-conformant tiles do not claim a profile"
