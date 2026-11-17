#include "x265.h"
#include "common.h"
#include "slice.h"
#include "level.h"

#include <stdio.h>
#include <vector>

static int testUntiledLegacySliceLevel()
{
    x265_param param;
    x265_param_default(&param);
    param.sourceWidth = 192;
    param.sourceHeight = 1984;
    param.fpsNum = 1;
    param.fpsDenom = 1;
    param.maxSlices = 31;
    param.bEnableWavefront = 1;
    param.logLevel = X265_LOG_NONE;

    X265_NS::VPS vps = {};
    X265_NS::determineLevel(param, vps);
    if (vps.ptl.levelIdc != X265_NS::Level::LEVEL3)
    {
        fprintf(stderr, "Legacy untiled slices changed automatic level selection\n");
        return 1;
    }

    param.levelIdc = 30;
    if (!X265_NS::enforceLevel(param, vps))
    {
        fprintf(stderr, "Legacy untiled slices rejected the requested level\n");
        return 1;
    }

    param.sourceWidth = 512;
    param.sourceHeight = 1024;
    param.maxSlices = 1;
    param.tileColumns = 2;
    param.bTileSlices = 1;
    param.slicesPerTile = 16;
    param.levelIdc = 0;
    X265_NS::determineLevel(param, vps);
    if (vps.ptl.levelIdc != X265_NS::Level::LEVEL3_1)
    {
        fprintf(stderr, "Tile slices did not raise the automatic level\n");
        return 1;
    }
    param.levelIdc = 30;
    if (X265_NS::enforceLevel(param, vps))
    {
        fprintf(stderr, "Tile slices exceeded the requested level\n");
        return 1;
    }
    return 0;
}

static int testSvtTileRejection()
{
    struct Option
    {
        const char* name;
        const char* value;
    };
    const Option options[] = {
        { "tile-columns", "256,256" }, { "tile-rows", "128,128" },
        { "tile-slices", "1" }, { "slices-per-tile", "2" },
        { "tile-columns", "0" }, { "tile-rows", "23" }, { "slices", "2" },
        { "loop-filter-across-tiles", "1" }
    };
    for (unsigned i = 0; i < sizeof(options) / sizeof(options[0]); i++)
    {
        x265_param* param = x265_param_alloc();
        if (!param)
            return 1;
        x265_param_default(param);
        param->bEnableSvtHevc = 1;
        if (i == 7)
            param->tileColumns = 2;
        param->logLevel = X265_LOG_NONE;
        if (x265_param_parse(param, options[i].name, options[i].value))
        {
            fprintf(stderr, "Unable to parse SVT tile option %s\n", options[i].name);
            x265_param_free(param);
            return 1;
        }
        bool configured = false;
        switch (i)
        {
        case 0: configured = param->tileColumnWidthCount == 2; break;
        case 1: configured = param->tileRowHeightCount == 2; break;
        case 2: configured = !!param->bTileSlices; break;
        case 3: configured = param->slicesPerTile == 2; break;
        case 4: configured = param->tileColumns == 0; break;
        case 5: configured = param->tileRows == 23; break;
        case 6: configured = param->maxSlices == 2; break;
        case 7: configured = param->bLoopFilterAcrossTiles == 1; break;
        }
        if (!configured)
        {
            fprintf(stderr, "SVT ignored tile option %s\n", options[i].name);
            x265_param_free(param);
            return 1;
        }
        x265_encoder* encoder = x265_encoder_open(param);
        if (encoder)
        {
            fprintf(stderr, "SVT accepted tile option %s\n", options[i].name);
            x265_encoder_close(encoder);
            x265_param_free(param);
            return 1;
        }
        x265_param_free(param);
    }
    return 0;
}

