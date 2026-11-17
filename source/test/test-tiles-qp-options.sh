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
trap 'for i in 0 1 2 3; do rm -f "$tmp/input$i.yuv" "$tmp/recon$i.yuv" "$tmp/tile$i.hevc"; done; rm -f "$tmp/input.yuv" "$tmp/cropped.yuv" "$tmp/recon.yuv" "$tmp/baseline.yuv" "$tmp/decoded.yuv" "$tmp/output.hevc" "$tmp/first.hevc" "$tmp/merged.hevc" "$tmp/tiles.mp4" "$tmp/full.md5" "$tmp/tile.md5" "$tmp/stats" "$tmp/stats.temp" "$tmp/stats.cutree" "$tmp/stats.cutree.temp" "$tmp/baseline.stats" "$tmp/baseline.stats.temp" "$tmp/baseline.stats.cutree" "$tmp/baseline.stats.cutree.temp" "$tmp/analysis.dat" "$tmp/analysis.dat.temp" "$tmp/encoder.log" "$tmp/decoder.log"; rmdir "$tmp"' EXIT

check_threaded_me()
{
    if ! grep -q 'frame threads / pool features.*threaded-me' "$tmp/encoder.log"; then
        echo "Threaded ME was not enabled; this test requires at least 32 pool threads" >&2
        exit 1
    fi
}

ffmpeg -y -v error -f lavfi -i 'testsrc2=size=512x256:rate=25,scroll=horizontal=0.07:vertical=0.02' \
    -frames:v 24 -pix_fmt yuv420p -f rawvideo "$tmp/input.yuv"

for threading in nowpp wpp; do
    if [ "$threading" = wpp ]; then wpp=--wpp; else wpp=--no-wpp; fi
    "$x265" --input "$tmp/input.yuv" --input-res 512x256 --fps 25 \
        --frames 24 --output-depth "$depth" --preset medium --ctu 32 \
        --pools 32 --frame-threads 2 "$wpp" --threaded-me \
        --recon "$tmp/recon.yuv" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
    check_threaded_me
    "$decoder" -b "$tmp/output.hevc" -o "$tmp/decoded.yuv" >"$tmp/decoder.log" 2>&1
    cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
    echo "PASS: $depth-bit $threading untiled threaded ME"
done

for threading in nowpp wpp; do
    if [ "$threading" = wpp ]; then threads='--pools 2 --wpp'; else threads='--pools none --no-wpp'; fi
    for mode in shared separate mcts; do
        case "$mode" in
            shared) tiles='--no-tile-slices' ;;
            separate) tiles='--slices-per-tile 2' ;;
            mcts) tiles='--mcts --slices-per-tile 2' ;;
        esac
        for option in motion qp distortion threaded; do
            case "$option" in
                motion) opts='--aq-mode 2 --aq-motion' ;;
                qp) opts='--rd 5 --aq-mode 2 --opt-cu-delta-qp' ;;
                distortion) opts='--bitrate 500 --multi-pass-opt-distortion' ;;
                threaded) opts='--pools 32 --frame-threads 2 --threaded-me' ;;
            esac
            if [ "$option" = distortion ]; then
                "$x265" --input "$tmp/input.yuv" --input-res 512x256 --fps 25 \
                    --frames 24 --output-depth "$depth" --preset medium --ctu 32 $threads \
                    --tile-columns 2 --tile-rows 2 $tiles $opts --pass 1 \
                    --stats "$tmp/stats" --analysis-reuse-file "$tmp/analysis.dat" \
                    --output "$tmp/first.hevc" >"$tmp/encoder.log" 2>&1
                set -- --pass 2 --stats "$tmp/stats" --analysis-reuse-file "$tmp/analysis.dat"
            else
                set --
            fi
            "$x265" --input "$tmp/input.yuv" --input-res 512x256 --fps 25 \
                --frames 24 --output-depth "$depth" --preset medium --ctu 32 $threads \
                --tile-columns 2 --tile-rows 2 $tiles $opts "$@" \
                --recon "$tmp/recon.yuv" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
            "$decoder" -b "$tmp/output.hevc" -o "$tmp/decoded.yuv" >"$tmp/decoder.log" 2>&1
            cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
            if [ "$option" = threaded ]; then
                check_threaded_me
            fi
            if [ "$depth" = 8 ] && [ "$threading" = nowpp ] && [ "$mode" = shared ]; then
                case "$option" in
                    motion) baseline='--aq-mode 2 --no-aq-motion' ;;
                    qp) baseline='--rd 5 --aq-mode 2 --no-opt-cu-delta-qp' ;;
                    distortion) baseline='--bitrate 500 --no-multi-pass-opt-distortion' ;;
                    threaded) baseline='--pools 32 --frame-threads 2 --no-threaded-me' ;;
                esac
                set --
                if [ "$option" = distortion ]; then
                    "$x265" --input "$tmp/input.yuv" --input-res 512x256 --fps 25 \
                        --frames 24 --output-depth "$depth" --preset medium --ctu 32 $threads \
                        --tile-columns 2 --tile-rows 2 $tiles $baseline --pass 1 \
                        --stats "$tmp/baseline.stats" --output "$tmp/first.hevc" >"$tmp/encoder.log" 2>&1
                    set -- --pass 2 --stats "$tmp/baseline.stats"
                fi
                "$x265" --input "$tmp/input.yuv" --input-res 512x256 --fps 25 \
                    --frames 24 --output-depth "$depth" --preset medium --ctu 32 $threads \
                    --tile-columns 2 --tile-rows 2 $tiles $baseline "$@" \
                    --recon "$tmp/baseline.yuv" --output "$tmp/first.hevc" >"$tmp/encoder.log" 2>&1
                if cmp -s "$tmp/recon.yuv" "$tmp/baseline.yuv"; then
                    echo "Option did not affect reconstruction: $option" >&2
                    exit 1
                fi
            fi
            if [ "$mode" = mcts ]; then
                gpac -i "$tmp/output.hevc" hevcsplit -o "$tmp/tiles.mp4" >"$tmp/encoder.log" 2>&1
                if [ "$depth" = 8 ]; then format=yuv420p; else format=yuv420p${depth}le; fi
                for tile in 0 1 2 3; do
                    x=$((tile % 2 * 256))
                    y=$((tile / 2 * 128))
                    ffmpeg -y -v error -f rawvideo -pixel_format "$format" -video_size 512x256 \
                        -framerate 25 -i "$tmp/recon.yuv" -vf "crop=256:128:$x:$y" \
                        -f framemd5 "$tmp/full.md5"
                    ffmpeg -y -v error -i "$tmp/tiles.mp4" -map "0:v:$tile" -f framemd5 "$tmp/tile.md5"
                    cmp "$tmp/full.md5" "$tmp/tile.md5"
                done
            fi
            echo "PASS: $depth-bit $threading $mode $option"
        done
    done
