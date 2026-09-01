# Moumusic Sponsor Website

这是 Moumusic 的轻量个人赞助主页，包含：

- `/aifadian`：Liquid Glass 风格的爱发电赞助页
- `/install`：iOS 与 Android 安装说明
- `/api/aifadian/sponsors`：脱敏后的赞助者名单
- `/api/aifadian/orders`：脱敏后的最近订单
- `/api/aifadian/stats`：支持者数量、最近支持时间和可选金额统计
- `/health`：服务健康检查

## 本地运行

需要 Node.js 20+，不需要安装任何第三方依赖：

```sh
cd website
copy .env.example .env
node --env-file=.env src/server.mjs
```

然后打开 <http://localhost:8787/aifadian>。

没有配置 `AFDIAN_USER_ID` 和 `AFDIAN_TOKEN` 时，页面仍然可以打开，顶部爱发电入口也可用；赞助名单会显示友好的错误状态。

## 配置

服务端读取 `.env` 或部署平台的环境变量：

| 变量 | 用途 |
| --- | --- |
| `AFDIAN_USER_ID` | 爱发电开发者 API 的 user_id，仅服务端使用 |
| `AFDIAN_TOKEN` | 爱发电开发者 API Token，仅服务端使用 |
| `AFDIAN_URL` | 公开的爱发电主页地址 |
| `SHOW_SPONSOR_AMOUNT` | `true` 时显示金额，默认关闭 |
| `SITE_NAME` | 页面显示昵称 |
| `SITE_AVATAR` | 头像 URL，可留空使用首字母头像 |
| `SITE_TAGLINE` | Hero 感谢语 |
| `SITE_THANKS` | 页面底部感谢语 |
| `IOS_DOWNLOAD_URL` | 安装页的 iOS 下载地址 |
| `ANDROID_DOWNLOAD_URL` | 安装页的 Android 下载地址 |

`AFDIAN_TOKEN` 永远不会进入 HTML、JavaScript、API 响应或日志。项目也不会托管 P12、mobileprovision、企业证书或密码。

## API 说明

服务端使用爱发电官方 `query-sponsor` 和 `query-order` OpenAPI，按官方规则生成 `md5(token + params + ts + user_id)` 签名，分页获取数据并在返回前只保留页面需要的字段。结果缓存 10 分钟，避免每次刷新都请求上游。

官方文档：[爱发电开发者 API 和 Webhook](https://guide.afdian.com/creator/developer)。

## 测试

```sh
npm test
```
