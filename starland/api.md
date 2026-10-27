# FileUpload API

本文件与 `/root/proto/starland/api.md` 的当前协议同步；本轮明确延期的反馈附件
`verify/claim` 在第 6 节说明。

## 1. 通用约定

- API 前缀：`/api/v1`
- 用户接口通过 `Authorization: Bearer <access_token>` 鉴权。
- 上传使用 `multipart/form-data`，文件字段名为 `file`。
- 每个逻辑上传任务使用 UUID v4 `Idempotency-Key`。
- `X-File-Size` 是正整数字节数；服务校验实际大小。
- 只有开发环境可同时配置 `APP_ENV=development` 与 `ALLOW_INSECURE_AUTH=true`。
- 幂等作用域是 `用户 ID + 文件类型 + Idempotency-Key`，状态保存在单实例内存中，默认
  保留 24 小时且重启丢失。

错误响应格式：

```json
{
  "code": "FILE_TOO_LARGE",
  "message": "uploaded file exceeds the allowed size",
  "request_id": "req_..."
}
```

## 2. 日志上传

```http
POST /api/v1/log-files
Authorization: Bearer <access-token>
Content-Type: multipart/form-data
Idempotency-Key: 550e8400-e29b-41d4-a716-446655440000
X-File-Size: 5242880
X-File-SHA256: <可选的64位十六进制SHA-256>
```

接受 `.zip`、`.gz`、`.tar.gz`，对象路径为 `logs/{file_id}`。文件所有者只取自 Access
Token 的可信 `UserId`。首次成功返回 `201 Created`，等价幂等重放返回 `200 OK`。

## 3. 反馈图片上传

```http
POST /api/v1/feedback-files
Authorization: Bearer <access-token>
Content-Type: multipart/form-data
Idempotency-Key: 550e8400-e29b-41d4-a716-446655440000
X-File-Size: 1048576
X-File-SHA256: <必填的64位小写十六进制SHA-256>
```

接受 JPEG、PNG、WebP；单文件最多 10 MiB，最长边最多 2048 像素。服务校验扩展名、
magic bytes、完整解码结果、实际大小与 SHA-256，并拒绝 APNG 和动画 WebP。对象路径为
`feedback-files/{file_id}`，初始元数据状态为 `pending`。

成功响应：

```json
{
  "file_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
  "file_kind": "feedback-image",
  "filename": "feedback.jpg",
  "size": 1048576,
  "sha256": "62b8...",
  "mime_type": "image/jpeg",
  "width": 1280,
  "height": 720,
  "created_at": "2026-10-26T08:00:00Z",
  "request_id": "req_..."
}
```

## 4. 客户端安装包上传

```http
POST /api/v1/app-releases
Authorization: Bearer <access-token>
Content-Type: multipart/form-data
Idempotency-Key: 20dbfe80-a655-4f30-884f-bb51ce465632
X-File-Size: 104857600
X-File-SHA256: <必填的64位十六进制SHA-256>
```

表单字段：

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `platform` | 是 | `android`、`ios`、`windows`、`mac` |
| `package_type` | 是 | `apk`、`ipa`、`exe`、`dmg`、`pkg` |
| `file` | 是 | 安装包文件；字段顺序不限 |

允许组合：

| platform | package_type | 扩展名 |
| --- | --- | --- |
| android | apk | `.apk` |
| ios | ipa | `.ipa` |
| windows | exe | `.exe` |
| mac | dmg / pkg | `.dmg` / `.pkg` |

对象路径为 `app-releases/{platform}/{file_id}`。服务校验组合、扩展名、文件格式特征、
实际大小和 SHA-256。响应额外包含 `platform` 和 `package_type`。当前 Access Token 没有
管理员角色，发布权限仍由 Admin 服务控制。

## 5. 文件下载

```http
GET /api/v1/log-files/{file_id}
GET /api/v1/feedback-files/{file_id}
GET /api/v1/app-releases/{file_id}
```

- 日志要求有效 Access Token，且 `token.UserId == owner_uid`；不存在和无权访问均返回
  `404 FILE_NOT_FOUND`。
- 反馈图片当前按 `file_id` 公开读取，不要求 Access Token。`file_id` 使用不可预测的 UUID，获得完整
  URL 即可读取图片；该 URL 可由 Admin 反馈详情接口返回。当前版本不使用签名或过期时间，后续可在
  不改变响应字段的情况下升级为短期签名 URL。
- 安装包下载公开，不依赖 Access Token。
- 支持完整下载和单段 `Range: bytes=start-end`；成功分别返回 200 或 206，无效 Range
  返回 416。
- MinIO Bucket 保持私有，客户端只通过文件服务读取。

## 6. 内部反馈图片接口

内部服务监听独立的回环地址 `INTERNAL_HTTP_ADDR`，不通过公网 OpenResty。当前阶段按约定
暂不校验服务凭据，Admin 读取图片：

```http
GET /internal/feedback-files/{file_id}
```

返回文件流并支持单段 Range。`POST /internal/feedback-files/verify` 与
`POST /internal/feedback-files/claim` 按当前迭代要求暂不实现；在 claim 生命周期实现前，
pending 文件自动清理也不启用。

## 7. 通用错误

| HTTP | code | 场景 |
| ---: | --- | --- |
| 400 | `INVALID_REQUEST` | 请求头、表单、平台组合或幂等键无效 |
| 400 | `CHECKSUM_REQUIRED` | 反馈图片或安装包未提供 SHA-256 |
| 401 | `AUTH_TOKEN_MISSING/INVALID/EXPIRED` | 用户 Token 鉴权失败 |
| 404 | `FILE_NOT_FOUND` | 文件不存在或用户不是所有者 |
| 409 | `IDEMPOTENCY_CONFLICT` | 幂等键对应不同请求 |
| 409 | `UPLOAD_IN_PROGRESS` | 相同幂等请求正在处理 |
| 413 | `FILE_TOO_LARGE` | 超过资源大小限制 |
| 415 | `UNSUPPORTED_FILE_TYPE` | 文件类型、格式或图片约束不符合要求 |
| 416 | `INVALID_RANGE` | Range 无效 |
| 422 | `FILE_SIZE_MISMATCH` | 实际大小不符 |
| 422 | `CHECKSUM_MISMATCH` | SHA-256 不符 |
| 503 | `STORAGE_UNAVAILABLE` | MinIO 不可用 |

## 8. 健康检查

```http
GET /health/live
GET /health/ready
```

`ready` 检查 MinIO Bucket 可用性。