done

if [ "$depth" = 8 ]; then format=yuv420p; else format=yuv420p${depth}le; fi
for tile in 0 1 2 3; do
    x=$((tile % 2 * 256))
    y=$((tile / 2 * 128))
    ffmpeg -y -v error -f rawvideo -pixel_format yuv420p -video_size 512x256 \
        -framerate 25 -i "$tmp/input.yuv" -vf "crop=256:128:$x:$y" \
        -f rawvideo "$tmp/input$tile.yuv"
done
for threading in nowpp wpp; do
    if [ "$threading" = wpp ]; then wpp=--wpp; else wpp=--no-wpp; fi
    for tile in 0 1 2 3; do
        for pass in 1 2; do
            "$x265" --input "$tmp/input$tile.yuv" --input-res 256x128 --fps 25 \
                --frames 24 --output-depth "$depth" --preset medium --ctu 32 \
                --pools 32 --frame-threads 2 "$wpp" --threaded-me --mcts \
                --aq-mode 2 --aq-motion --rd 5 --opt-cu-delta-qp \
                --bitrate 125 --multi-pass-opt-distortion --pass "$pass" \
                --stats "$tmp/stats" --analysis-reuse-file "$tmp/analysis.dat" \
                --b-adapt 0 --scenecut 0 --keyint 24 --min-keyint 24 --repeat-headers \
                --recon "$tmp/recon$tile.yuv" --output "$tmp/tile$tile.hevc" >"$tmp/encoder.log" 2>&1
            check_threaded_me
        done
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
            -framerate 25 -i "$tmp/decoded.yuv" -vf "crop=256:128:$x:$y" \
            -f framemd5 "$tmp/full.md5"
        ffmpeg -y -v error -f rawvideo -pixel_format "$format" -video_size 256x128 \
            -framerate 25 -i "$tmp/recon$tile.yuv" -f framemd5 "$tmp/tile.md5"
        cmp "$tmp/full.md5" "$tmp/tile.md5"
    done
    echo "PASS: $depth-bit $threading single-tile MCTS with all four options"
done

ffmpeg -y -v error -f lavfi -i 'testsrc2=size=770x386:rate=25,scroll=horizontal=0.07:vertical=0.02' \
    -frames:v 16 -pix_fmt yuv420p -f rawvideo "$tmp/cropped.yuv"
for pass in 1 2; do
    "$x265" --input "$tmp/cropped.yuv" --input-res 770x386 --fps 25 \
        --frames 16 --output-depth "$depth" --preset medium --ctu 32 \
        --pools 32 --frame-threads 2 --wpp --threaded-me --mcts \
        --tile-columns 256,256 --tile-rows 128,128 --slices-per-tile 3 \
        --aq-mode 2 --aq-motion --rd 5 --opt-cu-delta-qp \
        --bitrate 500 --multi-pass-opt-distortion --pass "$pass" \
        --stats "$tmp/stats" --analysis-reuse-file "$tmp/analysis.dat" \
        --recon "$tmp/recon.yuv" --output "$tmp/output.hevc" >"$tmp/encoder.log" 2>&1
    check_threaded_me
done
"$decoder" -b "$tmp/output.hevc" -o "$tmp/decoded.yuv" >"$tmp/decoder.log" 2>&1
cmp "$tmp/recon.yuv" "$tmp/decoded.yuv"
gpac -i "$tmp/output.hevc" hevcsplit -o "$tmp/tiles.mp4" >"$tmp/encoder.log" 2>&1
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
    ffmpeg -y -v error -f rawvideo -pixel_format "$format" -video_size 770x386 \
        -framerate 25 -i "$tmp/recon.yuv" -vf "crop=$width:$height:$x:$y" \
        -f framemd5 "$tmp/full.md5"
    ffmpeg -y -v error -i "$tmp/tiles.mp4" -map "0:v:$tile" -f framemd5 "$tmp/tile.md5"
    cmp "$tmp/full.md5" "$tmp/tile.md5"
done
echo "PASS: $depth-bit non-uniform cropped MCTS with all four options"
