import { requireNativeView } from 'expo';
import * as React from 'react';
import type { StyleProp, ViewStyle } from 'react-native';

import type {
  CoverageEvent,
  GuidanceEvent,
  KeyframeEvent,
  MetricsEvent,
  ScanMode,
  ScanSummary,
  SessionStateEvent,
} from './GaussianScan.types';

export type GaussianScanViewRef = {
  startScan(sessionId: string, resume: boolean): Promise<void>;
  stopScan(): Promise<ScanSummary>;
  lockExposure(): Promise<void>;
  unlockExposure(): Promise<void>;
  setWaypoint(x: number, y: number, z: number): Promise<void>;
  clearWaypoint(): Promise<void>;
};

export type GaussianScanViewProps = {
  mode: ScanMode;
  sessionId?: string;
  style?: StyleProp<ViewStyle>;
  onMetrics?: (event: { nativeEvent: MetricsEvent }) => void;
  onGuidance?: (event: { nativeEvent: GuidanceEvent }) => void;
  onCoverage?: (event: { nativeEvent: CoverageEvent }) => void;
  onKeyframe?: (event: { nativeEvent: KeyframeEvent }) => void;
  onSessionState?: (event: { nativeEvent: SessionStateEvent }) => void;
};

const NativeView = requireNativeView<GaussianScanViewProps & { ref?: React.Ref<GaussianScanViewRef> }>(
  'GaussianScan'
);

export const GaussianScanView = React.forwardRef<GaussianScanViewRef, GaussianScanViewProps>(
  (props, ref) => {
    return <NativeView {...props} ref={ref as React.Ref<GaussianScanViewRef>} />;
  }
);

GaussianScanView.displayName = 'GaussianScanView';
