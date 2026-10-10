/// Low-level probes for the measurement round, via dart:ffi into bionic libc
/// and plain reads of /proc and /sys. Android-only by design: every call is
/// guarded so that a failure becomes a recorded `null`/error code rather than a
/// crash — a measurement that silently lost its method would be worse than
/// one that says what it could not do.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _AffinityNative = Int32 Function(
    Int32 pid, IntPtr setSize, Pointer<Uint8> mask);
typedef _AffinityDart = int Function(int pid, int setSize, Pointer<Uint8> mask);
typedef _IntNative = Int32 Function();
typedef _IntDart = int Function();
typedef _ErrnoFn = Pointer<Int32> Function();

/// CPU pinning and thread identity (bionic libc).
class CpuAffinity {
  CpuAffinity._();

  /// bionic's `cpu_set_t` on 64-bit Android: CPU_SETSIZE = 1024 bits.
  static const int _maskBytes = 128;

  static final DynamicLibrary _libc = DynamicLibrary.open('libc.so');
  static final _AffinityDart _setAffinity = _libc
      .lookupFunction<_AffinityNative, _AffinityDart>('sched_setaffinity');
  static final _AffinityDart _getAffinity = _libc
      .lookupFunction<_AffinityNative, _AffinityDart>('sched_getaffinity');
  static final _IntDart _getCpu =
      _libc.lookupFunction<_IntNative, _IntDart>('sched_getcpu');
  static final _IntDart _getTid =
      _libc.lookupFunction<_IntNative, _IntDart>('gettid');
  static final _ErrnoFn _errno =
      _libc.lookupFunction<_ErrnoFn, _ErrnoFn>('__errno');

  /// The CPU the calling thread is running on right now.
  static int currentCpu() => _getCpu();

  /// Kernel thread id of the calling thread.
  static int currentTid() => _getTid();

  /// CPUs [tid] may run on (0 = calling thread); empty if the call failed.
  /// The kernel reports only cores that are active right now: a core paused by
  /// core control (see [pinWaking]) is missing, so the result must never be
  /// used to *restore* an affinity — restore to [CpuTopology.possibleCpus].
  static List<int> get(int tid) {
    final mask = calloc<Uint8>(_maskBytes);
    try {
      if (_getAffinity(tid, _maskBytes, mask) != 0) return const [];
      return [
        for (var cpu = 0; cpu < _maskBytes * 8; cpu++)
          if (((mask[cpu >> 3] >> (cpu & 7)) & 1) == 1) cpu
      ];
    } finally {
      calloc.free(mask);
    }
  }

  /// Restricts [tid] (0 = calling thread; any thread of this process works,
  /// since it has the same owner) to exactly [cpus]. Returns 0 on success;
  /// on failure a non-zero code: the errno if readable, otherwise -1. (errno is
  /// read through a second FFI call and is best-effort — the per-run CPU ids
  /// in the report are the actual proof of where a run executed.)
  static int set(int tid, List<int> cpus) {
    final mask = calloc<Uint8>(_maskBytes);
    try {
      for (final cpu in cpus) {
        mask[cpu >> 3] |= 1 << (cpu & 7);
      }
      if (_setAffinity(tid, _maskBytes, mask) == 0) return 0;
      final err = _errno().value;
      return err != 0 ? err : -1;
    } finally {
      calloc.free(mask);
    }
  }

  static const int _einval = 22;

  /// [set] to the single [cpu], robust against core control (ADR 009,
  /// amendment 2026-10-10). Qualcomm's core control pauses big cores while the
  /// phone is idle (on the S22: the X2 and one A710; `offline_delay_ms` 100).
  /// Pinning to a paused core fails with EINVAL; load wakes it within about
  /// 20 ms. So on EINVAL the CALLING thread spins for [slice] and retries, for
  /// at most [timeout]. Whatever is measured must start right after this
  /// returns, before the core has been idle for `offline_delay_ms` again.
  static ({int errno, int firstErrno, int attempts, int waitMs}) pinWaking(
      int tid, int cpu,
      {Duration timeout = const Duration(seconds: 3),
      Duration slice = const Duration(milliseconds: 10)}) {
    final watch = Stopwatch()..start();
    var attempts = 0;
    var firstErrno = 0;
    while (true) {
      attempts++;
      final err = set(tid, [cpu]);
      if (attempts == 1) firstErrno = err;
      if (err != _einval || watch.elapsed >= timeout) {
        return (
          errno: err,
          firstErrno: firstErrno,
          attempts: attempts,
          waitMs: watch.elapsedMilliseconds,
        );
      }
      final spin = Stopwatch()..start();
      while (spin.elapsed < slice) {} // busy on purpose: the load wakes the core
    }
  }
}

/// CPU topology from sysfs and /proc/cpuinfo.
class CpuTopology {
  CpuTopology._();

