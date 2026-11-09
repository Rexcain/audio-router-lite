// RouterCore — real-time audio core for Audio Router Lite.
//
// Everything called from an audio IO thread in this module is real-time safe:
// no allocation, no locks, no syscalls besides mach_absolute_time, no logging.
// All memory is allocated in the *_create functions on a non-real-time thread.

#ifndef ROUTER_CORE_H
#define ROUTER_CORE_H

#include <stdint.h>
#include <AudioToolbox/AudioToolbox.h>

#ifdef __cplusplus
extern "C" {
#endif

#define AR_MAX_DEVICE_CHANNELS 256
#define AR_MAX_BUS_CHANNELS 64
#define AR_MAX_BRIDGES_PER_NODE 32
#define AR_MAX_XPOINTS 1024

/// Host time (mach_absolute_time) in seconds.
double ar_host_time_seconds(void);

// ---------------------------------------------------------------------------
// Variable-ratio windowed-sinc resampler (polyphase Kaiser, linear phase interp)
// ---------------------------------------------------------------------------
typedef struct ARResampler ARResampler;

/// nominalStep = inputRate / outputRate. halfTaps = filter half length at ratio <= 1
/// (widened automatically when downsampling). maxOutFrames = largest render call.
ARResampler *ar_resampler_create(int channels, double nominalStep, int halfTaps, int maxOutFrames);
void ar_resampler_destroy(ARResampler *rs);
void ar_resampler_reset(ARResampler *rs);
/// Number of input frames that must be appended before rendering outFrames at `step`.
int ar_resampler_input_needed(const ARResampler *rs, int outFrames, double step);
/// Write location for the next input frames of channel ch.
float *ar_resampler_input_ptr(ARResampler *rs, int ch);
void ar_resampler_commit_input(ARResampler *rs, int frames);
void ar_resampler_render(ARResampler *rs, float *const *out, int outFrames, double step);
int ar_resampler_half_taps(const ARResampler *rs);
/// Input frames held as lookahead (fractional).
double ar_resampler_held_frames(const ARResampler *rs);

/// Offline helper (tests): resample deinterleaved `in` at a fixed step producing exactly
/// outFrames samples per channel. out[n] corresponds to input time n*step.
int64_t ar_resample_offline(int channels, double step, int halfTaps,
                            const float *const *in, int64_t inFrames,
                            float *const *out, int64_t outFrames);

// ---------------------------------------------------------------------------
// Bridge: ring buffer + resampler + drift controller between two clock domains
// ---------------------------------------------------------------------------
typedef struct {
    int busChannels;        // number of channels carried by the bridge
    double inRate;          // input device nominal sample rate
    double outRate;         // output device nominal sample rate
    int inMaxFrames;        // largest input callback (frames)
    int outMaxFrames;       // largest output callback (frames)
    int inBufferFrames;     // expected input IO buffer size
    int outBufferFrames;    // expected output IO buffer size
    int halfTaps;           // resampler quality (half filter length)
    int lockedClocks;       // nonzero: both ends share one clock -> no drift correction
    double marginSeconds;   // jitter safety margin added to the buffer target
    double maxCorrectionPPM;
} ARBridgeConfig;

typedef struct {
    int64_t underruns;
    int64_t overruns;
    int64_t resyncs;
    int64_t framesWritten;
    int64_t framesRead;
    double fillFrames;        // filtered fill estimate in input frames (incl. resampler lookahead)
    double targetFillFrames;
    double correctionPPM;     // current drift correction
    double nominalStep;       // inRate / outRate
    int halfTaps;             // effective resampler half length (0 when bypassed)
    int bypass;               // 1 = bit-exact pass-through (no resampling)
    int state;                // 0 = priming, 1 = running
} ARBridgeStats;

typedef struct ARBridge ARBridge;

/// sourceChannels[busChannels]: input device channel index feeding each bus channel.
ARBridge *ar_bridge_create(const ARBridgeConfig *cfg, const int32_t *sourceChannels);
void ar_bridge_destroy(ARBridge *b);
/// Producer side (input IO thread).
void ar_bridge_write(ARBridge *b, const float *const *deviceChannels, int deviceChannelCount,
                     int frames, double hostTime);
/// Consumer side (output IO thread). Writes `frames` frames into busOut[busChannels].
void ar_bridge_read(ARBridge *b, float *const *busOut, int frames, double hostTime);
void ar_bridge_get_stats(const ARBridge *b, ARBridgeStats *s);
void ar_bridge_reset_counters(ARBridge *b);
/// Replace the bridge output with a 1 kHz sine at -20 dBFS (verification aid).
void ar_bridge_set_test_tone(ARBridge *b, int enabled);

// ---------------------------------------------------------------------------
// Input node: one per input device (AUHAL input callback)
// ---------------------------------------------------------------------------
typedef struct ARInputNode ARInputNode;
ARInputNode *ar_input_create(int deviceChannels, int maxFrames);
void ar_input_destroy(ARInputNode *n);
int ar_input_add_bridge(ARInputNode *n, ARBridge *b);
void ar_input_set_unit(ARInputNode *n, AudioUnit unit);
AURenderCallback ar_input_callback_ptr(void);
/// Processing core used by the callback (also for tests).
void ar_input_process(ARInputNode *n, const float *const *chans, int frames, double hostTime);
/// Peak since last call (read-and-reset).
float ar_input_take_peak(ARInputNode *n, int ch);
int64_t ar_input_callback_count(const ARInputNode *n);
int64_t ar_input_error_count(const ARInputNode *n);
int32_t ar_input_last_error(const ARInputNode *n);

// ---------------------------------------------------------------------------
// Output node: one per output device (AUHAL render callback); mixes bridges.
// ---------------------------------------------------------------------------
typedef struct AROutputNode AROutputNode;
AROutputNode *ar_output_create(int deviceChannels, int maxFrames, double sampleRate);
void ar_output_destroy(AROutputNode *n);
/// Returns bridge slot or -1.
int ar_output_add_bridge(AROutputNode *n, ARBridge *b, int busChannels);
/// Returns crosspoint id or -1.
int ar_output_add_xpoint(AROutputNode *n, int slot, int busChannel, int outChannel, float gain);
void ar_output_set_xpoint_gain(AROutputNode *n, int xpoint, float gain);
void ar_output_set_protection(AROutputNode *n, int enabled);
int ar_output_protection_tripped(const AROutputNode *n);
void ar_output_reset_protection(AROutputNode *n);
AURenderCallback ar_output_callback_ptr(void);
void ar_output_process(AROutputNode *n, float *const *out, int outChannels, int frames, double hostTime);
float ar_output_take_peak(AROutputNode *n, int ch);
int64_t ar_output_callback_count(const AROutputNode *n);
int64_t ar_output_error_count(const AROutputNode *n);
int64_t ar_output_nan_count(const AROutputNode *n);

// ---------------------------------------------------------------------------
// Diagnostics helpers: tone generator (output) and capture (input).
// ---------------------------------------------------------------------------
typedef struct ARToneGen ARToneGen;
/// freqs[channels]: per-channel sine frequency (0 = silence).
ARToneGen *ar_tonegen_create(int channels, double sampleRate, const double *freqs, float amplitude);
void ar_tonegen_destroy(ARToneGen *t);
AURenderCallback ar_tonegen_callback_ptr(void);
int64_t ar_tonegen_frames(const ARToneGen *t);

typedef struct ARCapture ARCapture;
/// Captures the first `captureChannels` device channels (deinterleaved) once armed.
ARCapture *ar_capture_create(int deviceChannels, int captureChannels, int maxFrames, int64_t capacityFrames);
void ar_capture_destroy(ARCapture *c);
void ar_capture_set_unit(ARCapture *c, AudioUnit unit);
void ar_capture_arm(ARCapture *c, int armed);
AURenderCallback ar_capture_callback_ptr(void);
int64_t ar_capture_frames(const ARCapture *c);
const float *ar_capture_channel(const ARCapture *c, int ch);

#ifdef __cplusplus
}
#endif

#endif
