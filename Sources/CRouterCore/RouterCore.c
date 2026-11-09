#include "RouterCore.h"

#include <Accelerate/Accelerate.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// ---------------------------------------------------------------------------
// Time
// ---------------------------------------------------------------------------
static double g_ticks_to_seconds = 0.0;

__attribute__((constructor)) static void ar_init_timebase(void) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    g_ticks_to_seconds = (double)tb.numer / (double)tb.denom * 1e-9;
}

double ar_host_time_seconds(void) { return (double)mach_absolute_time() * g_ticks_to_seconds; }

static inline float ar_fmaxf(float a, float b) { return a > b ? a : b; }

// Atomic float peak helpers (stored as float in _Atomic).
static inline void ar_peak_update(_Atomic float *slot, float v) {
    float cur = atomic_load_explicit(slot, memory_order_relaxed);
    if (v > cur) atomic_store_explicit(slot, v, memory_order_relaxed);
}

// ---------------------------------------------------------------------------
// Resampler
// ---------------------------------------------------------------------------
#define AR_RS_PHASES 512
#define AR_RS_PASS 0.96     // cutoff (-6 dB) as fraction of the lower Nyquist
#define AR_RS_BETA 10.0     // Kaiser beta (~ -100 dB sidelobes)

struct ARResampler {
    int channels;
    int halfTaps;   // effective
    int taps;
    float *table;   // (phases+1) * taps
    float *coef;    // taps
    float *bufMem;
    float **buf;
    int bufCap;
    int bufFrames;
    double pos;
};

static double ar_bessel_i0(double x) {
    double sum = 1.0, term = 1.0, x2 = x * x * 0.25;
    for (int k = 1; k < 200; k++) {
        term *= x2 / ((double)k * (double)k);
        sum += term;
        if (term < sum * 1e-15) break;
    }
    return sum;
}

ARResampler *ar_resampler_create(int channels, double nominalStep, int halfTaps, int maxOutFrames) {
    if (channels < 1 || nominalStep <= 0 || halfTaps < 4 || maxOutFrames < 1) return NULL;
    ARResampler *rs = calloc(1, sizeof *rs);
    if (!rs) return NULL;
    const double scale = nominalStep > 1.0 ? nominalStep : 1.0;
    const int ht = (int)ceil(halfTaps * scale);
    rs->channels = channels;
    rs->halfTaps = ht;
    rs->taps = 2 * ht;
    const int taps = rs->taps;
    const double fc = 0.5 * AR_RS_PASS / scale;  // cycles per input sample
    const double i0b = ar_bessel_i0(AR_RS_BETA);

    rs->table = malloc(sizeof(float) * (size_t)(AR_RS_PHASES + 1) * (size_t)taps);
    double *row = malloc(sizeof(double) * (size_t)taps);
    for (int q = 0; q <= AR_RS_PHASES; q++) {
        const double f = (double)q / AR_RS_PHASES;
        double sum = 0.0;
        for (int j = 0; j < taps; j++) {
            const double x = (double)(j - ht + 1) - f;
            const double r = x / ht;
            double w = 0.0;
            if (fabs(r) < 1.0) w = ar_bessel_i0(AR_RS_BETA * sqrt(1.0 - r * r)) / i0b;
            const double s = fabs(x) < 1e-12 ? 2.0 * fc : sin(2.0 * M_PI * fc * x) / (M_PI * x);
            row[j] = s * w;
            sum += row[j];
        }
        for (int j = 0; j < taps; j++) rs->table[(size_t)q * taps + j] = (float)(row[j] / sum);
    }
    free(row);

    rs->coef = calloc((size_t)taps, sizeof(float));
    const double maxStep = nominalStep * 1.02 + 0.01;
    rs->bufCap = 2 * ht + (int)ceil(maxOutFrames * maxStep) + 16;
    rs->bufMem = calloc((size_t)rs->bufCap * (size_t)channels, sizeof(float));
    rs->buf = calloc((size_t)channels, sizeof(float *));
    for (int c = 0; c < channels; c++) rs->buf[c] = rs->bufMem + (size_t)c * rs->bufCap;
    ar_resampler_reset(rs);
    return rs;
}

void ar_resampler_destroy(ARResampler *rs) {
    if (!rs) return;
    free(rs->table);
    free(rs->coef);
    free(rs->bufMem);
    free(rs->buf);
    free(rs);
}

void ar_resampler_reset(ARResampler *rs) {
    memset(rs->bufMem, 0, sizeof(float) * (size_t)rs->bufCap * (size_t)rs->channels);
    rs->bufFrames = rs->halfTaps - 1;  // zero history
    rs->pos = rs->halfTaps - 1;        // first output centred on first real input sample
}

int ar_resampler_input_needed(const ARResampler *rs, int outFrames, double step) {
    if (outFrames <= 0) return 0;
    const double pLast = rs->pos + (double)(outFrames - 1) * step;
    const int required = (int)floor(pLast) + rs->halfTaps + 1;
    int need = required - rs->bufFrames;
    if (need < 0) need = 0;
    if (rs->bufFrames + need > rs->bufCap) need = rs->bufCap - rs->bufFrames;
    return need;
}

float *ar_resampler_input_ptr(ARResampler *rs, int ch) { return rs->buf[ch] + rs->bufFrames; }

