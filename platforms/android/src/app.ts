import '@/utils/errorHandle'
import { init as initLog } from '@/utils/log'
import { bootLog, getBootLog } from '@/utils/bootLog'
import '@/config/globalData'
import { getFontSize } from '@/utils/data'
import { exitApp } from './utils/nativeModules/utils'
import { windowSizeTools } from './utils/windowSizeTools'
import { listenLaunchEvent } from './navigation/regLaunchedEvent'
import { tipDialog } from './utils/tools'

console.log('starting app...')
listenLaunchEvent()

const INIT_TIMEOUT = 45_000

const waitForInit = async<T>(promise: Promise<T>): Promise<T> => new Promise<T>((resolve, reject) => {
  const timer = setTimeout(() => {
    reject(new Error(`Initialization timed out after ${INIT_TIMEOUT / 1000}s`))
  }, INIT_TIMEOUT)
  void promise.then(resolve, reject).finally(() => {
    clearTimeout(timer)
  })
})

void Promise.all([getFontSize(), windowSizeTools.init()]).then(async([fontSize]) => {
  global.lx.fontSize = fontSize
  bootLog('Font size setting loaded.')

  let isInited = false
  let handlePushedHomeScreen: () => void | Promise<void>

  const tryGetBootLog = () => {
    try {
      return getBootLog()
    } catch (err) {
      return 'Get boot log failed.'
    }
  }

  const handleInit = async() => {
    if (isInited) return
    void initLog()
    try {
      const { default: init } = await import('@/core/init')
      handlePushedHomeScreen = await waitForInit(init())
    } catch (err: any) {
      void tipDialog({
        title: '初始化失败 (Init Failed)',
        message: `Boot Log:\n${tryGetBootLog()}\n\n${(err.stack ?? err.message) as string}`,
        btnText: 'Exit',
        bgClose: false,
      }).then(() => {
        exitApp()
      })
      return
    }
    isInited ||= true
  }
  const { init: initNavigation, navigations } = await import('@/navigation')

  initNavigation(async() => {
    try {
      await navigations.pushBootScreen()
      await handleInit()
      if (!isInited) return
      // import('@/utils/nativeModules/cryptoTest')

      await navigations.pushHomeScreen().then(() => {
        void handlePushedHomeScreen()
      })
    } catch (err: any) {
      void tipDialog({
        title: 'Error',
        message: err.stack ?? err.message,
        btnText: 'Exit',
        bgClose: false,
      }).then(() => {
        exitApp()
      })
    }
  })
}).catch((err) => {
  void tipDialog({
    title: '初始化失败 (Init Failed)',
    message: `Boot Log:\n\n${(err.stack ?? err.message) as string}`,
    btnText: 'Exit',
    bgClose: false,
  }).then(() => {
    exitApp()
  })
})
