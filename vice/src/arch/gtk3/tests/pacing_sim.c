#include "../opengl_pacing.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static double schedule(opengl_pacing_t *p, double completed, double now, unsigned int queued)
{
    return opengl_pacing_schedule(p, completed, queued, now, 19.95, 4);
}

int main(void)
{
    opengl_pacing_t p;
    opengl_pacing_init(&p);
    double previous = 0;
    for (int i = 0; i < 3000; i++) {
        double arrived = 1000 + ceil(i * 19.95 / 10) * 10;
        double target = schedule(&p, arrived, arrived, 0);
        if (i > 500) assert(fabs(target - previous - 19.95) < 0.051);
        previous = target;
    }
    double target = schedule(&p, previous, previous, 3);
    assert(target <= previous);
    opengl_pacing_stop(&p);
    assert(p.next_ms == 0);
    target = schedule(&p, 100000, 100000, 0);
    assert(target == 100006);
    target = schedule(&p, 200000, 200000, 0);
    assert(target == 200006 && p.frames == 1);

    opengl_pacing_init(&p);
    for (int i = 0; i < 4000; i++) schedule(&p, 1000 + i * 19.95 / 0.9, 1000 + i * 19.95 / 0.9, 0);
    assert(fabs(p.period_ms - 19.95 / 0.9) < 0.01);

    opengl_pacing_init(&p);
    for (int i = 0; i < 100; i++) schedule(&p, 1000 + i * 19.95, 1000 + i * 19.95, 0);
    double planned = p.planned_ms;
    double completed = p.last_completed_ms;
    schedule(&p, completed + 19.95 + 5, completed + 19.95 + 5, 0);
    p.adjust_ms = 0;
    opengl_pacing_ready(&p, planned, completed, 12);
    assert(fabs(p.adjust_ms - (2 - (planned - completed - 12))) < 1e-8);
    double next = p.next_ms;
    schedule(&p, completed + 2 * 19.95, completed + 2 * 19.95, 0);
    assert(fabs(p.next_ms - next - p.period_ms) <= 0.500001);

    opengl_pacing_init(&p);
    for (int i = 0; i < 100; i++) schedule(&p, 1000 + i * 19.95, 1000 + i * 19.95, 0);
    opengl_pacing_ready(&p, p.planned_ms, p.last_completed_ms, 50);
    double peak = 0;
    for (int i = 100; i < 4000; i++) {
        double old_next = p.next_ms;
        double arrival = 1000 + i * 19.95;
        target = schedule(&p, arrival, arrival, 0);
        double shift = p.next_ms - old_next - p.period_ms;
        assert(shift <= 0.500001 && shift >= -0.050001);
        if (target - arrival > peak) peak = target - arrival;
    }
    assert(peak > 40 && target - p.last_completed_ms < 3);
    puts("pacing: bursts, pressure, pause/warp restart, speed and delayed feedback passed");
    return 0;
}
