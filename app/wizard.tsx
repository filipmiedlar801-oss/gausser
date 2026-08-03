import { useRef, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { useRouter } from 'expo-router';
import { SafeAreaView } from 'react-native-safe-area-context';

import {
  GaussianScanView,
  GaussianScanViewRef,
  MetricsEvent,
} from '../modules/gaussian-scan';
import { colors } from '../lib/theme';

type StepStatus = 'pass' | 'warn' | 'fail';

const STEPS = [
  { key: 'light', title: 'Oświetlenie', icon: '1' },
  { key: 'lens', title: 'Czysty obiektyw', icon: '2' },
  { key: 'hdr', title: 'HDR wyłączony', icon: '3' },
  { key: 'exposure', title: 'Stabilna ekspozycja', icon: '4' },
] as const;

function newSessionId(): string {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

export default function WizardScreen() {
  const router = useRouter();
  const viewRef = useRef<GaussianScanViewRef>(null);
  const [step, setStep] = useState(0);
  const [metrics, setMetrics] = useState<MetricsEvent | null>(null);
  const [exposureLocked, setExposureLocked] = useState(false);

  const lux = metrics?.lux ?? 0;
  const sharp = metrics?.sharpness01 ?? 0;

  const lightStatus: StepStatus = lux >= 450 ? 'pass' : lux >= 250 ? 'warn' : 'fail';
  const lensStatus: StepStatus = sharp >= 0.35 ? 'pass' : sharp >= 0.2 ? 'warn' : 'fail';

  const statusColor = (s: StepStatus) =>
    s === 'pass' ? colors.green : s === 'warn' ? colors.yellow : colors.red;

  const startScan = () => {
    const sessionId = newSessionId();
    router.replace({ pathname: '/scan', params: { sessionId } });
  };

  const lockExposure = async () => {
    try {
      await viewRef.current?.lockExposure();
      setExposureLocked(true);
    } catch {
      // Device does not expose a configurable camera — continue anyway.
      setExposureLocked(true);
    }
  };

  const renderStepContent = () => {
    switch (STEPS[step].key) {
      case 'light':
        return (
          <>
            <Text style={styles.stepText}>
              Rozejrzyj się po pomieszczeniu. Do dobrego skanu potrzeba równego, jasnego światła —
              najlepiej dziennego lub kilku włączonych lamp.
            </Text>
            <View style={styles.meterRow}>
              <Text style={styles.meterLabel}>Jasność</Text>
              <Text style={[styles.meterValue, { color: statusColor(lightStatus) }]}>
                {Math.round(lux)} lx
              </Text>
            </View>
            <Meter value={Math.min(1, lux / 900)} color={statusColor(lightStatus)} />
            <Text style={[styles.verdict, { color: statusColor(lightStatus) }]}>
              {lightStatus === 'pass'
                ? 'Wystarczająco jasno ✓'
                : lightStatus === 'warn'
                  ? 'Trochę ciemno — rozważ włączenie światła'
                  : 'Za ciemno — włącz światło'}
            </Text>
            <NextButton
              label="Dalej"
              enabled={lightStatus !== 'fail'}
              onPress={() => setStep(1)}
            />
          </>
        );
      case 'lens':
        return (
          <>
            <Text style={styles.stepText}>
              Przetrzyj obiektyw miękką szmatką, a potem wyceluj telefon w coś z wyraźną teksturą
              (książka, dywan) z odległości ~0,5 m.
            </Text>
            <View style={styles.meterRow}>
              <Text style={styles.meterLabel}>Ostrość obrazu</Text>
              <Text style={[styles.meterValue, { color: statusColor(lensStatus) }]}>
                {Math.round(sharp * 100)}%
              </Text>
            </View>
            <Meter value={sharp} color={statusColor(lensStatus)} />
            <Text style={[styles.verdict, { color: statusColor(lensStatus) }]}>
              {lensStatus === 'pass'
                ? 'Obraz ostry — obiektyw czysty ✓'
                : 'Obraz miękki — przetrzyj obiektyw i wyceluj w teksturę'}
            </Text>
            <NextButton label="Dalej" enabled={lensStatus === 'pass'} onPress={() => setStep(2)} />
          </>
        );
      case 'hdr':
        return (
          <>
            <Text style={styles.stepText}>
              HDR skleja kilka ekspozycji w jedną klatkę i psuje spójność zdjęć treningowych.
            </Text>
            <Text style={[styles.verdict, { color: colors.green }]}>
              HDR w strumieniu kamery jest wyłączony automatycznie ✓
            </Text>
            <NextButton label="Dalej" enabled onPress={() => setStep(3)} />
          </>
        );
      case 'exposure':
        return (
          <>
            <Text style={styles.stepText}>
              Wyceluj telefon w środek pomieszczenia (przeciętnie jasne miejsce) i zablokuj
              ekspozycję. Dzięki temu wszystkie zdjęcia będą miały tę samą jasność.
            </Text>
            {metrics ? (
              <Text style={styles.exposureInfo}>
                ISO {Math.round(metrics.iso)} · czas {(metrics.exposureDuration * 1000).toFixed(1)} ms
              </Text>
            ) : null}
            {!exposureLocked ? (
              <NextButton label="Zablokuj ekspozycję" enabled onPress={lockExposure} />
            ) : (
              <>
                <Text style={[styles.verdict, { color: colors.green }]}>
                  Ekspozycja zablokowana ✓
                </Text>
                <NextButton label="Rozpocznij skanowanie" enabled onPress={startScan} accent />
              </>
            )}
          </>
        );
    }
  };

  return (
    <View style={styles.container}>
      <GaussianScanView
        ref={viewRef}
        mode="wizard"
        style={StyleSheet.absoluteFill}
        onMetrics={(e) => setMetrics(e.nativeEvent)}
      />
      <SafeAreaView style={styles.overlay} pointerEvents="box-none">
        <View style={styles.topBar}>
          <Pressable onPress={() => router.back()} hitSlop={12}>
            <Text style={styles.cancel}>Anuluj</Text>
          </Pressable>
          <View style={styles.stepDots}>
            {STEPS.map((s, i) => (
              <View
                key={s.key}
                style={[
                  styles.dot,
                  i === step && styles.dotActive,
                  i < step && { backgroundColor: colors.green },
                ]}
              />
            ))}
          </View>
        </View>

        <View style={styles.panel}>
          <Text style={styles.stepKicker}>
            Krok {step + 1} z {STEPS.length}
          </Text>
          <Text style={styles.stepTitle}>{STEPS[step].title}</Text>
          {renderStepContent()}
        </View>
      </SafeAreaView>
    </View>
  );
}

function Meter({ value, color }: { value: number; color: string }) {
  return (
    <View style={styles.meterTrack}>
      <View
        style={[
          styles.meterFill,
          { width: `${Math.round(Math.max(0.02, Math.min(1, value)) * 100)}%`, backgroundColor: color },
        ]}
      />
    </View>
  );
}

function NextButton({
  label,
  enabled,
  onPress,
  accent,
}: {
  label: string;
  enabled: boolean;
  onPress: () => void;
  accent?: boolean;
}) {
  return (
    <Pressable
      style={[
        styles.nextButton,
        accent && { backgroundColor: colors.green },
        !enabled && { opacity: 0.35 },
      ]}
      disabled={!enabled}
      onPress={onPress}
    >
      <Text style={styles.nextButtonText}>{label}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.bg },
  overlay: { flex: 1, justifyContent: 'space-between' },
  topBar: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 20,
    paddingTop: 8,
  },
  cancel: { color: '#fff', fontSize: 16, textShadowColor: '#000', textShadowRadius: 4 },
  stepDots: { flexDirection: 'row', gap: 8 },
  dot: {
    width: 8,
    height: 8,
    borderRadius: 4,
    backgroundColor: 'rgba(255,255,255,0.35)',
  },
  dotActive: { backgroundColor: '#fff' },
  panel: {
    backgroundColor: 'rgba(11,13,16,0.92)',
    borderRadius: 20,
    margin: 16,
    padding: 20,
    borderWidth: 1,
    borderColor: colors.border,
  },
  stepKicker: { color: colors.textDim, fontSize: 12, textTransform: 'uppercase', letterSpacing: 1 },
  stepTitle: { color: colors.text, fontSize: 22, fontWeight: '700', marginTop: 4, marginBottom: 10 },
  stepText: { color: colors.textDim, fontSize: 14, lineHeight: 20, marginBottom: 14 },
  meterRow: { flexDirection: 'row', justifyContent: 'space-between', marginBottom: 6 },
  meterLabel: { color: colors.text, fontSize: 14 },
  meterValue: { fontSize: 14, fontWeight: '700' },
  meterTrack: {
    height: 8,
    borderRadius: 4,
    backgroundColor: colors.surfaceLight,
    overflow: 'hidden',
  },
  meterFill: { height: 8, borderRadius: 4 },
  verdict: { fontSize: 14, fontWeight: '600', marginTop: 12 },
  exposureInfo: { color: colors.textDim, fontSize: 13, marginBottom: 6 },
  nextButton: {
    backgroundColor: colors.accent,
    borderRadius: 14,
    paddingVertical: 15,
    alignItems: 'center',
    marginTop: 16,
  },
  nextButtonText: { color: '#fff', fontSize: 16, fontWeight: '700' },
});