void ar_resampler_commit_input(ARResampler *rs, int frames) {
    rs->bufFrames += frames;
    if (rs->bufFrames > rs->bufCap) rs->bufFrames = rs->bufCap;
}

int ar_resampler_half_taps(const ARResampler *rs) { return rs->halfTaps; }

double ar_resampler_held_frames(const ARResampler *rs) { return (double)rs->bufFrames - rs->pos; }

void ar_resampler_render(ARResampler *rs, float *const *out, int outFrames, double step) {
    const int taps = rs->taps;
    const int ht = rs->halfTaps;
    const int channels = rs->channels;
    float *coef = rs->coef;
    const int maxIndex = rs->bufFrames - taps;  // largest valid window start
    for (int n = 0; n < outFrames; n++) {
        const double p = rs->pos + (double)n * step;
        const int i0 = (int)p;
        const double f = p - (double)i0;
        const double qf = f * AR_RS_PHASES;
        int qi = (int)qf;
        if (qi >= AR_RS_PHASES) qi = AR_RS_PHASES - 1;
        const float a = (float)(qf - (double)qi);
        const float *t0 = rs->table + (size_t)qi * taps;
        const float *t1 = t0 + taps;
        // coef = t0 + (t1 - t0) * a
        vDSP_vintb(t0, 1, t1, 1, &a, coef, 1, (vDSP_Length)taps);
        int base = i0 - ht + 1;
        if (base < 0) base = 0;
        if (base > maxIndex) base = maxIndex < 0 ? 0 : maxIndex;  // guarded: caller fed too little
        for (int c = 0; c < channels; c++) {
            float acc;
            vDSP_dotpr(rs->buf[c] + base, 1, coef, 1, &acc, (vDSP_Length)taps);
            out[c][n] = acc;
        }
    }
    const double newPos = rs->pos + (double)outFrames * step;
    int shift = (int)floor(newPos) - (ht - 1);
    if (shift > rs->bufFrames) shift = rs->bufFrames;
    if (shift > 0) {
        const int remain = rs->bufFrames - shift;
        for (int c = 0; c < channels; c++) memmove(rs->buf[c], rs->buf[c] + shift, sizeof(float) * (size_t)remain);
        rs->bufFrames = remain;
        rs->pos = newPos - shift;
    } else {
        rs->pos = newPos;
    }
}

int64_t ar_resample_offline(int channels, double step, int halfTaps, const float *const *in, int64_t inFrames,
                            float *const *out, int64_t outFrames) {
    const int chunk = 256;
    ARResampler *rs = ar_resampler_create(channels, step, halfTaps, chunk);
    if (!rs) return 0;
    float **optr = calloc((size_t)channels, sizeof(float *));
    int64_t inPos = 0, produced = 0;
    while (produced < outFrames) {
        int n = (int)((outFrames - produced) < chunk ? (outFrames - produced) : chunk);
        int need = ar_resampler_input_needed(rs, n, step);
        for (int c = 0; c < channels; c++) {
            float *dst = ar_resampler_input_ptr(rs, c);
            for (int i = 0; i < need; i++) {
                int64_t k = inPos + i;
                dst[i] = k < inFrames ? in[c][k] : 0.0f;
            }
        }
        ar_resampler_commit_input(rs, need);
        inPos += need;
        for (int c = 0; c < channels; c++) optr[c] = out[c] + produced;
        ar_resampler_render(rs, optr, n, step);
        produced += n;
    }
    free(optr);
    ar_resampler_destroy(rs);
    return produced;
}

// ---------------------------------------------------------------------------
// Bridge
// ---------------------------------------------------------------------------
// Drift control loop (type-II PI on the timestamp-corrected fill level).
// Acquisition: wide bandwidth to lock quickly; tracking: very narrow bandwidth so that
// scheduler jitter in the fill estimate does not turn into rate (pitch) jitter.
#define AR_OMEGA_FAST 0.3       // rad/s during acquisition
#define AR_OMEGA_SLOW 0.03      // rad/s while tracking
#define AR_TAU_FAST 0.2         // fill low-pass time constant during acquisition (s)
#define AR_TAU_SLOW 1.0         // ... while tracking
#define AR_ZETA 0.8
#define AR_ACQUIRE_TIME 4.0     // seconds at fast bandwidth
#define AR_GLIDE_TAU 8.0        // fast->slow glide time constant

enum { AR_PRIMING = 0, AR_RUNNING = 1 };

struct ARBridge {
    ARBridgeConfig cfg;
    int32_t src[AR_MAX_BUS_CHANNELS];
    int channels;

    // ring (deinterleaved)
    float *ringMem;
    float *ring[AR_MAX_BUS_CHANNELS];
    int64_t cap;
    int64_t mask;
    _Atomic int64_t writePos;
    _Atomic int64_t readPos;
    _Atomic double lastWriteTime;

    // consumer state (output thread only)
    ARResampler *rs;
    int bypass;
    int ht;
    double nominalStep;
    int state;
    double filtered;
    double integ;
    double corr;
    double runTime;
    double omega;
    int everLocked;
    double target;      // in "estimate" units: ring avail + in-flight + resampler lookahead
    double primeLevel;  // ring avail needed to start
    double resyncAbove;
    double tonePhase;
    _Atomic int testTone;

    _Atomic int64_t underruns, overruns, resyncs, framesWritten, framesRead;
    _Atomic double statFill, statCorr;
    _Atomic int statState;
};