static int testTileParameters()
{
    x265_param* param = x265_param_alloc();
    if (!param || x265_param_default_preset(param, "ultrafast", "zerolatency"))
        return 1;
    param->sourceWidth = 770;
    param->sourceHeight = 386;
    param->confWinRightOffset = 62;
    param->confWinBottomOffset = 62;
    param->fpsNum = 30;
    param->fpsDenom = 1;
    param->maxCUSize = 64;
    param->bEnableWavefront = 0;
    param->bEnableTemporalMvp = 0;
    param->tileColumnWidthCount = 2;
    param->tileColumnWidths[0] = param->tileColumnWidths[1] = 256;
    param->tileRowHeightCount = 2;
    param->tileRowHeights[0] = param->tileRowHeights[1] = 128;
    param->slicesPerTile = 2;
    param->logLevel = X265_LOG_ERROR;
    x265_encoder* encoder = x265_encoder_open(param);
    if (!encoder)
    {
        x265_param_free(param);
        return 1;
    }
    x265_encoder_parameters(encoder, param);
    bool valid = param->bTileSlices && param->tileColumns == 3 && param->tileRows == 3 &&
                 param->tileColumnWidthCount == 3 && param->tileRowHeightCount == 3 &&
                 param->tileColumnWidths[2] == 320 && param->tileRowHeights[2] == 192;
    x265_encoder_close(encoder);
    x265_param_free(param);
    if (!valid)
        fprintf(stderr, "Explicit tile dimensions were not normalized or copied correctly\n");
    return !valid;
}

static int testTileVbvAccounting(int annexB)
{
    const int width = 512, height = 128;
    x265_param* param = x265_param_alloc();
    if (!param || x265_param_default_preset(param, "ultrafast", "zerolatency"))
        return 1;
    param->sourceWidth = width;
    param->sourceHeight = height;
    param->fpsNum = 30;
    param->fpsDenom = 1;
    param->frameNumThreads = 1;
    param->bEnableWavefront = 0;
    param->bEnableSAO = 0;
    param->bEnableTemporalMvp = 0;
    param->tileColumns = 2;
    param->bTileSlices = 1;
    param->bAnnexB = annexB;
    param->bRepeatHeaders = 1;
    param->rc.rateControlMode = X265_RC_ABR;
    param->rc.bitrate = 2000;
    param->rc.vbvMaxBitrate = 2000;
    param->rc.vbvBufferSize = 2000;
    param->logLevel = X265_LOG_ERROR;

    x265_encoder* encoder = x265_encoder_open(param);
    if (!encoder)
    {
        x265_param_free(param);
        return 1;
    }

    const int bytesPerSample = param->internalBitDepth > 8 ? 2 : 1;
    std::vector<uint8_t> pixels(width * height * 3 / 2 * bytesPerSample, 0);
    uint8_t seiData[512] = { 0 };
    uint8_t rpuData[64] = { 0 };
    x265_sei_payload payload = { sizeof(seiData), USER_DATA_UNREGISTERED, seiData };
    x265_picture pic;
    x265_picture_init(param, &pic);
    pic.planes[0] = &pixels[0];
    pic.planes[1] = &pixels[width * height * bytesPerSample];
    pic.planes[2] = &pixels[width * height * 5 / 4 * bytesPerSample];
    pic.stride[0] = width * bytesPerSample;
    pic.stride[1] = pic.stride[2] = width / 2 * bytesPerSample;
    pic.userSEI.numPayloads = 1;
    pic.userSEI.payloads = &payload;
    pic.rpu.payload = rpuData;
    pic.rpu.payloadSize = sizeof(rpuData);

    x265_nal* nals = NULL;
    uint32_t count = 0;
    int encoded = x265_encoder_encode(encoder, &nals, &count, &pic, NULL);
    uint64_t expectedBits = 0;
    bool hasSei = false, hasRpu = false;
    for (uint32_t i = 0; i < count; i++)
    {
        int prefix = annexB && nals[i].payload[2] == 1 ? 3 : 4;
        expectedBits += (nals[i].sizeBytes - prefix) * 8;
        hasSei |= nals[i].type == NAL_UNIT_PREFIX_SEI;
        hasRpu |= nals[i].type == NAL_UNIT_UNSPECIFIED;
    }
    x265_stats stats;
    x265_encoder_get_stats(encoder, &stats, sizeof(stats));
    bool valid = encoded == 1 && hasSei && hasRpu && stats.accBits == expectedBits;
    if (!valid)
        fprintf(stderr, "Tile VBV accounting mismatch (annexB=%d, expected=%llu, actual=%llu)\n",
                annexB, (unsigned long long)expectedBits, (unsigned long long)stats.accBits);
    x265_encoder_close(encoder);
    x265_param_free(param);
    return !valid;
}

