/** \file   opengl_pacing.c
 * \brief   Frame pacing for the OpenGL renderer on X11 (Linux, BSD) and macOS
 *
 * With VSync on, presents follow a steady clock at the emulated frame rate
 * instead of the bursty, audio-driven frame delivery of the emulator. This is
 * the same method as the Windows DirectX renderer uses (see
 * directx_renderer_impl.cc), with POSIX timing, or Mach timing on macOS.
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

#ifndef OPENGL_PACING_STANDALONE
#include "vice.h"
#include "log.h"
#endif

#include <errno.h>
#include <math.h>
#include <sched.h>
#include <string.h>
#include <time.h>
#ifdef LINUX_COMPILE
#include <sys/prctl.h>
#endif
#if defined(MACOS_COMPILE) || defined(__APPLE__)
#include <mach/mach_time.h>
#endif

#include "opengl_pacing.h"

/** \brief Frames this much later than planned restart the pacing (pause, menus, ...) */
#define PACING_RESET_MS             100.0

/** \brief Frames per block of the latency history; unneeded latency is trimmed after each (about 5 s) */
#define PACING_BLOCK_FRAMES         250

/** \brief Blocks in the latency history: the latency kept covers the worst frame of the last 30 s */
#define PACING_BLOCKS               OPENGL_PACING_HISTORY_BLOCKS

/** \brief Safety margin kept between the latest frame seen and its present */
#define PACING_MARGIN_MS            2.0

/** \brief Frames after a (re)start during which late frames just move the clock (1 s) */
#define PACING_WARMUP_FRAMES        50

/** \brief Latency kept at the start, before anything is known */
#define PACING_START_MS             6.0

/** \brief Most the clock moves earlier per frame when trimming latency */
#define PACING_SLEW_EARLIER_MS      0.05

/** \brief Most the clock moves later per frame after a late frame */
#define PACING_SLEW_LATER_MS        0.5

/** \brief Emulated frame rate this far from the nominal one is a speed change, not drift */
#define PACING_SPEED_CHANGE         0.01

/**
 * \brief Show each frame twice when the display is at least this much faster
 *
 * VRR displays have a minimum refresh rate (often 48 Hz). Near it (PAL is
 * 50.125 Hz) the driver inserts extra refreshes on its own, and a new frame
 * that arrives during one is delayed by up to a full scan. Presenting every
 * frame twice, evenly spaced, keeps the display at ~100 Hz, well inside the
 * VRR range. The picture still changes exactly once per emulated frame.
 */
#define PACING_DOUBLE_MIN_RATIO     2.2

/** \brief Sleep until this long before the target, then spin for precision (ms) */
#define PACING_SPIN_MS              0.5


/**
 * \brief Current time of the pacing clock (ms)
 *
 * On macOS CLOCK_UPTIME_RAW, the clock of mach_absolute_time() that
 * mach_wait_until() sleeps on. Ref: man 3 clock_gettime (macOS)
 */
double opengl_pacing_now_ms(void)
{
    struct timespec now;

#if defined(MACOS_COMPILE) || defined(__APPLE__)
    clock_gettime(CLOCK_UPTIME_RAW, &now);
#else
    clock_gettime(CLOCK_MONOTONIC, &now);
#endif
    return (double)now.tv_sec * 1000.0 + (double)now.tv_nsec / 1000000.0;
}


/** \brief Set up the pacing state of a new canvas */
void opengl_pacing_init(opengl_pacing_t *pacing)
{
    memset(pacing, 0, sizeof(*pacing));
    pacing->period_ms = 20.0;
    pacing->logged_display_hz = -1;
}


/** \brief Stop pacing (VSync off, warp): the next paced frame restarts it */
void opengl_pacing_stop(opengl_pacing_t *pacing)
{
    pacing->next_ms = 0.0;
}


/**
 * \brief Prepare the render thread for precise waits
 *
 * Asks for the smallest timer slack (Linux), so sleeps end on time. A higher
 * scheduling priority would need privileges, so it isn't attempted.
 */
void opengl_pacing_thread_init(void)
{
#if defined(LINUX_COMPILE) && defined(PR_SET_TIMERSLACK)
    prctl(PR_SET_TIMERSLACK, 1UL, 0UL, 0UL, 0UL);
#endif
}


