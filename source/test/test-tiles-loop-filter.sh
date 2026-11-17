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
    8|10|12) ;;
    *) echo "Unsupported bit depth: $depth" >&2; exit 2 ;;
esac
tmp=$(mktemp -d)
trap 'rm -f "$tmp/input.yuv" "$tmp/chroma.yuv" "$tmp/nonuniform.yuv" "$tmp/recon.yuv" "$tmp/on.yuv" "$tmp/off.yuv" "$tmp/default.yuv" "$tmp/decoded.yuv" "$tmp/output.hevc" "$tmp/encoder.log" "$tmp/decoder.log" "$tmp/trace.log"; rmdir "$tmp"' EXIT

ffmpeg -y -v error -f lavfi -i 'testsrc2=size=514x258:rate=25,scroll=horizontal=0.07:vertical=0.02' \
    -frames:v 24 -pix_fmt yuv420p -f rawvideo "$tmp/input.yuv"

for threading in nowpp wpp; do
    if [ "$threading" = wpp ]; then threads='--pools 2 --wpp'; else threads='--pools none --no-wpp'; fi
    for filters in deblock sao sao-pre combined combined-pre; do
        case "$filters" in
            deblock) filter_options='--deblock=0:0 --no-sao' ;;
            sao) filter_options='--no-deblock --sao --no-sao-non-deblock' ;;
            sao-pre) filter_options='--no-deblock --sao --sao-non-deblock' ;;
            combined) filter_options='--deblock=0:0 --sao --no-sao-non-deblock' ;;
            combined-pre) filter_options='--deblock=0:0 --sao --sao-non-deblock' ;;
        esac
        for option in default on off; do
            case "$option" in
                default) flag=1; set -- ;;
                on) flag=1; set -- --loop-filter-across-tiles ;;
                off) flag=0; set -- --no-loop-filter-across-tiles ;;
            esac
            "$x265" --input "$tmp/input.yuv" --input-res 514x258 --fps 25 \
                --frames 24 --output-depth "$depth" --preset medium --ctu 32 \
                --tile-columns 2 --tile-rows 2 --no-tile-slices $threads $filter_options "$@" \
                --recon "$tmp/$option.yuv" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
            "$decoder" -b "$tmp/output.hevc" -o "$tmp/decoded.yuv" >"$tmp/decoder.log" 2>&1
            cmp "$tmp/$option.yuv" "$tmp/decoded.yuv"
            ffmpeg -hide_banner -loglevel trace -i "$tmp/output.hevc" \
                -c:v copy -bsf:v trace_headers -f null - 2>"$tmp/trace.log"
            grep -q "loop_filter_across_tiles_enabled_flag.* = $flag" "$tmp/trace.log"
        done
        cmp "$tmp/default.yuv" "$tmp/on.yuv"
        if cmp -s "$tmp/on.yuv" "$tmp/off.yuv"; then
            echo "Cross-tile $filters filtering did not affect reconstruction" >&2
            exit 1
        fi
        echo "PASS: $depth-bit $threading $filters tile filtering"
    done
done

ffmpeg -y -v error -f lavfi -i 'testsrc2=size=770x386:rate=25,scroll=horizontal=0.07:vertical=0.02' \
    -frames:v 12 -pix_fmt yuv420p -f rawvideo "$tmp/nonuniform.yuv"
for threading in nowpp wpp; do
    if [ "$threading" = wpp ]; then threads='--pools 2 --wpp'; else threads='--pools none --no-wpp'; fi
    for lossless in normal cu-lossless; do
        if [ "$lossless" = cu-lossless ]; then set -- --cu-lossless; else set --; fi
        "$x265" --input "$tmp/nonuniform.yuv" --input-res 770x386 --fps 25 \
            --frames 12 --output-depth "$depth" --preset medium --ctu 32 \
            --tile-columns 256,256 --tile-rows 128,128 --no-tile-slices $threads "$@" \
            --deblock=0:0 --sao --sao-non-deblock \
            --recon "$tmp/recon.yuv" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
        "$decoder" -b "$tmp/output.hevc" -o "$tmp/decoded.yuv" >"$tmp/decoder.log" 2>&1
        cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
        echo "PASS: $depth-bit $threading non-uniform $lossless tile filtering"
    done
done

for csp in i400 i422 i444; do
    case "$csp" in
        i400) format=gray ;;
        i422) format=yuv422p ;;
        i444) format=yuv444p ;;
    esac
    ffmpeg -y -v error -f lavfi -i 'testsrc2=size=514x258:rate=25,scroll=horizontal=0.07:vertical=0.02' \
        -frames:v 8 -pix_fmt "$format" -f rawvideo "$tmp/chroma.yuv"
    for threading in nowpp wpp; do
        if [ "$threading" = wpp ]; then threads='--pools 2 --wpp'; else threads='--pools none --no-wpp'; fi
        "$x265" --input "$tmp/chroma.yuv" --input-res 514x258 --input-csp "$csp" --fps 25 \
            --frames 8 --output-depth "$depth" --preset medium --ctu 32 \
            --tile-columns 2 --tile-rows 2 --no-tile-slices $threads \
            --deblock=0:0 --sao --sao-non-deblock \
            --recon "$tmp/recon.yuv" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
        "$decoder" -b "$tmp/output.hevc" -o "$tmp/decoded.yuv" >"$tmp/decoder.log" 2>&1
        cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
        echo "PASS: $depth-bit $threading $csp tile filtering"
    done
