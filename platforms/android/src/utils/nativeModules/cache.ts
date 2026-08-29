import { NativeModules } from 'react-native'

const CacheModule = NativeModules.CacheModule ?? {
  getAppCacheSize: async() => 0,
  clearAppCache: async() => {},
}

export const getAppCacheSize = async(): Promise<number> => CacheModule.getAppCacheSize().then((size: number) => Math.trunc(size))
export const clearAppCache = CacheModule.clearAppCache as () => Promise<void>