  /// One entry per CPU: id, max frequency (kHz) and ARM part number.
  static List<Map<String, Object?>> read() {
    final parts = _cpuParts();
    final ids = possibleCpus();
    return [
      for (final cpu in ids)
        {
          'cpu': cpu,
          'max_freq_khz': _readInt(
              '/sys/devices/system/cpu/cpu$cpu/cpufreq/cpuinfo_max_freq'),
          'cpu_part': parts[cpu],
          'core_name': _coreName(parts[cpu]),
        }
    ];
  }

  /// The single fastest core ("prime") and one core of the next-fastest
  /// cluster ("big"). On a Snapdragon 8 Gen 1: 1x Cortex-X2 + 3x Cortex-A710
  /// + 4x Cortex-A510, so prime = the X2 and big = an A710.
  static ({int? prime, int? big}) pickLargeCores(
      List<Map<String, Object?>> topology) {
    final freqs = <int>{
      for (final c in topology)
        if (c['max_freq_khz'] is int) c['max_freq_khz'] as int
    }.toList()
      ..sort();
    if (freqs.isEmpty) return (prime: null, big: null);
    List<int> cpusAt(int f) => [
          for (final c in topology)
            if (c['max_freq_khz'] == f) c['cpu'] as int
        ];
    final top = cpusAt(freqs.last);
    int? big;
    if (freqs.length >= 3) {
      final second = cpusAt(freqs[freqs.length - 2]);
      big = second.isEmpty ? null : second.first;
    } else if (top.length > 1) {
      big = top.first; // plain big.LITTLE: two cores of the big cluster
    }
    return (prime: top.last, big: big);
  }

  /// Every CPU the system has (`/sys/devices/system/cpu/possible`), paused or
  /// not — the affinity to restore after pinning (the kernel still applies the
  /// app's cpuset on top).
  static List<int> possibleCpus() {
    try {
      final text =
          File('/sys/devices/system/cpu/possible').readAsStringSync().trim();
      final ids = <int>[];
      for (final part in text.split(',')) {
        final bounds = part.split('-').map(int.parse).toList();
        for (var i = bounds.first; i <= bounds.last; i++) {
          ids.add(i);
        }
      }
      return ids;
    } catch (_) {
      return List<int>.generate(Platform.numberOfProcessors, (i) => i);
    }
  }

  static Map<int, String> _cpuParts() {
    final parts = <int, String>{};
    try {
      int? current;
      for (final line in File('/proc/cpuinfo').readAsLinesSync()) {
        final kv = line.split(':');
        if (kv.length < 2) continue;
        final key = kv.first.trim();
        final value = kv.sublist(1).join(':').trim();
        if (key == 'processor') current = int.tryParse(value);
        if (key == 'CPU part' && current != null) parts[current] = value;
      }
    } catch (_) {}
    return parts;
  }

  static String? _coreName(String? part) => switch (part?.toLowerCase()) {
        '0xd46' => 'Cortex-A510',
        '0xd47' => 'Cortex-A710',
        '0xd48' => 'Cortex-X2',
        '0xd4d' => 'Cortex-A715',
        '0xd4e' => 'Cortex-X3',
        '0xd80' => 'Cortex-A520',
        '0xd81' => 'Cortex-A720',
        '0xd82' => 'Cortex-X4',
        '0xd05' => 'Cortex-A55',
        '0xd0d' => 'Cortex-A77',
        '0xd41' => 'Cortex-A78',
        '0xd44' => 'Cortex-X1',
        _ => null,
      };
}

/// Process memory from /proc/self — usable from any isolate (no FFI needed).
class ProcMemory {
  ProcMemory._();

  /// `/proc/self/status`: VmRSS (resident now), VmHWM (peak resident since the
  /// process started — an upper bound for any "peak memory"), RssAnon, RssFile.
  static Map<String, int> statusKb() => _parseKb('/proc/self/status',
      const {'VmRSS', 'VmHWM', 'VmSize', 'VmPeak', 'RssAnon', 'RssFile', 'VmSwap'});

  /// `/proc/self/smaps_rollup`: Pss (proportional set size, the metric
  /// `dumpsys meminfo` is built on, minus GPU/graphics memory it adds from
  /// the memtrack HAL), Rss, and their breakdown.
  static Map<String, int> smapsRollupKb() => _parseKb('/proc/self/smaps_rollup',
      const {'Rss', 'Pss', 'Pss_Anon', 'Pss_File', 'Private_Dirty', 'Swap', 'SwapPss'});

  static Map<String, int> _parseKb(String path, Set<String> keys) {
    final out = <String, int>{};
    try {
      for (final line in File(path).readAsLinesSync()) {
        final colon = line.indexOf(':');
        if (colon <= 0) continue;
        final key = line.substring(0, colon);
        if (!keys.contains(key)) continue;
        final value = line.substring(colon + 1).trim().split(RegExp(r'\s+')).first;
        final n = int.tryParse(value);
        if (n != null) out[key] = n;
      }
    } catch (_) {}
    return out;
  }
}

int? _readInt(String path) {
  try {
    return int.tryParse(File(path).readAsStringSync().trim());
  } catch (_) {
    return null;
  }
}
