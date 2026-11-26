/** \file   opengl_pacing.h
 * \brief   Frame pacing for the OpenGL renderer on X11 (Linux, BSD) and macOS
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

#ifndef VICE_OPENGL_PACING_H
#define VICE_OPENGL_PACING_H

#include <stdbool.h>

/** \brief Blocks of frames in the latency history (see opengl_pacing.c) */
#define OPENGL_PACING_HISTORY_BLOCKS 6

/** \brief Frame pacing state of one canvas (render thread only, except display_hz) */
typedef struct opengl_pacing_s {
    /** \brief nominal time between presents (ms) */
    double period_ms;

    /** \brief slowly measured time between emulated frames (ms) */
    double measured_ms;

    /** \brief planned present time of the next frame (ms), 0 = not running */
    double next_ms;

    /** \brief planned present time of the current frame (ms) */
    double planned_ms;

    /** \brief when the current frame was taken from the queue (ms) */
    double dequeued_ms;

    /** \brief clock shift still to be done (ms, > 0 = later) */
    double adjust_ms;

    /** \brief clock shift done since the pacing started (ms) */
    double shift_ms;

    /** \brief completion time of the previous frame (ms) */
    double last_completed_ms;

    /** \brief least slack seen in the current block, without shifts (ms) */
    double min_wait_ms;

    /** \brief least slack of each recent block of frames, without shifts (ms) */
    double block_min_ms[OPENGL_PACING_HISTORY_BLOCKS];

    /** \brief block of block_min_ms[] filled next */
    int block_index;

    /** \brief frames seen in the current block */
    int window_frames;

    /** \brief frames since the pacing (re)started, up to the warm-up count */
    int frames;

    /** \brief display refresh rate (Hz) last logged, -1 = nothing logged */
    int logged_display_hz;

    /**
     * \brief refresh rate of the monitor showing the window (Hz), 0 = unknown
     *
     * Written by the UI thread (GDK may only be used there), read by the
     * render thread.
     */
    volatile int display_hz;
} opengl_pacing_t;

double opengl_pacing_now_ms(void);
void   opengl_pacing_init(opengl_pacing_t *pacing);
void   opengl_pacing_stop(opengl_pacing_t *pacing);
double opengl_pacing_schedule(opengl_pacing_t *pacing, double completed_ms, unsigned int queued,
                             double now_ms, double nominal_ms, unsigned int capacity);
void   opengl_pacing_ready(opengl_pacing_t *pacing, double planned_ms,
                          double completed_ms, double draw_ms);
bool   opengl_pacing_should_double(opengl_pacing_t *pacing);
void   opengl_pacing_wait_until(double target_ms);
void   opengl_pacing_thread_init(void);

#endif
