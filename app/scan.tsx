import { useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { SafeAreaView } from 'react-native-safe-area-context';

import {
  CoverageEvent,
  GaussianScanView,
  GaussianScanViewRef,
  GuidanceEvent,
  MetricsEvent,
} from '../modules/gaussian-scan';
import { guidanceText, TRANSIENT_CODES } from '../lib/guidance';
import { colors } from '../lib/theme';

export default function ScanScreen() {
  const router = useRouter();
  const params = useLocalSearchParams<{
    sessionId: string;
    resume?: string;
    wx?: string;
    wy?: string;
    wz?: string;
  }>();
  const sessionId = params.sessionId;
  const viewRef = useRef<GaussianScanViewRef>(null);

  const [metrics, setMetrics] = useState<MetricsEvent | null>(null);
  const [coverage, setCoverage] = useState<CoverageEvent | null>(null);
  const [hint, setHint] = useState<GuidanceEvent | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  const [stopping, setStopping] = useState(false);
  const toastTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    let cancelled = false;
    // Give the native view one frame to mount before starting the session.
    const t = setTimeout(async () => {
      if (cancelled) return;
      try {
        await viewRef.current?.startScan(sessionId, params.resume === '1');
        if (params.wx && params.wy && params.wz) {
          await viewRef.current?.setWaypoint(
            parseFloat(params.wx),
            parseFloat(params.wy),
            parseFloat(params.wz)
          );
        }
      } catch {
        // Session failed to start; the user can back out.
      }
    }, 150);
    return () => {
      cancelled = true;
      clearTimeout(t);
      if (toastTimer.current) clearTimeout(toastTimer.current);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId]);

  const onGuidance = (e: { nativeEvent: GuidanceEvent }) => {
    const g = e.nativeEvent;
    if (TRANSIENT_CODES.has(g.code)) {
      setToast(guidanceText(g.code));
      if (toastTimer.current) clearTimeout(toastTimer.current);
      toastTimer.current = setTimeout(() => setToast(null), 2500);
    } else {
      setHint(g);
    }
  };

  const stop = async () => {
    if (stopping) return;
    setStopping(true);
    try {
      await viewRef.current?.stopScan();
    } catch {
      // Even if finalization partially failed, move on to review.
    }
    router.replace({ pathname: '/review/[id]', params: { id: sessionId } });
  };

  const greenPct = Math.round((coverage?.stats.green ?? 0) * 100);
  const yellowPct = Math.round((coverage?.stats.yellow ?? 0) * 100);
  const keyframes = metrics?.keyframes ?? 0;
  const hintCode = hint?.code ?? 'initializing';
  const isWarning = !['good', 'initializing', 'goto_gap'].includes(hintCode);

  const trackingColor =
    metrics?.trackingState === 'normal'
      ? colors.green
      : metrics?.trackingState === 'limited'
        ? colors.yellow
        : colors.red;

  return (
    <View style={styles.container}>
      <GaussianScanView
        ref={viewRef}
        mode="scan"
        style={StyleSheet.absoluteFill}
        onMetrics={(e) => setMetrics(e.nativeEvent)}
        onCoverage={(e) => setCoverage(e.nativeEvent)}
        onGuidance={onGuidance}
      />

      <SafeAreaView style={styles.overlay} pointerEvents="box-none">
        {/* Guidance banner */}
        <View style={styles.topArea} pointerEvents="none">
          <View style={[styles.banner, isWarning && styles.bannerWarning]}>
            <Text style={styles.bannerText}>{guidanceText(hintCode)}</Text>
          </View>
          {toast ? (
            <View style={[styles.banner, styles.bannerSuccess]}>
              <Text style={styles.bannerText}>{toast}</Text>
            </View>
          ) : null}
          {metrics?.waypoint ? (
            <View style={styles.waypointRow}>
              <Text
                style={[
                  styles.waypointArrow,
                  { transform: [{ rotate: `${Math.round(metrics.waypoint.bearing)}deg` }] },
                ]}
              >
                ↑
              </Text>
              <Text style={styles.waypointText}>
                {metrics.waypoint.distance.toFixed(1)} m do brakującego miejsca
              </Text>
            </View>
          ) : null}
        </View>

        {/* Bottom HUD */}
        <View style={styles.hud} pointerEvents="box-none">
          <View style={styles.metricsRow} pointerEvents="none">
            <MetricBar
              label="Ostrość"
              value={metrics?.sharpness01 ?? 0}
              color={(metrics?.sharpness01 ?? 0) >= 0.3 ? colors.green : colors.red}
            />
            <MetricBar
              label="Tempo"
              value={Math.min(1, (metrics?.speed ?? 0) / 1.0)}
              color={(metrics?.speed ?? 0) <= 0.65 ? colors.green : colors.red}
            />
            <View style={styles.trackingBox}>
              <View style={[styles.trackingDot, { backgroundColor: trackingColor }]} />
              <Text style={styles.trackingLabel}>Tracking</Text>
            </View>
          </View>

          <View style={styles.statsRow} pointerEvents="none">
            <View style={styles.statBox}>
              <Text style={[styles.statValue, { color: colors.green }]}>{greenPct}%</Text>
              <Text style={styles.statLabel}>pokrycie</Text>
            </View>
            <View style={styles.statBox}>
              <Text style={[styles.statValue, { color: colors.yellow }]}>{yellowPct}%</Text>
              <Text style={styles.statLabel}>1 kąt</Text>
            </View>
            <View style={styles.statBox}>
              <Text style={styles.statValue}>{keyframes}</Text>
              <Text style={styles.statLabel}>klatek</Text>
            </View>
          </View>

          <Pressable style={styles.stopButton} onPress={stop} disabled={stopping}>
            {stopping ? (
              <ActivityIndicator color="#fff" />
            ) : (
              <Text style={styles.stopButtonText}>Zakończ skan</Text>
            )}
          </Pressable>
        </View>
      </SafeAreaView>
    </View>
  );
}

