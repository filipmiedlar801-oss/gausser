import { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { SafeAreaView } from 'react-native-safe-area-context';
import * as Sharing from 'expo-sharing';

import {
  CoverageEvent,
  CoverageHole,
  GaussianScan,
  GaussianScanView,
  SessionMeta,
} from '../../modules/gaussian-scan';
import { colors } from '../../lib/theme';

export default function ReviewScreen() {
  const router = useRouter();
  const { id } = useLocalSearchParams<{ id: string }>();
  const [coverage, setCoverage] = useState<CoverageEvent | null>(null);
  const [meta, setMeta] = useState<SessionMeta | null>(null);
  const [exporting, setExporting] = useState(false);

  useEffect(() => {
    GaussianScan.listSessions().then((sessions) => {
      setMeta(sessions.find((s) => s.id === id) ?? null);
    });
  }, [id]);

  const stats = coverage?.stats ?? meta?.coverage ?? null;
  const holes: CoverageHole[] = coverage?.holes ?? [];
  const biggestHole = holes.length > 0 ? holes[0] : null;

  const rescan = () => {
    const params: Record<string, string> = { sessionId: id, resume: '1' };
    if (biggestHole) {
      params.wx = String(biggestHole.x);
      params.wy = String(biggestHole.y);
      params.wz = String(biggestHole.z);
    }
    router.replace({ pathname: '/scan', params });
  };

  const exportPhotos = async () => {
    setExporting(true);
    try {
      const zipUri = await GaussianScan.exportZip(id);
      await Sharing.shareAsync(zipUri, {
        mimeType: 'application/zip',
        dialogTitle: 'Eksport zdjęć do treningu',
      });
    } catch (e: unknown) {
      Alert.alert('Eksport nie powiódł się', e instanceof Error ? e.message : String(e));
    } finally {
      setExporting(false);
    }
  };

  const confirmDelete = () => {
    Alert.alert('Usunąć skan?', 'Zdjęcia i dane tego skanu zostaną trwale usunięte.', [
      { text: 'Anuluj', style: 'cancel' },
      {
        text: 'Usuń',
        style: 'destructive',
        onPress: async () => {
          await GaussianScan.deleteSession(id);
          router.replace('/');
        },
      },
    ]);
  };

  const greenPct = Math.round((stats?.green ?? 0) * 100);
  const yellowPct = Math.round((stats?.yellow ?? 0) * 100);
  const redPct = Math.max(0, 100 - greenPct - yellowPct);

  return (
    <SafeAreaView style={styles.container} edges={['top']}>
      <View style={styles.header}>
        <Pressable onPress={() => router.replace('/')} hitSlop={12}>
          <Text style={styles.back}>‹ Skany</Text>
        </Pressable>
        <Text style={styles.title}>Mapa pewności</Text>
        <Pressable onPress={confirmDelete} hitSlop={12}>
          <Text style={styles.delete}>Usuń</Text>
        </Pressable>
      </View>

      {/* 3D confidence map — orbit with one finger */}
      <View style={styles.viewer}>
        <GaussianScanView
          mode="review"
          sessionId={id}
          style={StyleSheet.absoluteFill}
          onCoverage={(e) => setCoverage(e.nativeEvent)}
        />
        <Text style={styles.viewerHint}>Obracaj model palcem</Text>
      </View>

      <ScrollView style={styles.details} contentContainerStyle={{ paddingBottom: 32 }}>
        {stats ? (
          <>
            <View style={styles.coverageBar}>
              <View style={{ flex: Math.max(greenPct, 1), backgroundColor: colors.green }} />
              <View style={{ flex: Math.max(yellowPct, 1), backgroundColor: colors.yellow }} />
              <View style={{ flex: Math.max(redPct, 1), backgroundColor: colors.red }} />
            </View>
            <View style={styles.legendRow}>
              <Legend color={colors.green} label={`Pełne ${greenPct}%`} />
              <Legend color={colors.yellow} label={`Jeden kąt ${yellowPct}%`} />
              <Legend color={colors.red} label={`Brak ${redPct}%`} />
            </View>

            <View style={styles.classRow}>
              <ClassStat label="Ściany" value={stats.wallsGreen} />
              <ClassStat label="Sufit" value={stats.ceilingGreen} />
              <ClassStat label="Podłoga" value={stats.floorGreen} />
            </View>
          </>
        ) : (
          <Text style={styles.noData}>Brak danych o pokryciu dla tego skanu.</Text>
        )}

        <Text style={styles.sectionTitle}>
          {holes.length > 0
            ? `Do uzupełnienia: ${holes.length}`
            : 'Pokrycie multi-view kompletne ✓'}
        </Text>
        {holes.slice(0, 5).map((hole, i) => (
          <Text key={i} style={styles.holeItem}>
            • obszar {i + 1} — ok. {Math.max(1, Math.round(hole.size * 0.36))} m² (brak lub jeden
            kąt)
          </Text>
        ))}

        <Text style={styles.frames}>
          Zebrane klatki treningowe: {meta?.frameCount ?? 0}
        </Text>

        {holes.length > 0 ? (
          <Pressable style={[styles.button, { backgroundColor: colors.accent }]} onPress={rescan}>
            <Text style={styles.buttonText}>Doskanuj braki</Text>
          </Pressable>
        ) : null}

        <Pressable
          style={[styles.button, { backgroundColor: colors.green }]}
          onPress={exportPhotos}
          disabled={exporting}
        >
          {exporting ? (
            <ActivityIndicator color="#fff" />
          ) : (
            <Text style={styles.buttonText}>Eksportuj zdjęcia (ZIP)</Text>
          )}
        </Pressable>
      </ScrollView>
    </SafeAreaView>
  );
}

function Legend({ color, label }: { color: string; label: string }) {
  return (
    <View style={styles.legend}>
      <View style={[styles.legendDot, { backgroundColor: color }]} />
      <Text style={styles.legendText}>{label}</Text>
    </View>
  );
}

function ClassStat({ label, value }: { label: string; value: number }) {
  const pct = Math.round(value * 100);
  const color = pct >= 70 ? colors.green : pct >= 35 ? colors.yellow : colors.red;
  return (
    <View style={styles.classBox}>
      <Text style={[styles.classValue, { color }]}>{pct}%</Text>
      <Text style={styles.classLabel}>{label}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.bg },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 20,
    paddingVertical: 12,
  },
  back: { color: colors.accent, fontSize: 16 },
  title: { color: colors.text, fontSize: 17, fontWeight: '700' },
  delete: { color: colors.red, fontSize: 15 },
  viewer: {
    height: 300,
    marginHorizontal: 16,
    borderRadius: 16,
    overflow: 'hidden',
    backgroundColor: '#111',
    borderWidth: 1,
    borderColor: colors.border,
  },
  viewerHint: {
    position: 'absolute',
    bottom: 8,
    alignSelf: 'center',
    color: colors.textDim,
    fontSize: 12,
  },
  details: { flex: 1, paddingHorizontal: 20, marginTop: 16 },
  coverageBar: {
    flexDirection: 'row',
    height: 12,
    borderRadius: 6,
    overflow: 'hidden',
  },
  legendRow: { flexDirection: 'row', justifyContent: 'space-between', marginTop: 8 },
  legend: { flexDirection: 'row', alignItems: 'center', gap: 5 },
  legendDot: { width: 8, height: 8, borderRadius: 4 },
  legendText: { color: colors.textDim, fontSize: 12 },
  classRow: { flexDirection: 'row', gap: 10, marginTop: 16 },
  classBox: {
    flex: 1,
    backgroundColor: colors.surface,
    borderRadius: 12,
    paddingVertical: 12,
    alignItems: 'center',
    borderWidth: 1,
    borderColor: colors.border,
  },
  classValue: { fontSize: 18, fontWeight: '700' },
  classLabel: { color: colors.textDim, fontSize: 12, marginTop: 2 },
  sectionTitle: { color: colors.text, fontSize: 16, fontWeight: '600', marginTop: 20 },
  holeItem: { color: colors.textDim, fontSize: 14, marginTop: 6, lineHeight: 20 },
  frames: { color: colors.textDim, fontSize: 14, marginTop: 16 },
  noData: { color: colors.textDim, fontSize: 14 },
  button: {
    borderRadius: 14,
    paddingVertical: 15,
    alignItems: 'center',
    marginTop: 14,
  },
  buttonText: { color: '#fff', fontSize: 16, fontWeight: '700' },
});