int main()
{
    if (testUntiledLegacySliceLevel() || testSvtTileRejection() || testTileParameters() || testTileVbvAccounting(1) || testTileVbvAccounting(0))
        return 1;
    const int width = 1280, height = 1408;
    const int tileCount = 20 * 22, payloadCount = 700;
    x265_param* param = x265_param_alloc();
    if (!param || x265_param_default_preset(param, "ultrafast", "zerolatency"))
        return 1;
    param->sourceWidth = width;
    param->sourceHeight = height;
    param->fpsNum = 30;
    param->fpsDenom = 1;
    param->frameNumThreads = 1;
    param->maxCUSize = 64;
    param->bEnableWavefront = 0;
    param->bEnableSAO = 0;
    param->bEnableTemporalMvp = 0;
    param->tileColumns = 20;
    param->tileRows = 22;
    param->bAllowNonConformance = 1;
    param->bEnableMcts = 1;
    param->bRepeatHeaders = 1;
    param->bSingleSeiNal = 0;
    param->logLevel = X265_LOG_ERROR;

    x265_encoder* encoder = x265_encoder_open(param);
    if (!encoder)
    {
        x265_param_free(param);
        return 1;
    }
    x265_encoder_parameters(encoder, param);
    if (!param->bTileSlices)
    {
        fprintf(stderr, "MCTS did not enable tile slices in encoder parameters\n");
        x265_encoder_close(encoder);
        x265_param_free(param);
        return 1;
    }

    const int bytesPerSample = param->internalBitDepth > 8 ? 2 : 1;
    std::vector<uint8_t> pixels(width * height * 3 / 2 * bytesPerSample, 0);
    uint8_t seiData[16] = { 0 };
    x265_sei_payload payloads[payloadCount];
    for (int i = 0; i < payloadCount; i++)
    {
        payloads[i].payload = seiData;
        payloads[i].payloadSize = sizeof(seiData);
        payloads[i].payloadType = USER_DATA_UNREGISTERED;
    }
    x265_picture pic;
    x265_picture_init(param, &pic);
    pic.planes[0] = &pixels[0];
    pic.planes[1] = &pixels[width * height * bytesPerSample];
    pic.planes[2] = &pixels[width * height * 5 / 4 * bytesPerSample];
    pic.stride[0] = width * bytesPerSample;
    pic.stride[1] = pic.stride[2] = width / 2 * bytesPerSample;

    int result = 0;
    for (int frame = 0; frame < 3; frame++)
    {
        pic.pts = frame;
        pic.userSEI.numPayloads = frame == 1 ? 0 : payloadCount;
        pic.userSEI.payloads = payloads;
        x265_nal* nals = NULL;
        uint32_t count = 0;
        int encoded = x265_encoder_encode(encoder, &nals, &count, &pic, NULL);
        int slices = 0, prefixSei = 0;
        for (uint32_t i = 0; i < count; i++)
        {
            if (nals[i].type < 32)
                slices++;
            if (nals[i].type == NAL_UNIT_PREFIX_SEI)
                prefixSei++;
            if (!nals[i].payload || !nals[i].sizeBytes)
                result = 1;
        }
        if (encoded != 1 || slices != tileCount || prefixSei < pic.userSEI.numPayloads ||
            (pic.userSEI.numPayloads && count <= 1024))
        {
            fprintf(stderr, "frame %d: encoded=%d, NALs=%u, slices=%d, prefix SEI=%d\n",
                    frame, encoded, count, slices, prefixSei);
            result = 1;
            break;
        }
    }
    x265_encoder_close(encoder);
    x265_param_free(param);
    return result;
}