static int64_t ar_next_pow2(int64_t v) {
    int64_t p = 1;
    while (p < v) p <<= 1;
    return p;
}

ARBridge *ar_bridge_create(const ARBridgeConfig *cfg, const int32_t *sourceChannels) {
    if (!cfg || cfg->busChannels < 1 || cfg->busChannels > AR_MAX_BUS_CHANNELS) return NULL;
    if (cfg->inRate <= 0 || cfg->outRate <= 0) return NULL;
    ARBridge *b = calloc(1, sizeof *b);
    if (!b) return NULL;
    b->cfg = *cfg;
    b->channels = cfg->busChannels;
    for (int i = 0; i < b->channels; i++) b->src[i] = sourceChannels ? sourceChannels[i] : i;
    if (b->cfg.inMaxFrames < 1) b->cfg.inMaxFrames = 4096;
    if (b->cfg.outMaxFrames < 1) b->cfg.outMaxFrames = 4096;
    if (b->cfg.inBufferFrames < 1) b->cfg.inBufferFrames = 512;
    if (b->cfg.outBufferFrames < 1) b->cfg.outBufferFrames = 512;
    if (b->cfg.maxCorrectionPPM <= 0) b->cfg.maxCorrectionPPM = 2000;
    if (b->cfg.halfTaps < 8) b->cfg.halfTaps = 8;

    b->nominalStep = cfg->inRate / cfg->outRate;
    b->bypass = (cfg->lockedClocks && cfg->inRate == cfg->outRate) ? 1 : 0;
    if (!b->bypass) {
        b->rs = ar_resampler_create(b->channels, b->nominalStep, b->cfg.halfTaps, b->cfg.outMaxFrames);
        if (!b->rs) { free(b); return NULL; }
        b->ht = ar_resampler_half_taps(b->rs);
    }

    const double inBuf = b->cfg.inBufferFrames;
    const double outBufIn = b->cfg.outBufferFrames * b->nominalStep;
    const double base = outBufIn + inBuf + b->cfg.marginSeconds * cfg->inRate;
    b->target = base + b->ht;
    b->primeLevel = base + b->ht;
    b->resyncAbove = b->target + fmax(4.0 * (inBuf + outBufIn), 0.08 * cfg->inRate);

    int64_t needCap = (int64_t)(b->resyncAbove * 2 + b->cfg.inMaxFrames * 4 + b->cfg.outMaxFrames * 4 * b->nominalStep);
    if (needCap < 16384) needCap = 16384;
    b->cap = ar_next_pow2(needCap);
    b->mask = b->cap - 1;
    b->ringMem = calloc((size_t)b->cap * (size_t)b->channels, sizeof(float));
    if (!b->ringMem) { ar_resampler_destroy(b->rs); free(b); return NULL; }
    for (int c = 0; c < b->channels; c++) b->ring[c] = b->ringMem + (size_t)c * b->cap;

    atomic_init(&b->writePos, 0);
    atomic_init(&b->readPos, 0);
    atomic_init(&b->lastWriteTime, 0.0);
    atomic_init(&b->testTone, 0);
    b->state = AR_PRIMING;
    b->filtered = b->target;
    return b;
}

void ar_bridge_destroy(ARBridge *b) {
    if (!b) return;
    ar_resampler_destroy(b->rs);
    free(b->ringMem);
    free(b);
}

void ar_bridge_write(ARBridge *b, const float *const *dev, int devChannels, int frames, double hostTime) {
    if (frames <= 0) return;
    const int64_t w = atomic_load_explicit(&b->writePos, memory_order_relaxed);
    const int64_t r = atomic_load_explicit(&b->readPos, memory_order_acquire);
    const int64_t freeFrames = b->cap - (w - r);
    if (frames > freeFrames) {
        atomic_fetch_add_explicit(&b->overruns, 1, memory_order_relaxed);
        return;  // drop this block; consumer resyncs
    }
    const int64_t start = w & b->mask;
    const int64_t first = (start + frames <= b->cap) ? frames : (b->cap - start);
    const int64_t second = frames - first;
    for (int c = 0; c < b->channels; c++) {
        const int sc = b->src[c];
        float *dst = b->ring[c];
        if (sc >= 0 && sc < devChannels && dev[sc]) {
            memcpy(dst + start, dev[sc], sizeof(float) * (size_t)first);
            if (second) memcpy(dst, dev[sc] + first, sizeof(float) * (size_t)second);
        } else {
            memset(dst + start, 0, sizeof(float) * (size_t)first);
            if (second) memset(dst, 0, sizeof(float) * (size_t)second);
        }
    }
    atomic_store_explicit(&b->lastWriteTime, hostTime, memory_order_relaxed);
    atomic_store_explicit(&b->writePos, w + frames, memory_order_release);
    atomic_fetch_add_explicit(&b->framesWritten, frames, memory_order_relaxed);
}

static void ar_ring_copy_out(ARBridge *b, int64_t r, int frames, float *const *dst) {
    const int64_t start = r & b->mask;
    const int64_t first = (start + frames <= b->cap) ? frames : (b->cap - start);
    const int64_t second = frames - first;
    for (int c = 0; c < b->channels; c++) {
        memcpy(dst[c], b->ring[c] + start, sizeof(float) * (size_t)first);
        if (second) memcpy(dst[c] + first, b->ring[c], sizeof(float) * (size_t)second);
    }
}

