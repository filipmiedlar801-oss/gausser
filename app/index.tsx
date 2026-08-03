import { useCallback, useState } from 'react';
import {
  Alert,
  FlatList,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { useFocusEffect, useRouter } from 'expo-router';
import { SafeAreaView } from 'react-native-safe-area-context';

import { GaussianScan, SessionMeta } from '../modules/gaussian-scan';
import { colors } from '../lib/theme';

function formatDate(ms?: number): string {
  if (!ms) return '—';
  const d = new Date(ms);
  return d.toLocaleDateString('pl-PL', {
    day: 'numeric',
    month: 'short',
    hour: '2-digit',
    minute: '2-digit',
  });
}

function CoverageBadge({ meta }: { meta: SessionMeta }) {
  const green = meta.coverage?.green ?? 0;
  const pct = Math.round(green * 100);
  const color = pct >= 70 ? colors.green : pct >= 35 ? colors.yellow : colors.red;
  return (
    <View style={[styles.badge, { borderColor: color }]}>
      <Text style={[styles.badgeText, { color }]}>{pct}%</Text>
    </View>
  );
}

export default function HomeScreen() {
  const router = useRouter();
  const [sessions, setSessions] = useState<SessionMeta[]>([]);
  const hasLiDAR = GaussianScan.hasLiDAR();

  const reload = useCallback(() => {
    GaussianScan.listSessions().then(setSessions).catch(() => setSessions([]));
  }, []);

  useFocusEffect(
    useCallback(() => {
      reload();
    }, [reload])
  );

  const confirmDelete = (id: string) => {
    Alert.alert('Usunąć skan?', 'Zdjęcia i dane tego skanu zostaną trwale usunięte.', [
      { text: 'Anuluj', style: 'cancel' },
      {
        text: 'Usuń',
        style: 'destructive',
        onPress: async () => {
          await GaussianScan.deleteSession(id);
          reload();
        },
      },
    ]);
  };

  return (
    <SafeAreaView style={styles.container}>
      <View style={styles.header}>
        <View>
          <Text style={styles.title}>Gaussian Scanner</Text>
          <Text style={styles.subtitle}>
            {hasLiDAR ? 'LiDAR aktywny' : 'Tryb bez LiDAR (uproszczona mapa pokrycia)'}
          </Text>
        </View>
      </View>

      <FlatList
        data={sessions}
        keyExtractor={(item) => item.id}
        contentContainerStyle={styles.list}
        ListEmptyComponent={
          <View style={styles.empty}>
            <Text style={styles.emptyTitle}>Brak skanów</Text>
            <Text style={styles.emptyText}>
              Zacznij od nowego skanu — kreator sprawdzi warunki, a potem poprowadzi Cię przez
              pomieszczenie.
            </Text>
          </View>
        }
        renderItem={({ item }) => (
          <Pressable
            style={styles.card}
            onPress={() => router.push({ pathname: '/review/[id]', params: { id: item.id } })}
            onLongPress={() => confirmDelete(item.id)}
          >
            <View style={{ flex: 1 }}>
              <Text style={styles.cardTitle}>Skan {formatDate(item.createdAt)}</Text>
              <Text style={styles.cardMeta}>
                {item.frameCount ?? 0} klatek ·{' '}
                {item.state === 'done' ? 'zakończony' : 'przerwany'}
              </Text>
            </View>
            <CoverageBadge meta={item} />
          </Pressable>
        )}
      />

      <Pressable style={styles.newButton} onPress={() => router.push('/wizard')}>
        <Text style={styles.newButtonText}>Nowy skan</Text>
      </Pressable>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.bg },
  header: {
    paddingHorizontal: 20,
    paddingTop: 12,
    paddingBottom: 16,
  },
  title: { color: colors.text, fontSize: 28, fontWeight: '700' },
  subtitle: { color: colors.textDim, fontSize: 13, marginTop: 4 },
  list: { paddingHorizontal: 20, paddingBottom: 120, gap: 10 },
  card: {
    backgroundColor: colors.surface,
    borderRadius: 14,
    borderWidth: 1,
    borderColor: colors.border,
    padding: 16,
    flexDirection: 'row',
    alignItems: 'center',
    marginBottom: 10,
  },
  cardTitle: { color: colors.text, fontSize: 16, fontWeight: '600' },
  cardMeta: { color: colors.textDim, fontSize: 13, marginTop: 3 },
  badge: {
    borderWidth: 1.5,
    borderRadius: 999,
    paddingHorizontal: 10,
    paddingVertical: 5,
  },
  badgeText: { fontSize: 14, fontWeight: '700' },
  empty: { alignItems: 'center', paddingTop: 120, paddingHorizontal: 32 },
  emptyTitle: { color: colors.text, fontSize: 18, fontWeight: '600' },
  emptyText: { color: colors.textDim, fontSize: 14, textAlign: 'center', marginTop: 8, lineHeight: 20 },
  newButton: {
    position: 'absolute',
    bottom: 40,
    left: 20,
    right: 20,
    backgroundColor: colors.accent,
    borderRadius: 16,
    paddingVertical: 17,
    alignItems: 'center',
  },
  newButtonText: { color: '#fff', fontSize: 17, fontWeight: '700' },
});
