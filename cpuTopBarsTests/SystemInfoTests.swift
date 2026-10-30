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

import Testing
import Foundation

// SystemInfo.c: the CPU window, memory, swap and uptime.
extension FreeTests {
  @Suite struct SystemInfoTests {
    @Test func noSamplesGiveNoReading() {
      // SystemInfoCpuReset forgets the samples (SystemInfo.c:131); with fewer than 2 the busy share is -1, the span 0
      // and both kinds' shares -1 (SystemInfo.c:162-177)
      SystemInfoCpuReset()
      var span = 1.0, efficiency = 0.0, performance = 0.0
      #expect(SystemInfoCpuBusy(&span, &efficiency, &performance) == -1)
      #expect(span == 0)
      #expect(efficiency == -1 && performance == -1)
      SystemInfoCpuTick()   // one sample is still fewer than 2
      #expect(SystemInfoCpuBusy(&span, nil, nil) == -1)
      #expect(span == 0)
    }

    @Test func memorySwapAndUptime() {
      // SystemInfoMemory: total is hw.memsize (SystemInfo.c:224, 242), used the counted pages, which cannot exceed it
      var used: UInt64 = 0, total: UInt64 = 0
      #expect(SystemInfoMemory(&used, &total))
      #expect(total == ProcessInfo.processInfo.physicalMemory)
      #expect(used > 0 && used <= total)
      // SystemInfoSwap reads vm.swapusage (SystemInfo.c:250)
      var swap: UInt64 = 0
      #expect(SystemInfoSwap(&swap))
      // SystemInfoUptimeSeconds counts from the boot time, sleep included (SystemInfo.c:269), so it is not below the
      // system uptime, which leaves sleep out; one second of slack for the two clocks' reads
      #expect(SystemInfoUptimeSeconds() >= Int(ProcessInfo.processInfo.systemUptime) - 1)
    }

    @Test func busyOverOneSecond() {
      // two ticks 1.1 s apart: the window is the 2 samples, whose span is their time difference, at least 1.1 s
      // (SystemInfo.c:185-200), and the busy share is used / total, between 0 and 1 (SystemInfo.c:126-128)
      SystemInfoCpuReset()
      SystemInfoCpuTick()
      let until = Date().addingTimeInterval(1.1)
      var spin = 0.0
      while Date() < until { spin += 1 }
      SystemInfoCpuTick()
      var span = 0.0
      let busy = SystemInfoCpuBusy(&span, nil, nil)
      #expect(busy >= 0 && busy <= 1, "busy \(busy) after \(spin) loops")
      #expect(span >= 1.0)
    }
  }
}