static void ar_bridge_tone(ARBridge *b, float *const *busOut, int frames) {
    const double inc = 2.0 * M_PI * 1000.0 / b->cfg.outRate;
    double ph = b->tonePhase;
    for (int i = 0; i < frames; i++) {
        const float v = (float)(0.1 * sin(ph));
        for (int c = 0; c < b->channels; c++) busOut[c][i] = v;
        ph += inc;
        if (ph > 2.0 * M_PI) ph -= 2.0 * M_PI;
    }
    b->tonePhase = ph;
}

static void ar_bridge_silence(ARBridge *b, float *const *busOut, int frames) {
    for (int c = 0; c < b->channels; c++) memset(busOut[c], 0, sizeof(float) * (size_t)frames);
}

void ar_bridge_read(ARBridge *b, float *const *busOut, int frames, double hostTime) {
    if (frames <= 0) return;
    const int64_t w = atomic_load_explicit(&b->writePos, memory_order_acquire);
    int64_t r = atomic_load_explicit(&b->readPos, memory_order_relaxed);
    int64_t avail = w - r;
    const double dt = (double)frames / b->cfg.outRate;
    const int tone = atomic_load_explicit(&b->testTone, memory_order_relaxed);

    // Frames captured by the input device since its last callback: removes the
    // input-buffer sawtooth from the fill measurement.
    const double tLast = atomic_load_explicit(&b->lastWriteTime, memory_order_relaxed);
    double ext = 0.0;
    if (tLast > 0.0) {
        ext = (hostTime - tLast) * b->cfg.inRate;
        if (ext < 0.0) ext = 0.0;
        if (ext > b->cfg.inBufferFrames) ext = b->cfg.inBufferFrames;
    }

    if (b->state == AR_PRIMING) {
        // Start once the fill estimate reaches the target; drop any excess so the loop starts at zero error.
        if ((double)avail + ext >= b->primeLevel) {
            const int64_t excess = (int64_t)floor((double)avail + ext - b->primeLevel);
            if (excess > 0) { r += excess; avail -= excess; }
            if (b->rs) ar_resampler_reset(b->rs);
            b->state = AR_RUNNING;
            b->filtered = b->target;
            // First lock: acquisition gear. After an underrun the drift estimate (integ) is still
            // valid, so resume directly in the narrow tracking gear.
            if (!b->everLocked) { b->runTime = 0; b->everLocked = 1; }
            else if (b->runTime < AR_ACQUIRE_TIME + 4 * AR_GLIDE_TAU) b->runTime = AR_ACQUIRE_TIME + 4 * AR_GLIDE_TAU;
        } else {
            atomic_store_explicit(&b->readPos, r, memory_order_release);
            if (tone) ar_bridge_tone(b, busOut, frames); else ar_bridge_silence(b, busOut, frames);
            atomic_store_explicit(&b->statState, AR_PRIMING, memory_order_relaxed);
            return;
        }
    }

    // Fill estimate: ring content + in-flight input frames + resampler lookahead.
    const double held = b->rs ? ar_resampler_held_frames(b->rs) : 0.0;
    const double est = (double)avail + ext + held;

    // Stall / runaway protection: drop excess to get back to target.
    if (est > b->resyncAbove) {
        int64_t drop = (int64_t)(est - b->target);
        if (drop > avail) drop = avail;
        if (drop > 0) { r += drop; avail -= drop; }
        b->filtered = b->target;
        atomic_fetch_add_explicit(&b->resyncs, 1, memory_order_relaxed);
    } else {
        // Gear shift: 0 = acquisition, 1 = tracking (smooth exponential glide).
        b->runTime += dt;
        double g = 0.0;
        if (b->runTime > AR_ACQUIRE_TIME) g = 1.0 - exp(-(b->runTime - AR_ACQUIRE_TIME) / AR_GLIDE_TAU);
        b->omega = exp(log(AR_OMEGA_FAST) + g * (log(AR_OMEGA_SLOW) - log(AR_OMEGA_FAST)));
        const double tau = AR_TAU_FAST + g * (AR_TAU_SLOW - AR_TAU_FAST);
        const double a = 1.0 - exp(-dt / tau);
        b->filtered += a * (est - b->filtered);
    }

    double step = b->nominalStep;
    if (!b->cfg.lockedClocks) {
        const double omega = b->omega > 0 ? b->omega : AR_OMEGA_FAST;
        const double plant = b->cfg.inRate;
        const double kp = 2.0 * AR_ZETA * omega / plant;
        const double ki = omega * omega / plant;
        const double e = b->filtered - b->target;
        const double lim = b->cfg.maxCorrectionPPM * 1e-6;
        b->integ += ki * e * dt;
        if (b->integ > lim) b->integ = lim;
        if (b->integ < -lim) b->integ = -lim;
        double c = kp * e + b->integ;
        if (c > lim) c = lim;
        if (c < -lim) c = -lim;
        b->corr = c;
        step = b->nominalStep * (1.0 + c);
    }

    int need = b->bypass ? frames : ar_resampler_input_needed(b->rs, frames, step);
    if ((int64_t)need > avail) {
        // Underrun: output silence and re-prime (keep drift estimate in integ).
        atomic_fetch_add_explicit(&b->underruns, 1, memory_order_relaxed);
        b->state = AR_PRIMING;
        atomic_store_explicit(&b->readPos, r, memory_order_release);
        if (tone) ar_bridge_tone(b, busOut, frames); else ar_bridge_silence(b, busOut, frames);
        atomic_store_explicit(&b->statState, AR_PRIMING, memory_order_relaxed);
        return;
    }

    if (b->bypass) {
        ar_ring_copy_out(b, r, need, busOut);
    } else {
        float *dst[AR_MAX_BUS_CHANNELS];
        for (int c = 0; c < b->channels; c++) dst[c] = ar_resampler_input_ptr(b->rs, c);
        ar_ring_copy_out(b, r, need, dst);
        ar_resampler_commit_input(b->rs, need);
        ar_resampler_render(b->rs, busOut, frames, step);
    }
    r += need;
    atomic_store_explicit(&b->readPos, r, memory_order_release);
    atomic_fetch_add_explicit(&b->framesRead, frames, memory_order_relaxed);
    if (tone) ar_bridge_tone(b, busOut, frames);

    atomic_store_explicit(&b->statFill, b->filtered, memory_order_relaxed);
    atomic_store_explicit(&b->statCorr, b->corr * 1e6, memory_order_relaxed);
    atomic_store_explicit(&b->statState, AR_RUNNING, memory_order_relaxed);
}

