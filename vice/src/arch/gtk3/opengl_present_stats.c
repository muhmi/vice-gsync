/** \file   opengl_present_stats.c
 * \brief   Present timing log of the OpenGL renderer (VICE_PRESENT_STATS)
 *
 * With the environment variable VICE_PRESENT_STATS set to a file name, every
 * present is written to that file as a CSV line, and a summary of the last
 * few seconds goes to the VICE log. present_stats.py turns the file into a
 * histogram. Without the variable nothing is measured.
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

#include "vice.h"

#include <math.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "log.h"
#include "vsync.h"

#include "opengl_present_stats.h"

/** \brief Length of a summary period (ms) */
#define STATS_PERIOD_MS     5000.0


/** \brief Start a summary period at \a now_ms */
static void stats_reset(opengl_present_stats_t *stats, double now_ms, unsigned int dropped)
{
    stats->period_start_ms = now_ms;
    stats->frames = 0;
    stats->interval_sum = 0.0;
    stats->interval_sum_sq = 0.0;
    stats->interval_min = 1e9;
    stats->interval_max = 0.0;
    stats->late = 0;
    stats->bunched = 0;
    stats->repeats = 0;
    stats->redraws = 0;
    stats->latency_sum = 0.0;
    stats->latency_max = 0.0;
    stats->dropped_start = dropped;
}


/** \brief Open the log named by VICE_PRESENT_STATS, if set */
void opengl_present_stats_init(opengl_present_stats_t *stats)
{
    const char *path = getenv("VICE_PRESENT_STATS");

    memset(stats, 0, sizeof(*stats));
    if (path == NULL || *path == '\0') {
        return;
    }

    stats->file = fopen(path, "w");
    if (stats->file == NULL) {
        log_error(LOG_DEFAULT, "OpenGL: cannot write present stats to %s", path);
        return;
    }
    setvbuf(stats->file, NULL, _IOFBF, 1 << 20);
    fprintf(stats->file, "kind,completed_ms,target_ms,ready_ms,done_ms,queued,dropped,emulated_hz\n");
    log_message(LOG_DEFAULT, "OpenGL: writing present stats to %s", path);
}


/**
 * \brief Note one present
 *
 * \param[in,out]   stats           stats state
 * \param[in]       kind            what was presented
 * \param[in]       completed_ms    when the emulator finished the frame
 * \param[in]       target_ms       when the pacing wanted it shown, 0 = at once
 * \param[in]       ready_ms        when the present was called
 * \param[in]       done_ms         when the present and glFinish() returned
 * \param[in]       queued          frames waiting behind this one
 * \param[in]       dropped         frames dropped so far (render queue full)
 */
void opengl_present_stats_record(opengl_present_stats_t *stats,
                                 opengl_present_kind_t kind,
                                 double completed_ms,
                                 double target_ms,
                                 double ready_ms,
                                 double done_ms,
                                 unsigned int queued,
                                 unsigned int dropped)
{
    double refresh = vsync_get_refresh_frequency();
    double nominal = refresh > 1.0 ? 1000.0 / refresh : 20.0;

    if (stats->file == NULL) {
        return;
    }

    fprintf(stats->file, "%c,%.3f,%.3f,%.3f,%.3f,%u,%u,%.4f\n",
            (char)kind, completed_ms, target_ms, ready_ms, done_ms, queued, dropped, refresh);

    if (stats->period_start_ms <= 0.0) {
        stats_reset(stats, done_ms, dropped);
    }

    switch (kind) {
        case OPENGL_PRESENT_NEW:
            if (stats->last_new_ms > 0.0) {
                double interval = done_ms - stats->last_new_ms;

                stats->frames++;
                stats->interval_sum += interval;
                stats->interval_sum_sq += interval * interval;
                if (interval < stats->interval_min) {
                    stats->interval_min = interval;
                }
                if (interval > stats->interval_max) {
                    stats->interval_max = interval;
                }
                if (interval > nominal * 1.5) {
                    stats->late++;
                } else if (interval < nominal * 0.5) {
                    stats->bunched++;
                }
                stats->latency_sum += done_ms - completed_ms;
                if (done_ms - completed_ms > stats->latency_max) {
                    stats->latency_max = done_ms - completed_ms;
                }
            }
            stats->last_new_ms = done_ms;
            break;
        case OPENGL_PRESENT_REPEAT:
            stats->repeats++;
            break;
        case OPENGL_PRESENT_REDRAW:
            stats->redraws++;
            stats->last_new_ms = 0.0; /* paused: the next interval means nothing */
            break;
    }

    if (done_ms - stats->period_start_ms >= STATS_PERIOD_MS) {
        if (stats->frames > 0) {
            double mean = stats->interval_sum / stats->frames;
            double var = stats->interval_sum_sq / stats->frames - mean * mean;

            log_message(LOG_DEFAULT,
                        "OpenGL present stats: %u frames, interval mean %.3f sd %.3f min %.3f max %.3f ms,"
                         " late %u, bunched %u, repeats %u, redraws %u, dropped %u, latency mean %.2f max %.2f ms,"
                         " new interval/nominal %.6f (nominal %.6f ms)",
                        stats->frames, mean, var > 0.0 ? sqrt(var) : 0.0,
                        stats->interval_min, stats->interval_max,
                        stats->late, stats->bunched, stats->repeats, stats->redraws,
                        dropped - stats->dropped_start,
                         stats->latency_sum / stats->frames, stats->latency_max, mean / nominal, nominal);
        }
        fflush(stats->file);
        stats_reset(stats, done_ms, dropped);
    }
}
