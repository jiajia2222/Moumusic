import RNFS from 'react-native-fs'
import { fromByteArray, toByteArray } from 'react-native-quick-base64'
import { gzip, ungzip } from 'pako'

export type Encoding = 'base64' | 'utf8'
export type HashAlgorithm = 'md5' | 'sha1' | 'sha224' | 'sha256' | 'sha384' | 'sha512'

export interface FileType {
  name: string
  path: string
  isDirectory: boolean
  isFile: boolean
  lastModified: number
  canRead: boolean
  data: string
  mimeType: string
  size: number
}

export interface OpenDocumentOptions {
  mimeTypes?: string[]
  extTypes?: string[]
  multi?: boolean
  toPath?: string
  encoding?: Encoding
}

interface ReadDirItem {
  name: string
  path: string
  size: number
  mtime?: Date
  isFile: () => boolean
  isDirectory: () => boolean
}

interface StatItem {
  name?: string
  path: string
  size: number
  mtime: number
  isFile: () => boolean
  isDirectory: () => boolean
}

const getName = (path: string, name?: string) => name ?? path.substring(path.lastIndexOf('/') + 1)

const toFileType = (item: ReadDirItem | StatItem): FileType => ({
  name: getName(item.path, item.name),
  path: item.path,
  isDirectory: item.isDirectory(),
  isFile: item.isFile(),
  lastModified: item.mtime instanceof Date ? item.mtime.getTime() : item.mtime ?? 0,
  canRead: true,
  data: '',
  mimeType: '',
  size: item.size,
})

// iOS has no public equivalent of Android's external storage/document-tree URI.
// Keep the app's file features inside its sandbox instead of importing the
// Android-only react-native-file-system package on iOS.
export const extname = (name: string) => name.lastIndexOf('.') > 0 ? name.substring(name.lastIndexOf('.') + 1) : ''

export const temporaryDirectoryPath = RNFS.CachesDirectoryPath
export const externalStorageDirectoryPath = RNFS.DocumentDirectoryPath
export const privateStorageDirectoryPath = RNFS.DocumentDirectoryPath

export const getExternalStoragePaths = async() => [RNFS.DocumentDirectoryPath]

export const selectManagedFolder = async(_isPersist: boolean = false): Promise<FileType | null> => null
export const selectFile = async(_options: OpenDocumentOptions): Promise<FileType | null> => null
export const removeManagedFolder = async(_path: string) => true
export const getManagedFolders = async() => [] as string[]
export const getPersistedUriList = async() => [] as string[]

export const readDir = async(path: string) => {
  const items = await RNFS.readDir(path) as ReadDirItem[]
  return items.map(toFileType)
}

export const unlink = async(path: string) => {
  await RNFS.unlink(path)
  return true
}

export const mkdir = async(path: string) => {
  await RNFS.mkdir(path)
  return stat(path)
}

export const stat = async(path: string) => toFileType(await RNFS.stat(path) as StatItem)
export const hash = async(path: string, algorithm: HashAlgorithm) => RNFS.hash(path, algorithm)

export const readFile = async(path: string, encoding: Encoding = 'utf8') => RNFS.readFile(path, encoding)

export const moveFile = async(fromPath: string, toPath: string) => {
  await RNFS.moveFile(fromPath, toPath)
  return true
}

export const gzipFile = async(fromPath: string, toPath: string) => {
  const data = toByteArray(await RNFS.readFile(fromPath, 'base64'))
  await RNFS.writeFile(toPath, fromByteArray(gzip(data)), 'base64')
}

export const unGzipFile = async(fromPath: string, toPath: string) => {
  const data = toByteArray(await RNFS.readFile(fromPath, 'base64'))
  await RNFS.writeFile(toPath, fromByteArray(ungzip(data)), 'base64')
}

export const gzipString = async(data: string, encoding: Encoding = 'utf8') => {
  const input = encoding === 'base64' ? toByteArray(data) : data
  return fromByteArray(gzip(input))
}

export const unGzipString = async(data: string, encoding: Encoding = 'utf8') => {
  const bytes = ungzip(toByteArray(data))
  return encoding === 'base64' ? fromByteArray(bytes) : Buffer.from(bytes).toString('utf8')
}

export const existsFile = async(path: string) => RNFS.exists(path)

export const rename = async(path: string, name: string) => {
  const parentPath = path.substring(0, path.lastIndexOf('/'))
  await RNFS.moveFile(path, `${parentPath}/${name}`)
  return true
}

export const writeFile = async(path: string, data: string, encoding: Encoding = 'utf8') => RNFS.writeFile(path, data, encoding)

export const appendFile = async(path: string, data: string, encoding: Encoding = 'utf8') => RNFS.appendFile(path, data, encoding)

export const downloadFile = (url: string, path: string, options: Omit<RNFS.DownloadFileOptions, 'fromUrl' | 'toFile'> = {}) => {
  if (!options.headers) {
    options.headers = {
      'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
    }
  }
  return RNFS.downloadFile({
    fromUrl: url,
    toFile: path,
    ...options,
  })
}

export const stopDownload = (jobId: number) => {
  RNFS.stopDownload(jobId)
}