void ar_bridge_get_stats(const ARBridge *b, ARBridgeStats *s) {
    ARBridge *m = (ARBridge *)b;
    s->underruns = atomic_load_explicit(&m->underruns, memory_order_relaxed);
    s->overruns = atomic_load_explicit(&m->overruns, memory_order_relaxed);
    s->resyncs = atomic_load_explicit(&m->resyncs, memory_order_relaxed);
    s->framesWritten = atomic_load_explicit(&m->framesWritten, memory_order_relaxed);
    s->framesRead = atomic_load_explicit(&m->framesRead, memory_order_relaxed);
    s->fillFrames = atomic_load_explicit(&m->statFill, memory_order_relaxed);
    s->targetFillFrames = b->target;
    s->correctionPPM = atomic_load_explicit(&m->statCorr, memory_order_relaxed);
    s->nominalStep = b->nominalStep;
    s->halfTaps = b->ht;
    s->bypass = b->bypass;
    s->state = atomic_load_explicit(&m->statState, memory_order_relaxed);
}

void ar_bridge_reset_counters(ARBridge *b) {
    atomic_store(&b->underruns, 0);
    atomic_store(&b->overruns, 0);
    atomic_store(&b->resyncs, 0);
}

void ar_bridge_set_test_tone(ARBridge *b, int enabled) { atomic_store(&b->testTone, enabled ? 1 : 0); }

// Callback time de-jittering. The HAL timestamp (mHostTime) follows the device clock smoothly but
// has a device-specific constant offset from the moment the callback actually runs. We use
// halTime + slowly averaged (now - halTime): smooth like the HAL clock, aligned like wall time.
typedef struct {
    double avgOffset;
    int init;
} ARTimeSmoother;

static double ar_smooth_time(ARTimeSmoother *sm, double now, const AudioTimeStamp *ts) {
    if (!ts || !(ts->mFlags & kAudioTimeStampHostTimeValid) || ts->mHostTime == 0) return now;
    const double hal = (double)ts->mHostTime * g_ticks_to_seconds;
    const double off = now - hal;
    if (!sm->init || fabs(off - sm->avgOffset) > 0.005) {  // first call or timeline jump: re-anchor
        sm->avgOffset = off;
        sm->init = 1;
    } else {
        sm->avgOffset += 0.002 * (off - sm->avgOffset);
    }
    return hal + sm->avgOffset;
}

// ---------------------------------------------------------------------------
// Input node
// ---------------------------------------------------------------------------
struct ARInputNode {
    AudioUnit unit;
    int channels;
    int maxFrames;
    float *mem;
    float *chans[AR_MAX_DEVICE_CHANNELS];
    AudioBufferList *abl;
    ARBridge *bridges[AR_MAX_BRIDGES_PER_NODE];
    int nb;
    _Atomic float peaks[AR_MAX_DEVICE_CHANNELS];
    _Atomic int64_t callbacks;
    _Atomic int64_t errors;
    _Atomic int32_t lastError;
    ARTimeSmoother clock;
};

ARInputNode *ar_input_create(int deviceChannels, int maxFrames) {
    if (deviceChannels < 1 || deviceChannels > AR_MAX_DEVICE_CHANNELS || maxFrames < 1) return NULL;
    ARInputNode *n = calloc(1, sizeof *n);
    n->channels = deviceChannels;
    n->maxFrames = maxFrames;
    n->mem = calloc((size_t)deviceChannels * (size_t)maxFrames, sizeof(float));
    for (int c = 0; c < deviceChannels; c++) n->chans[c] = n->mem + (size_t)c * maxFrames;
    n->abl = calloc(1, offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * (size_t)deviceChannels);
    n->abl->mNumberBuffers = (UInt32)deviceChannels;
    for (int c = 0; c < deviceChannels; c++) {
        n->abl->mBuffers[c].mNumberChannels = 1;
        n->abl->mBuffers[c].mData = n->chans[c];
        n->abl->mBuffers[c].mDataByteSize = (UInt32)(sizeof(float) * (size_t)maxFrames);
    }
    return n;
}