/** \brief Wait until \a target_ms: sleep for most of it, then spin for precision */
void opengl_pacing_wait_until(double target_ms)
{
    double remaining = target_ms - opengl_pacing_now_ms();

    if (remaining <= 0.0) {
        return;
    }

#if defined(MACOS_COMPILE) || defined(__APPLE__)
    {
        /* A real-time thread sleeps on mach_wait_until(), which is precise
         * enough without spinning, and must not spin.
         * Ref: https://developer.apple.com/library/archive/technotes/tn2169/_index.html
         */
        static mach_timebase_info_data_t timebase;

        if (timebase.denom == 0) {
            mach_timebase_info(&timebase);
        }
        mach_wait_until(mach_absolute_time()
                        + (uint64_t)(remaining * 1000000.0 * timebase.denom / timebase.numer));
    }
#else
    if (remaining > PACING_SPIN_MS) {
        double wake_ms = target_ms - PACING_SPIN_MS;
        struct timespec wake;

        wake.tv_sec = (time_t)(wake_ms / 1000.0);
        wake.tv_nsec = (long)((wake_ms - (double)wake.tv_sec * 1000.0) * 1000000.0);
        if (wake.tv_nsec >= 1000000000L) {
            wake.tv_sec++;
            wake.tv_nsec -= 1000000000L;
        } else if (wake.tv_nsec < 0) {
            wake.tv_nsec = 0;
        }
        while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &wake, NULL) == EINTR) {
            /* interrupted by a signal: sleep the rest */
        }
    }

    while (opengl_pacing_now_ms() < target_ms) {
        sched_yield();
    }
#endif
}


/** \brief Should each frame be presented twice (see PACING_DOUBLE_MIN_RATIO) */
bool opengl_pacing_should_double(opengl_pacing_t *pacing)
{
    int hz = pacing->display_hz;
    bool twice = hz > 1 && hz * pacing->period_ms >= 1000.0 * PACING_DOUBLE_MIN_RATIO;

    if (hz != pacing->logged_display_hz) {
        pacing->logged_display_hz = hz;
#ifndef OPENGL_PACING_STANDALONE
        if (hz > 1) {
            log_message(LOG_DEFAULT, "OpenGL: display refresh %d Hz, frame pacing presents each frame %s",
                        hz, twice ? "twice" : "once");
        }
#endif
    }

    return twice;
}


/**
 * \brief Decide when to present a new frame
 *
 * Presents follow a steady clock at the emulated frame rate. The emulator
 * delivers frames in bursts, so the clock runs a little behind them, by the
 * latest a frame arrived in the last PACING_BLOCKS * PACING_BLOCK_FRAMES
 * frames plus a margin.
 *
 * Besides the frame arriving, drawing it can take a while now and then (the
 * GPU busy with something else); opengl_pacing_ready() takes that into
 * account too.
 *
 * The clock is never moved in one step, as every jump shows as a hitch in
 * scrolling: unneeded latency is trimmed slowly, and after a late frame (shown
 * at once) the clock moves later over several frames. Clock drift between the
 * audio device (which paces the emulator) and the system timer is absorbed the
 * same way.
 *
 * \param[in,out]   pacing          pacing state
 * \param[in]       completed_ms    when the emulator finished the frame
 * \param[in]       queued          frames waiting behind this one
 *
 * \return  time to present the frame at (ms)
 */
