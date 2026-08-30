import { memo, useCallback, useMemo, useRef, useState } from 'react'

import { ScrollView, View } from 'react-native'

import SubTitle from '../../components/SubTitle'
import CheckBox from '@/components/common/CheckBox'
import { createStyle } from '@/utils/tools'
import { setApiSource } from '@/core/apiSource'
import { checkUserApi } from '@/core/userApi'
import { useI18n } from '@/lang'
import apiSourceInfo from '@/utils/musicSdk/api-source-info'
import { useSettingValue } from '@/store/setting/hook'
import { useStatus, useUserApiList } from '@/store/userApi'
import Button from '../../components/Button'
import UserApiEditModal, { type UserApiEditModalType } from './UserApiEditModal'
import Text from '@/components/common/Text'
import { useTheme } from '@/store/theme/hook'
import { MUSIC_PLATFORMS } from '@/config/platforms'

const apiSourceList = apiSourceInfo.map(api => ({
  id: api.id,
  name: api.name,
  disabled: api.disabled,
}))

const useActive = (id: string) => {
  const activeLangId = useSettingValue('common.apiSource')
  const isActive = useMemo(() => activeLangId == id, [activeLangId, id])
  return isActive
}

const Item = ({ id, name, desc, statusLabel, change }: {
  id: string
  name: string
  desc?: string
  statusLabel?: string
  change: (id: string) => void
}) => {
  const isActive = useActive(id)
  const theme = useTheme()
  // const [toggleCheckBox, setToggleCheckBox] = useState(false)
  return (
    <CheckBox marginBottom={5} check={isActive} onChange={() => { change(id) }} need>
      <Text style={styles.sourceLabel}>
        {name}
        {
          desc ? <Text style={styles.sourceDesc} color={theme['c-500']} size={13}>  {desc}</Text> : null
        }
        {
          statusLabel ? <Text style={styles.sourceStatus} size={13}>  {statusLabel}</Text> : null
        }
      </Text>
    </CheckBox>
  )
}

