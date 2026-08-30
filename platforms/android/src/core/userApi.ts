import { action, state } from '@/store/userApi'
import { addUserApi, getUserApiScript, removeUserApi as removeUserApiFromStore, setUserApiAllowShowUpdateAlert as setUserApiAllowShowUpdateAlertFromStore } from '@/utils/data'
import { destroy, loadScript } from '@/utils/nativeModules/userApi'
import { log as writeLog } from '@/utils/log'
import playerState from '@/store/player/state'
import musicSdk from '@/utils/musicSdk'
import { toOldMusicInfo } from '@/utils'
import settingState from '@/store/setting/state'


export const setUserApi = async(apiId: string) => {
  global.lx.qualityList = {}
  setUserApiStatus(false, 'initing')

  const target = state.list.find(api => api.id === apiId)
  if (!target) throw new Error('api not found')
  const script = await getUserApiScript(target.id)
  loadScript({ ...target, script })
}

export const destroyUserApi = () => {
  destroy()
}


export const setUserApiStatus: typeof action['setStatus'] = (status, message) => {
  action.setStatus(status, message)
}

export const setUserApiList: typeof action['setUserApiList'] = (list) => {
  action.setUserApiList(list)
}

export const importUserApi = async(script: string) => {
  const info = await addUserApi(script)
  action.addUserApi(info)
}

/**
 * Make a real musicUrl request with the active User API. Initialization alone
 * only proves that the script can be evaluated; this check also verifies that
 * at least one catalogue platform returns a usable playback URL.
 */
export const checkUserApi = async(): Promise<{ source: LX.OnlineSource, quality: LX.Quality }> => {
  if (!/^user_api/.test(settingState.setting['common.apiSource'])) {
    throw new Error('当前不是用户导入的 LX 音源')
  }
  if (!await global.lx.apiInitPromise[0]) throw new Error('音源初始化失败')

  const platformOrder: LX.OnlineSource[] = ['wy', 'kw', 'kg', 'tx', 'mg']
  const failures: string[] = []
  for (const source of platformOrder) {
    const api: any = global.lx.apis[source]
    if (!api?.getMusicUrl) continue

    let musicInfo: LX.Music.MusicInfoOnline | null = null
    const current = playerState.playMusicInfo.musicInfo
    if (current && !('progress' in current) && current.source == source) musicInfo = current
    if (!musicInfo) {
      try {
        const result = await musicSdk[source]?.musicSearch?.search('周杰伦 晴天', 1, 1)
        musicInfo = result?.list?.[0] ?? null
      } catch {
        failures.push(`${source}：无法获取测试歌曲`)
        continue
      }
    }
    if (!musicInfo) {
      failures.push(`${source}：找不到测试歌曲`)
      continue
    }

    const quality = (global.lx.qualityList[source]?.[0] ?? '128k') as LX.Quality
    try {
      const result = await api.getMusicUrl(toOldMusicInfo(musicInfo), quality).promise
      const response = result as { url?: unknown, type?: unknown }
      const url = typeof response.url == 'string' ? response.url : ''
      if (/^https?:\/\//i.test(url)) {
        const actualQuality = typeof response.type == 'string'
          ? response.type as LX.Quality
          : quality
        return { source, quality: actualQuality }
      }
      failures.push(`${source}：没有返回有效播放地址`)
    } catch (error: any) {
      failures.push(`${source}：${error?.message ?? '请求失败'}`)
    }
  }
  throw new Error(failures.length ? failures.join('；') : '音源没有可用的 musicUrl 接口')
}

export const removeUserApi = async(ids: string[]) => {
  const list = await removeUserApiFromStore(ids)
  action.setUserApiList(list)
}

export const setUserApiAllowShowUpdateAlert = async(id: string, enable: boolean) => {
  await setUserApiAllowShowUpdateAlertFromStore(id, enable)
  action.setUserApiAllowShowUpdateAlert(id, enable)
}

export const log = {
  r_info(...params: any[]) {
    // eslint-disable-next-line @typescript-eslint/no-unsafe-argument
    writeLog.info(...params)
  },
  r_warn(...params: any[]) {
    // eslint-disable-next-line @typescript-eslint/no-unsafe-argument
    writeLog.warn(...params)
  },
  r_error(...params: any[]) {
    // eslint-disable-next-line @typescript-eslint/no-unsafe-argument
    writeLog.error(...params)
  },
  log(...params: any[]) {
    // eslint-disable-next-line @typescript-eslint/no-unsafe-argument
    if (global.lx.isEnableUserApiLog) writeLog.info(...params)
  },
  info(...params: any[]) {
    // eslint-disable-next-line @typescript-eslint/no-unsafe-argument
    if (global.lx.isEnableUserApiLog) writeLog.info(...params)
  },
  warn(...params: any[]) {
    // eslint-disable-next-line @typescript-eslint/no-unsafe-argument
    if (global.lx.isEnableUserApiLog) writeLog.warn(...params)
  },
  error(...params: any[]) {
    // eslint-disable-next-line @typescript-eslint/no-unsafe-argument
    if (global.lx.isEnableUserApiLog) writeLog.error(...params)
  },
}