function MetricBar({ label, value, color }: { label: string; value: number; color: string }) {
  return (
    <View style={styles.metricBox}>
      <Text style={styles.metricLabel}>{label}</Text>
      <View style={styles.metricTrack}>
        <View
          style={[
            styles.metricFill,
            { width: `${Math.round(Math.max(0.04, Math.min(1, value)) * 100)}%`, backgroundColor: color },
          ]}
        />
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.bg },
  overlay: { flex: 1, justifyContent: 'space-between' },
  topArea: { alignItems: 'center', paddingTop: 8, gap: 8 },
  banner: {
    backgroundColor: 'rgba(11,13,16,0.85)',
    borderRadius: 999,
    paddingHorizontal: 20,
    paddingVertical: 10,
    borderWidth: 1,
    borderColor: colors.border,
  },
  bannerWarning: { borderColor: colors.yellow },
  bannerSuccess: { borderColor: colors.green },
  bannerText: { color: '#fff', fontSize: 16, fontWeight: '600' },
  waypointRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    backgroundColor: 'rgba(11,13,16,0.85)',
    borderRadius: 999,
    paddingHorizontal: 14,
    paddingVertical: 6,
  },
  waypointArrow: { color: colors.green, fontSize: 22, fontWeight: '700' },
  waypointText: { color: colors.text, fontSize: 13 },
  hud: { paddingHorizontal: 16, paddingBottom: 8, gap: 10 },
  metricsRow: { flexDirection: 'row', gap: 10, alignItems: 'flex-end' },
  metricBox: {
    flex: 1,
    backgroundColor: 'rgba(11,13,16,0.85)',
    borderRadius: 12,
    padding: 10,
  },
  metricLabel: { color: colors.textDim, fontSize: 11, marginBottom: 5 },
  metricTrack: { height: 6, borderRadius: 3, backgroundColor: colors.surfaceLight, overflow: 'hidden' },
  metricFill: { height: 6, borderRadius: 3 },
  trackingBox: {
    backgroundColor: 'rgba(11,13,16,0.85)',
    borderRadius: 12,
    padding: 10,
    alignItems: 'center',
    gap: 4,
  },
  trackingDot: { width: 12, height: 12, borderRadius: 6 },
  trackingLabel: { color: colors.textDim, fontSize: 11 },
  statsRow: {
    flexDirection: 'row',
    backgroundColor: 'rgba(11,13,16,0.85)',
    borderRadius: 14,
    paddingVertical: 10,
  },
  statBox: { flex: 1, alignItems: 'center' },
  statValue: { color: colors.text, fontSize: 20, fontWeight: '700' },
  statLabel: { color: colors.textDim, fontSize: 11, marginTop: 2 },
  stopButton: {
    backgroundColor: colors.red,
    borderRadius: 16,
    paddingVertical: 16,
    alignItems: 'center',
    marginBottom: 8,
  },
  stopButtonText: { color: '#fff', fontSize: 17, fontWeight: '700' },
});
