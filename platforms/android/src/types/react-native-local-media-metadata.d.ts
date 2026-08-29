declare module 'react-native-local-media-metadata' {
  export interface MusicMetadata {
    albumName: string
    singer: string
    name: string
  }

  export interface MusicMetadataFull extends MusicMetadata {
    type: 'mp3' | 'flac' | 'ogg' | 'wav'
    bitrate: string
    interval: number
    size: number
    ext: 'mp3' | 'flac' | 'ogg' | 'wav'
  }

  export function readMetadata(filePath: string): Promise<MusicMetadataFull | null>
  export function writeMetadata(filePath: string, metadata: MusicMetadata, isOverwrite?: boolean): Promise<void>
  export function readPic(filePath: string, picDir: string): Promise<string>
  export function writePic(filePath: string, picPath: string): Promise<void>
  export function readLyric(filePath: string, isReadLrcFile?: boolean): Promise<string>
  export function writeLyric(filePath: string, lyric: string): Promise<void>
}