double opengl_pacing_schedule(opengl_pacing_t *pacing, double completed_ms, unsigned int queued,
                             double now_ms, double nominal, unsigned int capacity)
{
    double planned;
    double target;
    double slack;
    double step;

    /* Measure the actual frame rate (slowly), to notice speed changes */
    if (pacing->measured_ms <= 0.0) {
        pacing->measured_ms = nominal;
    } else if (pacing->last_completed_ms > 0.0) {
        double interval = completed_ms - pacing->last_completed_ms;
        if (interval > 0.0 && interval < nominal * 4.0) {
            pacing->measured_ms += (interval - pacing->measured_ms) * 0.002;
        }
    }
    pacing->last_completed_ms = completed_ms;

    /* The nominal rate, unless the emulator clearly runs at another speed */
    if (fabs(pacing->measured_ms - nominal) > nominal * PACING_SPEED_CHANGE) {
        pacing->period_ms = pacing->measured_ms;
    } else {
        pacing->period_ms = nominal;
    }

    if (pacing->next_ms <= 0.0 || completed_ms > pacing->next_ms + PACING_RESET_MS) {
        /* (Re)start in step with this frame */
        int i;

        pacing->next_ms = completed_ms + PACING_START_MS;
        pacing->min_wait_ms = 1e9;
        pacing->window_frames = 0;
        for (i = 0; i < PACING_BLOCKS; i++) {
            pacing->block_min_ms[i] = 1e9; /* nothing known yet */
        }
        pacing->block_index = 0;
        pacing->adjust_ms = 0.0;
        pacing->shift_ms = 0.0;
        pacing->frames = 0;
    }
    if (pacing->frames < PACING_WARMUP_FRAMES) {
        pacing->frames++;
    }

    planned = pacing->next_ms;
    pacing->dequeued_ms = now_ms;
    slack = planned - completed_ms;
    target = planned;

    if (slack < 0.0) {
        /* Late: show it as soon as it exists */
        target = completed_ms;
        if (pacing->frames < PACING_WARMUP_FRAMES) {
            /* the start is bumpy and a jump doesn't show yet: just follow */
            planned = completed_ms;
            slack = 0.0;
        } else if (pacing->adjust_ms < PACING_MARGIN_MS - slack) {
            /* move the clock later, gradually */
            pacing->adjust_ms = PACING_MARGIN_MS - slack;
        }
    }
    pacing->planned_ms = planned;

    if (queued + 1 >= capacity) {
        /* Queue about to overflow (emulator ran ahead): show it now, or frames get dropped */
        if (target > now_ms) {
            target = now_ms;
        }
    } else if (queued >= 2 && pacing->adjust_ms > -pacing->period_ms * 0.5) {
        /* More latency than needed: trim it, faster than usual but still gradually */
        pacing->adjust_ms = -pacing->period_ms * 0.5;
    }

    /*
     * Least slack in the block, as if all shifts done since had been there
     * from the start, so trimming doesn't count the same latency twice.
     */
    if (slack - pacing->shift_ms < pacing->min_wait_ms) {
        pacing->min_wait_ms = slack - pacing->shift_ms;
    }
    if (++pacing->window_frames >= PACING_BLOCK_FRAMES) {
        double worst = 1e9;
        double projected;
        int i;

        pacing->block_min_ms[pacing->block_index] = pacing->min_wait_ms;
        pacing->block_index = (pacing->block_index + 1) % PACING_BLOCKS;
        for (i = 0; i < PACING_BLOCKS; i++) {
            if (pacing->block_min_ms[i] < worst) {
                worst = pacing->block_min_ms[i];
            }
        }

        /* the least slack once all shifts in progress are done */
        projected = worst + pacing->shift_ms + pacing->adjust_ms;
        if (projected > PACING_MARGIN_MS + 0.5) {
            pacing->adjust_ms -= projected - PACING_MARGIN_MS;
        }
        pacing->min_wait_ms = 1e9;
        pacing->window_frames = 0;
    }

    /* Move the clock gradually */
    step = pacing->adjust_ms;
    if (step > PACING_SLEW_LATER_MS) {
        step = PACING_SLEW_LATER_MS;
    } else if (step < -(queued >= 2 ? PACING_SLEW_LATER_MS : PACING_SLEW_EARLIER_MS)) {
        step = -(queued >= 2 ? PACING_SLEW_LATER_MS : PACING_SLEW_EARLIER_MS);
    }
    pacing->adjust_ms -= step;
    pacing->shift_ms += step;

    pacing->next_ms = planned + pacing->period_ms + step;

    return target;
}


/**
 * \brief Note when a paced frame was drawn and ready to be presented
 *
 * Like a frame arriving late, a frame that took long to draw moves the clock
 * later (gradually), and the latency kept covers the slowest draw in the
 * history.
 *
 * \param[in,out]   pacing  pacing state
 */
void opengl_pacing_ready(opengl_pacing_t *pacing, double planned_ms,
                         double completed_ms, double draw_ms)
{
    double slack;

    if (pacing->frames < PACING_WARMUP_FRAMES) {
        return; /* the first frames are slow to draw (shaders, textures) */
    }

    /* as if the frame had arrived that much later: when it was finished plus how long drawing it took */
    slack = planned_ms - (completed_ms + draw_ms);

    if (slack < 0.0 && pacing->adjust_ms < PACING_MARGIN_MS - slack) {
        pacing->adjust_ms = PACING_MARGIN_MS - slack;
    }
    if (slack - pacing->shift_ms < pacing->min_wait_ms) {
        pacing->min_wait_ms = slack - pacing->shift_ms;
    }
}
