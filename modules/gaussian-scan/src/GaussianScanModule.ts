import { NativeModule, requireNativeModule } from 'expo';

import type { SessionMeta } from './GaussianScan.types';

declare class GaussianScanModule extends NativeModule {
  hasLiDAR(): boolean;
  listSessions(): Promise<SessionMeta[]>;
  deleteSession(id: string): Promise<void>;
  exportZip(id: string): Promise<string>;
}

export default requireNativeModule<GaussianScanModule>('GaussianScan');