export default memo(() => {
  const t = useI18n()
  const theme = useTheme()
  const [checking, setChecking] = useState(false)
  const [checkSourceId, setCheckSourceId] = useState<string | null>(null)
  const [checkMessage, setCheckMessage] = useState<string | null>(null)
  const [checkSucceeded, setCheckSucceeded] = useState(false)
  const list = useMemo(() => apiSourceList.map(s => ({
    // @ts-expect-error
    name: t(`setting_basic_source_${s.id}`) || s.name,
    id: s.id,
  })), [t])
  const setApiSourceId = useCallback((id: string) => {
    setCheckSourceId(null)
    setCheckMessage(null)
    setApiSource(id)
  }, [])
  const userApiListRaw = useUserApiList()
  const apiStatus = useStatus()
  const apiSourceSetting = useSettingValue('common.apiSource')
  const userApiList = useMemo(() => {
    const getApiStatus = () => {
      let status
      if (apiStatus.status) status = t('setting_basic_source_status_success')
      else if (apiStatus.message == 'initing') status = t('setting_basic_source_status_initing')
      else status = t('setting_basic_source_status_failed')

      return status
    }
    return userApiListRaw.map(api => {
      const statusLabel = api.id == apiSourceSetting ? `[${getApiStatus()}]` : ''
      return {
        id: api.id,
        name: api.name,
        label: `${api.name}${statusLabel}`,
        desc: [/^\d/.test(api.version) ? `v${api.version}` : api.version].filter(Boolean).join(', '),
        statusLabel,
        // status: apiStatus.status,
        // message: apiStatus.message,
        // disabled: false,
      }
    })
  }, [userApiListRaw, apiStatus, apiSourceSetting, t])

  const activeSourceName = userApiListRaw.find(api => api.id == apiSourceSetting)?.name

  const modalRef = useRef<UserApiEditModalType>(null)
  const handleShow = () => {
    modalRef.current?.show()
  }

  const handleCheck = useCallback(async() => {
    setChecking(true)
    setCheckSourceId(apiSourceSetting)
    setCheckMessage(null)
    try {
      const result = await checkUserApi()
      setCheckSucceeded(true)
      setCheckMessage(`音源可用：${result.source} / ${result.quality}`)
    } catch (error: any) {
      setCheckSucceeded(false)
      setCheckMessage(`音源不可用：${error?.message ?? '请求失败'}`)
    } finally {
      setChecking(false)
    }
  }, [apiSourceSetting])

  return (
    <SubTitle title={t('setting_basic_source')}>
      <Text style={styles.tipText} color={theme['c-font-label']} size={12}>
        {t('setting_basic_source_user_only_tip')}
      </Text>
      <Text style={styles.sectionLabel} size={13}>{t('setting_basic_platform_catalog')}</Text>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.platformScroll} contentContainerStyle={styles.platformList}>
        {MUSIC_PLATFORMS.map(platform => (
          <View key={platform.id} style={{ ...styles.platformChip, borderColor: platform.color }}>
            <View style={{ ...styles.platformDot, backgroundColor: platform.color }} />
            <Text size={12}>{platform.name}</Text>
          </View>
        ))}
      </ScrollView>
      <Text style={styles.sectionLabel} size={13}>{t('setting_basic_source_resolver')}</Text>
      <Text style={styles.activeSource} color={activeSourceName ? theme['c-primary-font-active'] : theme['c-font-label']} size={12}>
        {activeSourceName ?? t('setting_basic_source_none')}
      </Text>
      <View style={styles.checkRow}>
        <Button disabled={checking || !/^user_api/.test(apiSourceSetting)} onPress={handleCheck}>
          {checking ? '检测中…' : '测试当前音源'}
        </Button>
        {checkSourceId == apiSourceSetting && checkMessage ? (
          <Text style={styles.checkMessage} color={checkSucceeded ? theme['c-primary-font-active'] : theme['c-500']} size={12}>
            {checkMessage}
          </Text>
        ) : null}
      </View>
      <Text style={styles.tipText} color={theme['c-font-label']} size={12}>
        测试会使用一首公开歌曲请求音源的 musicUrl 接口，只检查是否能返回播放地址，不会下载歌曲。
      </Text>
      <View style={styles.list}>
        {
          list.map(({ id, name }) => <Item name={name} id={id} key={id} change={setApiSourceId} />)
        }
        {
          userApiList.map(({ id, name, desc, statusLabel }) => <Item name={name} desc={desc} statusLabel={statusLabel} id={id} key={id} change={setApiSourceId} />)
        }
      </View>
      <View style={styles.btn}>
        <Button onPress={handleShow}>{t('setting_basic_source_user_api_btn')}</Button>
      </View>
      <UserApiEditModal ref={modalRef} />
    </SubTitle>
  )
})

const styles = createStyle({
  list: {
    flexGrow: 0,
    flexShrink: 1,
    // flexDirection: 'row',
    // flexWrap: 'wrap',
  },
  btn: {
    marginTop: 10,
    flexDirection: 'row',
  },
  checkRow: {
    marginTop: 4,
    flexDirection: 'row',
    alignItems: 'center',
    flexWrap: 'wrap',
  },
  checkMessage: {
    flexShrink: 1,
    marginTop: 5,
    marginBottom: 5,
  },
  sourceLabel: {

  },
  sourceDesc: {

  },
  sourceStatus: {

  },
  tipText: {
    marginBottom: 10,
  },
  sectionLabel: {
    marginTop: 8,
    marginBottom: 6,
    fontWeight: '600',
  },
  activeSource: {
    marginBottom: 6,
  },
  platformScroll: {
    flexGrow: 0,
  },
  platformList: {
    paddingBottom: 4,
  },
  platformChip: {
    flexDirection: 'row',
    alignItems: 'center',
    borderWidth: 1,
    borderRadius: 99,
    paddingHorizontal: 8,
    paddingVertical: 5,
    marginRight: 6,
  },
  platformDot: {
    width: 6,
    height: 6,
    borderRadius: 3,
    marginRight: 5,
  },
})