void ar_input_destroy(ARInputNode *n) {
    if (!n) return;
    free(n->mem);
    free(n->abl);
    free(n);
}

int ar_input_add_bridge(ARInputNode *n, ARBridge *b) {
    if (n->nb >= AR_MAX_BRIDGES_PER_NODE) return -1;
    n->bridges[n->nb] = b;
    return n->nb++;
}

void ar_input_set_unit(ARInputNode *n, AudioUnit unit) { n->unit = unit; }

void ar_input_process(ARInputNode *n, const float *const *chans, int frames, double hostTime) {
    for (int c = 0; c < n->channels; c++) {
        float m = 0.0f;
        vDSP_maxmgv(chans[c], 1, &m, (vDSP_Length)frames);
        ar_peak_update(&n->peaks[c], m);
    }
    for (int i = 0; i < n->nb; i++) ar_bridge_write(n->bridges[i], chans, n->channels, frames, hostTime);
}

static OSStatus ar_input_cb(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus,
                            UInt32 frames, AudioBufferList *ioData) {
    (void)ioData;
    ARInputNode *n = (ARInputNode *)refCon;
    const double now = ar_smooth_time(&n->clock, ar_host_time_seconds(), ts);
    atomic_fetch_add_explicit(&n->callbacks, 1, memory_order_relaxed);
    if ((int)frames > n->maxFrames || !n->unit) {
        atomic_fetch_add_explicit(&n->errors, 1, memory_order_relaxed);
        return noErr;
    }
    for (int c = 0; c < n->channels; c++) {
        n->abl->mBuffers[c].mData = n->chans[c];
        n->abl->mBuffers[c].mDataByteSize = (UInt32)(sizeof(float) * frames);
    }
    OSStatus err = AudioUnitRender(n->unit, flags, ts, bus, frames, n->abl);
    if (err != noErr) {
        atomic_fetch_add_explicit(&n->errors, 1, memory_order_relaxed);
        atomic_store_explicit(&n->lastError, err, memory_order_relaxed);
        return noErr;
    }
    ar_input_process(n, (const float *const *)n->chans, (int)frames, now);
    return noErr;
}

AURenderCallback ar_input_callback_ptr(void) { return ar_input_cb; }

float ar_input_take_peak(ARInputNode *n, int ch) {
    if (ch < 0 || ch >= n->channels) return 0.0f;
    return atomic_exchange_explicit(&n->peaks[ch], 0.0f, memory_order_relaxed);
}
int64_t ar_input_callback_count(const ARInputNode *n) { return atomic_load(&((ARInputNode *)n)->callbacks); }
int64_t ar_input_error_count(const ARInputNode *n) { return atomic_load(&((ARInputNode *)n)->errors); }
int32_t ar_input_last_error(const ARInputNode *n) { return atomic_load(&((ARInputNode *)n)->lastError); }

// ---------------------------------------------------------------------------
// Output node
// ---------------------------------------------------------------------------
typedef struct {
    int slot;
    int bus;
    int out;
    _Atomic float target;
    float current;
} ARXPoint;

struct AROutputNode {
    int channels;
    int maxFrames;
    double rate;
    ARBridge *bridges[AR_MAX_BRIDGES_PER_NODE];
    int busCount[AR_MAX_BRIDGES_PER_NODE];
    float *scratchMem[AR_MAX_BRIDGES_PER_NODE];
    float *scratch[AR_MAX_BRIDGES_PER_NODE][AR_MAX_BUS_CHANNELS];
    int nb;
    ARXPoint xp[AR_MAX_XPOINTS];
    int nxp;
    _Atomic float peaks[AR_MAX_DEVICE_CHANNELS];
    _Atomic int64_t callbacks;
    _Atomic int64_t errors;
    _Atomic int64_t nans;
    _Atomic int protectEnabled;
    _Atomic int tripped;
    double clipRun;  // seconds of continuous clipping (output thread)
    ARTimeSmoother clock;
};

AROutputNode *ar_output_create(int deviceChannels, int maxFrames, double sampleRate) {
    if (deviceChannels < 1 || deviceChannels > AR_MAX_DEVICE_CHANNELS || maxFrames < 1) return NULL;
    AROutputNode *n = calloc(1, sizeof *n);
    n->channels = deviceChannels;
    n->maxFrames = maxFrames;
    n->rate = sampleRate > 0 ? sampleRate : 48000;
    atomic_init(&n->protectEnabled, 1);
    return n;
}

void ar_output_destroy(AROutputNode *n) {
    if (!n) return;
    for (int i = 0; i < n->nb; i++) free(n->scratchMem[i]);
    free(n);
}

int ar_output_add_bridge(AROutputNode *n, ARBridge *b, int busChannels) {
    if (n->nb >= AR_MAX_BRIDGES_PER_NODE || busChannels < 1 || busChannels > AR_MAX_BUS_CHANNELS) return -1;
    const int s = n->nb;
    n->bridges[s] = b;
    n->busCount[s] = busChannels;
    n->scratchMem[s] = calloc((size_t)busChannels * (size_t)n->maxFrames, sizeof(float));
    for (int c = 0; c < busChannels; c++) n->scratch[s][c] = n->scratchMem[s] + (size_t)c * n->maxFrames;
    n->nb++;
    return s;
}

