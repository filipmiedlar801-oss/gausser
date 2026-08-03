export type ScanMode = 'wizard' | 'scan' | 'review';

export type MetricsEvent = {
  sharpness: number;
  sharpness01: number;
  speed: number;
  angularSpeed: number;
  trackingState: 'normal' | 'limited' | 'notAvailable';
  trackingReason: string;
  lux: number;
  iso: number;
  exposureDuration: number;
  exposureLocked: boolean;
  motionBlurRisk: number;
  medianDepth: number;
  keyframes: number;
  waypoint?: {
    bearing: number;
    elevation: number;
    distance: number;
  };
};

export type GuidanceEvent = {
  code: string;
  distance?: number;
  reason?: string;
};

export type CoverageStats = {
  green: number;
  yellow: number;
  red: number;
  wallsGreen: number;
  ceilingGreen: number;
  floorGreen: number;
  ceilingSamples?: number;
  floorSamples?: number;
  medianDepth: number;
  totalSamples: number;
};

export type CoverageHole = {
  x: number;
  y: number;
  z: number;
  size: number;
};

export type CoverageEvent = {
  stats: CoverageStats;
  holes: CoverageHole[];
  final?: boolean;
};

export type KeyframeEvent = {
  index: number;
  uri: string;
  sharpness: number;
  total: number;
};

export type SessionStateEvent = {
  state: 'wizard' | 'scanning' | 'stopped' | 'review';
  sessionId: string;
  hasLiDAR: boolean;
};

export type ScanSummary = {
  sessionId: string;
  frameCount: number;
  coverage: CoverageStats;
  holes: CoverageHole[];
};

export type SessionMeta = {
  id: string;
  createdAt?: number;
  finishedAt?: number;
  state?: 'scanning' | 'done';
  frameCount?: number;
  hasLiDAR?: boolean;
  coverage?: CoverageStats;
};
