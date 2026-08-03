# Gaussian Scanner

Aplikacja iOS (React Native + Expo + natywny moduł Swift/ARKit) do zbierania wysokiej jakości zdjęć pod trening gaussian splatów.

## Co robi

1. **Wizard pre-scan** — sprawdza warunki przed skanem: jasność (lux z ARKit), czystość obiektywu (test ostrości), HDR (wyłączany automatycznie), blokada ekspozycji.
2. **Skanowanie z prowadzeniem** — wskazówki po polsku w czasie rzeczywistym: „Zwolnij", „Podejdź bliżej ścian", „Pokaż sufit", „Obejdź z innych kątów" itd.
3. **Mapa pokrycia 3D (multi-view)** — z LiDAR: płaszczyzny na meshu + punkty z depth (~5 cm). Zielony = ≥2 kierunki widoku; żółty = jeden kąt; czerwony = brak. Bez LiDAR: kafle 10 cm + ARPointCloud.
4. **Selekcja keyframe'ów** — Laplace + Tenengrad (texture-aware ostrość), baseline pose, dobry tracking. Zdjęcia 12 MP przez `captureHighResolutionFrame`.
5. **Mapa pewności / review** — obracany model 3D, braki (najpierw czerwone, potem żółte), „Doskanuj braki" z waypointem (ARWorldMap).
6. **Eksport** — ZIP z samymi zdjęciami przez share sheet. Manifest z pozami/intrinsics zostaje w sesji na potrzeby audytu.

## Wymagania

- iPhone z iOS 16.4+ (ARKit nie działa w symulatorze)
- Pełna mapa pokrycia wymaga LiDAR (iPhone Pro); pozostałe urządzenia dostają uproszczony fallback
- Xcode 16+ z zainstalowaną platformą iOS

## Uruchomienie

```bash
npm install
npx expo prebuild --platform ios   # generuje projekt ios/
npx expo run:ios --device          # build + instalacja na podłączonym iPhonie
```

Aplikacja używa expo-dev-client (natywny moduł nie działa w Expo Go).

## Struktura

- `modules/gaussian-scan/ios/` — natywny rdzeń Swift:
  - `ScanController.swift` — sesja AR, orkiestracja
  - `FrameQualityAnalyzer.swift` — ostrość (Laplace/vImage), prędkość, tracking, ekspozycja
  - `CoverageEngine.swift` — hybrydowa mapa pokrycia (planar mesh LiDAR + point cloud / fallback płaszczyzny + feature points)
  - `KeyframeWriter.swift` — selekcja i zapis klatek treningowych
  - `GuidanceEngine.swift` — maszyna reguł wskazówek
  - `SessionStore.swift` — magazyn sesji + eksport ZIP
- `app/` — ekrany (expo-router): home, wizard, skan, review
- `lib/` — teksty wskazówek PL, motyw

## Dane sesji

`Documents/scans/<id>/`: `images/*.jpg`, `manifest.json` (pozy, intrinsics, ostrość), `coverage.json`, `coverage.bin`, `scene.scn` (model 3D do review), `worldmap.bin` (relokalizacja), `meta.json`.
