/*****************************************************************************
 * Copyright (C) 2013-2020 MulticoreWare, Inc
 *
 * Authors: Deepthi Nandakumar <deepthi@multicorewareinc.com>
 *          Praveen Kumar Tiwari <praveen@multicorewareinc.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02111, USA.
 *
 * This program is also available under a commercial proprietary license.
 * For more information, contact us at license @ x265.com.
 *****************************************************************************/

#ifndef X265_PARAM_H
#define X265_PARAM_H

namespace X265_NS {

static inline const char* x265_svt_tile_error(const x265_param* param)
{
    if (!param->bEnableSvtHevc)
        return NULL;
    if (param->tileColumnWidthCount || param->tileRowHeightCount)
        return "SVT-HEVC integration does not support non-uniform tiles";
    if (param->tileColumns < 1 || param->tileColumns > 20 || param->tileRows < 1 || param->tileRows > 22)
        return "SVT-HEVC tile counts must be between 1 and 20 columns and 1 and 22 rows";
    if (param->slicesPerTile != 1 || param->maxSlices != 1)
        return "SVT-HEVC integration does not support multiple slices per tile or picture";
    if (param->bTileSlices < 0 || param->bTileSlices > 1 ||
        (param->bTileSlices && !param->bEnableMcts && param->tileColumns == 1 && param->tileRows == 1))
        return "SVT-HEVC tile slices require multiple tiles";
    if (param->bLoopFilterAcrossTiles < -1 || param->bLoopFilterAcrossTiles > 1)
        return "loop-filter-across-tiles must be -1, 0 or 1";
    if (param->bLoopFilterAcrossTiles == 1 &&
        (param->bEnableMcts || param->tileColumns > 1 || param->tileRows > 1))
        return "SVT-HEVC does not support loop filtering across tile boundaries";
    return NULL;
}

int   x265_check_params(x265_param *param);
int   x265_normalize_tile_params(x265_param *param);
bool  x265_tiles_fit_profile(const x265_param *param, bool configured = false);
void  x265_print_params(x265_param *param);
void  x265_param_apply_fastfirstpass(x265_param *p);
char* x265_param2string(x265_param *param, int padx, int pady);
int   x265_atoi(const char *str, bool& bError);
double x265_atof(const char *str, bool& bError);
int   parseCpuName(const char *value, bool& bError, bool bEnableavx512);
void  setParamAspectRatio(x265_param *p, int width, int height);
void  getParamAspectRatio(x265_param *p, int& width, int& height);
bool  parseLambdaFile(x265_param *param);
void x265_copy_params(x265_param* dst, x265_param* src);
bool parseMaskingStrength(x265_param* p, const char* value);

/* this table is kept internal to avoid confusion, since log level indices start at -1 */
static const char * const logLevelNames[] = { "none", "error", "warning", "info", "debug", "full", 0 };

#if EXPORT_C_API
#define PARAM_NS
#else
/* declare param functions within private namespace */
void x265_param_free(x265_param *);
x265_param* x265_param_alloc();
void x265_param_default(x265_param *param);
int x265_param_default_preset(x265_param *, const char *preset, const char *tune);
int x265_param_apply_profile(x265_param *, const char *profile);
int x265_param_parse(x265_param *p, const char *name, const char *value);
int x265_scenecut_aware_qp_param_parse(x265_param* p, const char* name, const char* value);
int x265_zone_param_parse(x265_param* p, const char* name, const char* value);
#define PARAM_NS X265_NS
#endif
}
#endif // ifndef X265_PARAM_H
