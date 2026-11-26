/** \file   opengl_present_stats.h
 * \brief   Present timing log of the OpenGL renderer (VICE_PRESENT_STATS)
 */

/*
 * This file is part of VICE, the Versatile Commodore Emulator.
 * See README for copyright notice.
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
 *  02111-1307  USA.
 *
 */

#ifndef VICE_OPENGL_PRESENT_STATS_H
#define VICE_OPENGL_PRESENT_STATS_H

#include <stdio.h>

/** \brief What a present showed */
typedef enum opengl_present_kind_e {
    OPENGL_PRESENT_NEW = 'N',       /**< a new emulated frame */
    OPENGL_PRESENT_REPEAT = 'R',    /**< the same frame again (frame doubling) */
    OPENGL_PRESENT_REDRAW = 'D'     /**< a redraw without a new frame (pause, monitor, resize) */
} opengl_present_kind_t;

/** \brief Present timing of one canvas (render thread only) */
typedef struct opengl_present_stats_s {
    /** \brief per-present log, NULL = stats off */
    FILE *file;

    /** \brief start of the current summary period (ms) */
    double period_start_ms;

    /** \brief when the previous new frame was presented (ms), 0 = none yet */
    double last_new_ms;

    /** \brief new frames presented in the current summary period */
    unsigned int frames;

    /** \brief sum of the intervals between new frames (ms) */
    double interval_sum;

    /** \brief sum of the squared intervals between new frames (ms^2) */
    double interval_sum_sq;

    /** \brief shortest interval between new frames (ms) */
    double interval_min;

    /** \brief longest interval between new frames (ms) */
    double interval_max;

    /** \brief intervals longer than 1.5 emulated frames */
    unsigned int late;

    /** \brief intervals shorter than half an emulated frame */
    unsigned int bunched;

    /** \brief frames presented a second time (frame doubling) */
    unsigned int repeats;

    /** \brief redraws without a new frame */
    unsigned int redraws;

    /** \brief sum of the latencies from frame completion to present (ms) */
    double latency_sum;

    /** \brief longest latency from frame completion to present (ms) */
    double latency_max;

    /** \brief frames dropped (render queue full) when the period started */
    unsigned int dropped_start;
} opengl_present_stats_t;

void opengl_present_stats_init(opengl_present_stats_t *stats);
void opengl_present_stats_record(opengl_present_stats_t *stats,
                                 opengl_present_kind_t kind,
                                 double completed_ms,
                                 double target_ms,
                                 double ready_ms,
                                 double done_ms,
                                 unsigned int queued,
                                 unsigned int dropped);

#endif