int ar_output_add_xpoint(AROutputNode *n, int slot, int busChannel, int outChannel, float gain) {
    if (n->nxp >= AR_MAX_XPOINTS || slot < 0 || slot >= n->nb) return -1;
    if (busChannel < 0 || busChannel >= n->busCount[slot]) return -1;
    if (outChannel < 0 || outChannel >= n->channels) return -1;
    ARXPoint *x = &n->xp[n->nxp];
    x->slot = slot;
    x->bus = busChannel;
    x->out = outChannel;
    atomic_init(&x->target, gain);
    x->current = gain;
    return n->nxp++;
}

void ar_output_set_xpoint_gain(AROutputNode *n, int xpoint, float gain) {
    if (xpoint < 0 || xpoint >= n->nxp) return;
    if (!(gain == gain)) gain = 0.0f;
    atomic_store_explicit(&n->xp[xpoint].target, gain, memory_order_relaxed);
}

void ar_output_set_protection(AROutputNode *n, int enabled) { atomic_store(&n->protectEnabled, enabled ? 1 : 0); }
int ar_output_protection_tripped(const AROutputNode *n) { return atomic_load(&((AROutputNode *)n)->tripped); }
void ar_output_reset_protection(AROutputNode *n) { atomic_store(&n->tripped, 0); }

void ar_output_process(AROutputNode *n, float *const *out, int outChannels, int frames, double hostTime) {
    atomic_fetch_add_explicit(&n->callbacks, 1, memory_order_relaxed);
    for (int c = 0; c < outChannels; c++) memset(out[c], 0, sizeof(float) * (size_t)frames);
    if (frames > n->maxFrames) {
        atomic_fetch_add_explicit(&n->errors, 1, memory_order_relaxed);
        return;
    }
    for (int s = 0; s < n->nb; s++) ar_bridge_read(n->bridges[s], n->scratch[s], frames, hostTime);

    if (atomic_load_explicit(&n->tripped, memory_order_relaxed)) return;  // protection: stay silent

    for (int i = 0; i < n->nxp; i++) {
        ARXPoint *x = &n->xp[i];
        if (x->out >= outChannels) continue;
        const float g = atomic_load_explicit(&x->target, memory_order_relaxed);
        const float *src = n->scratch[x->slot][x->bus];
        float *dst = out[x->out];
        if (g == x->current) {
            if (g != 0.0f) vDSP_vsma(src, 1, &g, dst, 1, dst, 1, (vDSP_Length)frames);
        } else {
            // Linear ramp over this buffer to avoid zipper noise.
            float c = x->current;
            const float inc = (g - c) / (float)frames;
            for (int k = 0; k < frames; k++) {
                c += inc;
                dst[k] += src[k] * c;
            }
            x->current = g;
        }
    }

    int clipped = 0;
    const int nch = outChannels < n->channels ? outChannels : n->channels;
    for (int c = 0; c < nch; c++) {
        float *d = out[c];
        float m = 0.0f;
        int bad = 0;
        for (int k = 0; k < frames; k++) {
            const float v = d[k];
            if (!isfinite(v)) { d[k] = 0.0f; bad = 1; continue; }
            m = ar_fmaxf(m, fabsf(v));
        }
        if (bad) atomic_fetch_add_explicit(&n->nans, 1, memory_order_relaxed);
        if (m >= 0.9999f) clipped = 1;
        ar_peak_update(&n->peaks[c], m);
    }
    // Feedback / runaway protection: >1.5 s of uninterrupted full-scale output mutes the device.
    if (clipped) n->clipRun += (double)frames / n->rate; else n->clipRun = 0.0;
    if (n->clipRun > 1.5 && atomic_load_explicit(&n->protectEnabled, memory_order_relaxed)) {
        atomic_store_explicit(&n->tripped, 1, memory_order_relaxed);
        n->clipRun = 0.0;
        for (int c = 0; c < outChannels; c++) memset(out[c], 0, sizeof(float) * (size_t)frames);
    }
}

static OSStatus ar_output_cb(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus,
                             UInt32 frames, AudioBufferList *ioData) {
    (void)flags; (void)bus;
    AROutputNode *n = (AROutputNode *)refCon;
    const double now = ar_smooth_time(&n->clock, ar_host_time_seconds(), ts);
    float *out[AR_MAX_DEVICE_CHANNELS];
    int nch = (int)ioData->mNumberBuffers;
    if (nch > AR_MAX_DEVICE_CHANNELS) nch = AR_MAX_DEVICE_CHANNELS;
    for (int c = 0; c < nch; c++) out[c] = (float *)ioData->mBuffers[c].mData;
    ar_output_process(n, out, nch, (int)frames, now);
    return noErr;
}

AURenderCallback ar_output_callback_ptr(void) { return ar_output_cb; }

float ar_output_take_peak(AROutputNode *n, int ch) {
    if (ch < 0 || ch >= n->channels) return 0.0f;
    return atomic_exchange_explicit(&n->peaks[ch], 0.0f, memory_order_relaxed);
}
int64_t ar_output_callback_count(const AROutputNode *n) { return atomic_load(&((AROutputNode *)n)->callbacks); }
int64_t ar_output_error_count(const AROutputNode *n) { return atomic_load(&((AROutputNode *)n)->errors); }
int64_t ar_output_nan_count(const AROutputNode *n) { return atomic_load(&((AROutputNode *)n)->nans); }

