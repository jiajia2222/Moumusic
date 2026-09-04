import { useCallback, useRef, forwardRef, useImperativeHandle, useState } from 'react'
// import { StyleSheet } from 'react-native'
import Input, { type InputType, type InputProps } from '@/components/common/Input'
import { useI18n } from '@/lang'

export interface SearchInputProps {
  onChangeText: (text: string) => void
  onSubmit: (text: string) => void
  onBlur: () => void
  onTouchStart: () => void
}

export interface SearchInputType {
  setText: (text: string) => void
  // getText: () => string
  focus: () => void
  blur: () => void
}

export default forwardRef<SearchInputType, SearchInputProps>(({ onChangeText, onSubmit, onBlur, onTouchStart }, ref) => {
  // const theme = useTheme()
  const t = useI18n()
  const [text, setText] = useState('')
  const placeholderProps: Pick<InputProps, 'placeholder'> = { placeholder: t('search_input_placeholder') }
  const textRef = useRef('')
  const inputRef = useRef<InputType>(null)

  useImperativeHandle(ref, () => ({
    // getText() {
    //   return text.trim()
    // },
    setText(text) {
      setText(text)
      textRef.current = text
    },
    focus() {
      inputRef.current?.focus()
    },
    blur() {
      inputRef.current?.blur()
    },
  }))

  const handleChangeText = (text: string) => {
    setText(text)
    textRef.current = text
    onChangeText(text.trim())
  }

  const handleClearText = useCallback(() => {
    setText('')
    textRef.current = ''
    onChangeText('')
    onSubmit('')
  }, [onChangeText, onSubmit])

  const handleSubmit = useCallback<NonNullable<InputProps['onSubmitEditing']>>(({ nativeEvent }) => {
    // Third-party IMEs can send the previous nativeEvent.text while the
    // controlled value already contains the committed composition.
    const query = (textRef.current || nativeEvent.text || '').trim()
    if (query) onSubmit(query)
  }, [onSubmit])

  return (
    <Input
      ref={inputRef}
      value={text}
      {...placeholderProps}
      onChangeText={handleChangeText}
      // style={{ ...styles.input, backgroundColor: theme['c-primary-input-background'] }}
      onBlur={onBlur}
      onSubmitEditing={handleSubmit}
      returnKeyType="search"
      blurOnSubmit
      onClearText={handleClearText}
      onTouchStart={onTouchStart}
      clearBtn
    />
  )
})
