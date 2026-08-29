import { useEffect } from 'react'
import PageContent from '@/components/PageContent'
import { setComponentId } from '@/core/common'
import { COMPONENT_IDS } from '@/config/constant'
import { navigations } from '@/navigation'
import settingState from '@/store/setting/state'
import Kumone from './Kumone'


interface Props {
  componentId: string
}


export default ({ componentId }: Props) => {
  useEffect(() => {
    setComponentId(COMPONENT_IDS.home, componentId)
    // eslint-disable-next-line react-hooks/exhaustive-deps

    if (settingState.setting['player.startupPushPlayDetailScreen']) {
      navigations.pushPlayDetailScreen(componentId, true)
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return (
    <PageContent>
      <Kumone />
    </PageContent>
  )
}
