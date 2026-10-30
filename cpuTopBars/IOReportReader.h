// The MIT License (MIT)

// Copyright 2026 Halfmarble LLC

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

// The ANE's and the GPU's readings from IOReport, for the unsandboxed variant. IOReport is reached with dlopen and
// dlsym, never linked. In the sandboxed variant IOReportSample does nothing and both readings are -1, so a caller needs
// no #if. The functions below are called only from the main thread; the sample itself (about 4.7 ms) runs on a serial
// queue of its own, which alone makes the IOReport calls and holds the subscription, and its two readings are published
// back to the main thread.

#ifndef IOReportReader_h
#define IOReportReader_h

#include <stdbool.h>
#include <stdint.h>
#include <sys/cdefs.h>

__BEGIN_DECLS

// ANE busy %, 0-100: the share of the window's residencies of "PMP | AF BW | ANE0 RD+WR" that are in any state but the
// lowest (index 0, "1GB/s"); 0 when they sum to 0 (engine off). -1 when residencies is NULL or count < 1.
double IOReportAneBusyFromResidencies(const int64_t* residencies, int count);

// W from nanojoules over seconds; -1 when seconds <= 0 or nanojoules < 0.
double IOReportGpuWattsFromEnergy(double nanojoules, double seconds);

// Queues a sample, unless one is still queued, whose readings, over the time since the previous sample, are published
// to the main thread when it is done. The first sample only starts the window, and so does one more than 10 s after the
// previous request, whose old readings are dropped at once: a pause is never averaged in. A read after this call
// returns -1 until a sample finishes.
void IOReportSample(void);

// The readings the last finished sample published, or -1 when not readable or none has finished yet.
double IOReportAneBusy(void);
double IOReportGpuWatts(void);

// true once IOReport could not be set up, or a sample could not be taken, until a sample reads both channels again;
// false in the sandboxed variant
bool IOReportUnreadable(void);

__END_DECLS

#endif /* IOReportReader_h */
