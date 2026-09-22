# FileUpload API

## 1. 通用约定

- API 前缀：`/api/v1`
- 文件保存在私有 MinIO Bucket 中，调用方不直接接触 MinIO 凭据。
- 日志和客户端安装包是两类独立资源，使用不同接口、权限和对象前缀。
- App 为每个逻辑上传任务生成并持久化 UUID v4 `Idempotency-Key`。
- 用户上传接口必须校验 access token，验签与权限边界详见 `token.md`。
- 只有本地开发环境可同时设置 `APP_ENV=development` 和 `ALLOW_INSECURE_AUTH=true` 绕过鉴权。

错误响应：

```json
{
  "code": "FILE_TOO_LARGE",
  "message": "uploaded file exceeds the allowed size",
  "request_id": "req_01K5..."
}
```

## 2. 幂等约定

当前幂等作用域是 `文件类型 + Idempotency-Key`，因此同一个 UUID 可分别用于日志和
安装包上传。接入 JWT 后扩展为 `用户 ID + 文件类型 + Idempotency-Key`。

- 相同作用域、相同文件参数、已经完成：返回原来的 `file_id` 和 `200 OK`。
- 相同作用域正在处理：返回 `409 UPLOAD_IN_PROGRESS`。
- 相同作用域对应不同文件参数：返回 `409 IDEMPOTENCY_CONFLICT`。
- 上传失败：释放幂等键，调用方可以使用原键重新上传完整文件。
- 内存记录默认保留24小时，不跨进程、不支持多实例。

## 3. C 端日志上传

```http
POST /api/v1/log-files
Content-Type: multipart/form-data
Idempotency-Key: 550e8400-e29b-41d4-a716-446655440000
X-File-Size: 5242880
X-File-SHA256: <可选>
```

表单字段：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `file` | binary | 是 | `.zip`、`.gz` 或 `.tar.gz` |

对象路径：

```text
logs/{file_id}
```

首次上传成功返回 `201 Created`：

```http
Location: /api/v1/log-files/3fa85f64-5717-4562-b3fc-2c963f66afa6
```

```json
{
  "file_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
  "file_kind": "log",
  "filename": "logs.zip",
  "size": 5242880,
  "sha256": "62b8...",
  "created_at": "2026-09-19T16:30:00Z",
  "request_id": "req_01K5..."
}
```

当前要求有效 access token，文件所有者取自 token 的可信 uid。

## 4. 客户端安装包上传

```http
POST /api/v1/app-releases
Content-Type: multipart/form-data
Idempotency-Key: 20dbfe80-a655-4f30-884f-bb51ce465632
X-File-Size: 104857600
X-File-SHA256: <必填的64位十六进制SHA-256>
```

表单字段：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `file` | binary | 是 | 客户端安装包 |
| `platform` | string | 是 | `android`、`ios`、`windows` 或 `mac` |
| `package_type` | string | 是 | `apk`、`ipa`、`exe`、`dmg` 或 `pkg` |

平台与包类型必须符合下表：

| platform | package_type | 文件扩展名 |
| --- | --- | --- |
| `android` | `apk` | `.apk` |
| `ios` | `ipa` | `.ipa` |
| `windows` | `exe` | `.exe` |
| `mac` | `dmg` 或 `pkg` | `.dmg` 或 `.pkg` |

对象路径：

```text
app-releases/{platform}/{file_id}
```

服务检查平台与包类型组合、扩展名、对应文件格式特征、实际大小和 SHA-256。首次上传返回：

```json
{
  "file_id": "ec23b015-f836-4b3b-bc9a-66451935c7a1",
  "file_kind": "app-release",
  "platform": "android",
  "package_type": "apk",
  "filename": "app-release.apk",
  "size": 104857600,
  "sha256": "9a31...",
  "created_at": "2026-09-19T16:30:00Z",
  "request_id": "req_01K5..."
}
```

当前阶段要求有效 access token。版本号、构建号和发布说明由 Admin 服务保存，文件服务
只返回 `file_id` 和技术元信息。只有 Admin 服务中指定的发布账号能把已上传文件发布为生效版本。

## 5. 文件下载

```http
GET  /api/v1/log-files/{file_id}

GET  /api/v1/app-releases/{file_id}
```

`GET` 支持完整下载和单段 Range：

```http
Range: bytes=0-1048575
```

- 完整下载：`200 OK`
- 合法 Range：`206 Partial Content`
- 文件不存在：`404 Not Found`
- Range 不合法：`416 Range Not Satisfiable`

日志的 `GET` 要求有效 access token，并且只能访问本人上传的文件。安装包的 `GET` 是公开
接口，便于未登录或 token 已过期的客户端完成升级。Feedback 和 Admin 都直接接收前端提交
的上传结果元信息，不回查文件服务；其中 Feedback 将日志元信息按客户端未验证数据保存。
MinIO Bucket 始终保持私有，文件只能经过文件服务下载。

## 6. 通用错误

| HTTP 状态 | 错误码 | 场景 |
| --- | --- | --- |
| `400` | `INVALID_REQUEST` | 请求头、表单或幂等键不合法 |
| `400` | `CHECKSUM_REQUIRED` | 安装包未提供 SHA-256 |
| `409` | `IDEMPOTENCY_CONFLICT` | 幂等键对应不同文件 |
| `409` | `UPLOAD_IN_PROGRESS` | 相同幂等请求正在处理 |
| `413` | `FILE_TOO_LARGE` | 超过对应资源的大小限制 |
| `415` | `UNSUPPORTED_FILE_TYPE` | 文件扩展名或 magic bytes 不匹配 |
| `422` | `FILE_SIZE_MISMATCH` | 实际大小与声明大小不一致 |
| `422` | `CHECKSUM_MISMATCH` | 实际 SHA-256 不一致 |
| `503` | `STORAGE_UNAVAILABLE` | MinIO 不可用 |

## 7. 健康检查

```http
GET /health/live
GET /health/ready
```

`ready` 会检查 MinIO Bucket 是否可用。