done

for option in --loop-filter-across-tiles --no-loop-filter-across-tiles; do
    "$x265" --input "$tmp/input.yuv" --input-res 514x258 --fps 25 \
        --frames 8 --output-depth "$depth" --preset medium --ctu 32 \
        --tile-columns 2 --tile-rows 2 --slices-per-tile 2 \
        --pools 2 --wpp --sao --deblock=0:0 "$option" \
        --recon "$tmp/recon.yuv" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
    "$decoder" -b "$tmp/output.hevc" -o "$tmp/decoded.yuv" >"$tmp/decoder.log" 2>&1
    cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
    ffmpeg -hide_banner -loglevel trace -i "$tmp/output.hevc" \
        -c:v copy -bsf:v trace_headers -f null - 2>"$tmp/trace.log"
    if [ "$option" = --loop-filter-across-tiles ]; then flag=1; else flag=0; fi
    grep -q "loop_filter_across_tiles_enabled_flag.* = $flag" "$tmp/trace.log"
    grep -q 'loop_filter_across_slices_enabled_flag.* = 0' "$tmp/trace.log"
    if [ "$option" = --loop-filter-across-tiles ]; then
        cp "$tmp/recon.yuv" "$tmp/on.yuv"
    else
        cmp "$tmp/on.yuv" "$tmp/recon.yuv"
    fi
done
echo "PASS: $depth-bit cross-slice filtering remains disabled"

for option in default on off; do
    case "$option" in
        default) set -- ;;
        on) set -- --loop-filter-across-tiles ;;
        off) set -- --no-loop-filter-across-tiles ;;
    esac
    "$x265" --input "$tmp/input.yuv" --input-res 514x258 --fps 25 \
        --frames 8 --output-depth "$depth" --preset medium --ctu 32 \
        --pools none --no-wpp --sao --deblock=0:0 "$@" \
        --recon "$tmp/$option.yuv" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
    "$decoder" -b "$tmp/output.hevc" -o "$tmp/decoded.yuv" >"$tmp/decoder.log" 2>&1
    cmp "$tmp/$option.yuv" "$tmp/decoded.yuv"
    ffmpeg -hide_banner -loglevel trace -i "$tmp/output.hevc" \
        -c:v copy -bsf:v trace_headers -f null - 2>"$tmp/trace.log"
    grep -q 'tiles_enabled_flag.* = 0' "$tmp/trace.log"
done
cmp "$tmp/default.yuv" "$tmp/on.yuv"
cmp "$tmp/default.yuv" "$tmp/off.yuv"
echo "PASS: $depth-bit untiled reconstruction is unchanged"

for option in default off; do
    if [ "$option" = off ]; then set -- --no-loop-filter-across-tiles; else set --; fi
    "$x265" --input "$tmp/input.yuv" --input-res 514x258 --fps 25 \
        --frames 8 --output-depth "$depth" --preset medium --ctu 32 \
        --tile-columns 2 --tile-rows 2 --mcts --pools none --no-wpp "$@" \
        --recon "$tmp/$option.yuv" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
    "$decoder" -b "$tmp/output.hevc" -o "$tmp/decoded.yuv" >"$tmp/decoder.log" 2>&1
    cmp "$tmp/$option.yuv" "$tmp/decoded.yuv"
    ffmpeg -hide_banner -loglevel trace -i "$tmp/output.hevc" \
        -c:v copy -bsf:v trace_headers -f null - 2>"$tmp/trace.log"
    grep -q 'loop_filter_across_tiles_enabled_flag.* = 0' "$tmp/trace.log"
done
cmp "$tmp/default.yuv" "$tmp/off.yuv"
echo "PASS: $depth-bit MCTS defaults to disabled tile filtering"

for tiles in 1 2; do
    if "$x265" --input "$tmp/input.yuv" --input-res 514x258 --fps 25 \
        --frames 1 --output-depth "$depth" --pools none --no-wpp \
        --tile-columns "$tiles" --mcts --loop-filter-across-tiles \
        --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1; then
        echo "MCTS accepted cross-tile filtering" >&2
        exit 1
    fi
    grep -q 'mcts requires --no-loop-filter-across-tiles' "$tmp/encoder.log"
done
echo "PASS: $depth-bit incompatible MCTS options rejected"