// ---------------------------------------------------------------------------
// Tone generator
// ---------------------------------------------------------------------------
struct ARToneGen {
    int channels;
    double rate;
    double inc[64];
    double phase[64];
    float amp;
    _Atomic int64_t frames;
};

ARToneGen *ar_tonegen_create(int channels, double sampleRate, const double *freqs, float amplitude) {
    if (channels < 1 || channels > 64) return NULL;
    ARToneGen *t = calloc(1, sizeof *t);
    t->channels = channels;
    t->rate = sampleRate;
    t->amp = amplitude;
    for (int c = 0; c < channels; c++) t->inc[c] = 2.0 * M_PI * freqs[c] / sampleRate;
    return t;
}
void ar_tonegen_destroy(ARToneGen *t) { free(t); }

static OSStatus ar_tonegen_cb(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus,
                              UInt32 frames, AudioBufferList *ioData) {
    (void)flags; (void)ts; (void)bus;
    ARToneGen *t = (ARToneGen *)refCon;
    for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
        float *d = (float *)ioData->mBuffers[b].mData;
        if ((int)b >= t->channels || t->inc[b] == 0.0) { memset(d, 0, sizeof(float) * frames); continue; }
        double ph = t->phase[b];
        for (UInt32 k = 0; k < frames; k++) {
            d[k] = (float)(t->amp * sin(ph));
            ph += t->inc[b];
            if (ph > 2.0 * M_PI) ph -= 2.0 * M_PI;
        }
        t->phase[b] = ph;
    }
    atomic_fetch_add_explicit(&t->frames, frames, memory_order_relaxed);
    return noErr;
}
AURenderCallback ar_tonegen_callback_ptr(void) { return ar_tonegen_cb; }
int64_t ar_tonegen_frames(const ARToneGen *t) { return atomic_load(&((ARToneGen *)t)->frames); }

// ---------------------------------------------------------------------------
// Capture
// ---------------------------------------------------------------------------
struct ARCapture {
    AudioUnit unit;
    int devChannels;
    int capChannels;
    int maxFrames;
    int64_t capacity;
    float *tmpMem;
    AudioBufferList *abl;
    float *data[64];
    _Atomic int64_t frames;
    _Atomic int armed;
};

ARCapture *ar_capture_create(int deviceChannels, int captureChannels, int maxFrames, int64_t capacityFrames) {
    if (deviceChannels < 1 || captureChannels < 1 || captureChannels > 64 || captureChannels > deviceChannels) return NULL;
    ARCapture *c = calloc(1, sizeof *c);
    c->devChannels = deviceChannels;
    c->capChannels = captureChannels;
    c->maxFrames = maxFrames;
    c->capacity = capacityFrames;
    c->tmpMem = calloc((size_t)deviceChannels * (size_t)maxFrames, sizeof(float));
    c->abl = calloc(1, offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * (size_t)deviceChannels);
    c->abl->mNumberBuffers = (UInt32)deviceChannels;
    for (int k = 0; k < deviceChannels; k++) {
        c->abl->mBuffers[k].mNumberChannels = 1;
        c->abl->mBuffers[k].mData = c->tmpMem + (size_t)k * maxFrames;
    }
    for (int k = 0; k < captureChannels; k++) c->data[k] = calloc((size_t)capacityFrames, sizeof(float));
    return c;
}

void ar_capture_destroy(ARCapture *c) {
    if (!c) return;
    for (int k = 0; k < c->capChannels; k++) free(c->data[k]);
    free(c->tmpMem);
    free(c->abl);
    free(c);
}
void ar_capture_set_unit(ARCapture *c, AudioUnit unit) { c->unit = unit; }
void ar_capture_arm(ARCapture *c, int armed) { atomic_store(&c->armed, armed); }

static OSStatus ar_capture_cb(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus,
                              UInt32 frames, AudioBufferList *ioData) {
    (void)ioData;
    ARCapture *c = (ARCapture *)refCon;
    if ((int)frames > c->maxFrames || !c->unit) return noErr;
    for (int k = 0; k < c->devChannels; k++) {
        c->abl->mBuffers[k].mData = c->tmpMem + (size_t)k * c->maxFrames;
        c->abl->mBuffers[k].mDataByteSize = (UInt32)(sizeof(float) * frames);
    }
    if (AudioUnitRender(c->unit, flags, ts, bus, frames, c->abl) != noErr) return noErr;
    if (!atomic_load_explicit(&c->armed, memory_order_relaxed)) return noErr;
    const int64_t f = atomic_load_explicit(&c->frames, memory_order_relaxed);
    int64_t n = frames;
    if (f + n > c->capacity) n = c->capacity - f;
    if (n <= 0) return noErr;
    for (int k = 0; k < c->capChannels; k++) memcpy(c->data[k] + f, c->abl->mBuffers[k].mData, sizeof(float) * (size_t)n);
    atomic_store_explicit(&c->frames, f + n, memory_order_release);
    return noErr;
}
AURenderCallback ar_capture_callback_ptr(void) { return ar_capture_cb; }
int64_t ar_capture_frames(const ARCapture *c) { return atomic_load(&((ARCapture *)c)->frames); }
const float *ar_capture_channel(const ARCapture *c, int ch) { return (ch >= 0 && ch < c->capChannels) ? c->data[ch] : NULL; }
