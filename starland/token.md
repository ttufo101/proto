# Starland Access Token 验签规范

本文供文件上传 REST 服务接入 Starland 登录态时参考。依据当前 Login 的签发实现和 Gateway 的验签实现整理；目标是让文件上传服务与 Gateway 对同一枚 access token 得出相同的用户身份和有效性结论。

## 1. Token 来源与传输

access token 由 Login 服务登录或刷新流程签发。Gateway 当前从业务请求体的 `com.jwt_token` 读取；文件上传服务是独立 REST API，应使用标准 HTTP 头：

```http
Authorization: Bearer <access_token>
```

文件服务应当：

1. 对 `Bearer` 方案名做大小写不敏感匹配。
2. 要求头中只有一枚非空 token。
3. 不接受 query、表单或 Cookie 中的 token。
4. 不在访问日志、错误日志或追踪属性中记录原始 token。
5. Web 客户端跨域上传时，在 CORS 中允许 `Authorization`、`Idempotency-Key`、`X-File-Size` 和 `X-File-SHA256`。

## 2. 当前 JWT 格式

签名算法固定为 `HS256`。当前业务 Claims：

```json
{
  "UserId": "用户ID",
  "token_type": "access",
  "iss": "starland",
  "sub": "用户ID",
  "iat": 1789860000,
  "nbf": 1789860000,
  "exp": 1789863600
}
```

字段语义：

| 字段 | 当前要求 | 说明 |
|---|---|---|
| `alg` | 必须为 `HS256` | 必须使用算法白名单，不能只相信 JWT header |
| `UserId` | 必须存在且去除首尾空白后非空 | 字段大小写必须保持一致；这是当前可信用户 ID |
| `token_type` | 必须等于 `access` | refresh token 和 password_reset token 不得用于上传 |
| `iss` | 必须与配置的 issuer 完全一致 | 当前运行配置为 `starland`，代码不得硬编码 |
| `exp` | Login 签发时一定存在 | 到期后拒绝；Gateway 当前解析器没有显式要求该字段必须出现，见第 7 节 |
| `nbf` | Login 签发时一定存在 | 当前时间早于该值时拒绝 |
| `iat` | Login 签发时一定存在 | 表示签发时间；Gateway 当前不单独限制 token 最大年龄 |
| `sub` | Login 当前写为用户 ID | Gateway 当前不检查它是否等于 `UserId` |
| `jti` | access token 为空 | refresh token 才使用 jti，不能依赖它识别 access token |

access token 默认有效期由 Login 的 `jwt.accessExpires` 控制，当前是 `1h`。验签服务不应自行用固定一小时替代 `exp` 校验。

## 3. 与 Gateway 一致的校验顺序

文件上传服务对用户接口按以下顺序处理：

1. 解析 `Authorization`，缺失或格式错误返回 HTTP 401。
2. 使用配置中的共享密钥验证签名。
3. 只允许 `HS256`。
4. 要求 `iss` 与配置一致。
5. 校验 JWT 库支持的时间 Claims；`exp` 已过期或 `nbf` 尚未生效均返回 HTTP 401。
6. 要求解析后的 token 有效。
7. 要求 `token_type == "access"`。
8. 读取并 trim `UserId`，为空则返回 HTTP 401。
9. 后续业务只使用 token 中的 `UserId`，忽略客户端提交的 uid、owner_uid 等身份字段。

Gateway 当前把 malformed、签名错误和算法错误统一视为无效 token；把 expired 与 not-valid-yet 统一映射为过期错误。文件服务可以使用更准确的内部错误码，但对外都应返回 401，且不能暴露签名或密钥细节。

建议 REST 错误响应：

```json
{
  "code": "AUTH_TOKEN_INVALID",
  "message": "access token is invalid",
  "request_id": "req_..."
}
```

推荐错误码：

| 场景 | HTTP | code |
|---|---:|---|
| Authorization 缺失 | 401 | `AUTH_TOKEN_MISSING` |
| Bearer 格式、签名、算法、issuer 或 Claims 无效 | 401 | `AUTH_TOKEN_INVALID` |
| 已过期或尚未生效 | 401 | `AUTH_TOKEN_EXPIRED` |
| token 类型不是 access | 401 | `AUTH_TOKEN_INVALID` |
| `UserId` 为空 | 401 | `AUTH_TOKEN_INVALID` |

响应建议携带：

```http
WWW-Authenticate: Bearer
```

## 4. Go 参考实现

当前 Gateway 和 Login 使用：

```text
github.com/golang-jwt/jwt/v5 v5.3.1
```

核心验签逻辑可按以下方式实现：

```go
type accessClaims struct {
    UserID    string `json:"UserId"`
    TokenType string `json:"token_type"`
    jwt.RegisteredClaims
}

func verifyAccessToken(rawToken, issuer string, key []byte) (string, error) {
    if strings.TrimSpace(rawToken) == "" {
        return "", errTokenMissing
    }
    if len(key) == 0 || strings.TrimSpace(issuer) == "" {
        return "", errAuthConfig
    }

    claims := &accessClaims{}
    token, err := jwt.ParseWithClaims(
        rawToken,
        claims,
        func(*jwt.Token) (any, error) { return key, nil },
        jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}),
        jwt.WithIssuer(issuer),
    )
    if err != nil {
        if errors.Is(err, jwt.ErrTokenExpired) ||
            errors.Is(err, jwt.ErrTokenNotValidYet) {
            return "", errTokenExpired
        }
        return "", errTokenInvalid
    }
    if token == nil || !token.Valid || claims.TokenType != "access" {
        return "", errTokenInvalid
    }
    uid := strings.TrimSpace(claims.UserID)
    if uid == "" {
        return "", errTokenInvalid
    }
    return uid, nil
}
```

密钥必须从运行时 Secret 或受权限保护的配置加载。不要把当前生产密钥复制到源码、镜像、本文档或示例配置。Login、Gateway 与文件上传服务的 `key` 和 `issuer` 必须同时更新，否则会立即出现登录成功但上传返回 401 的情况。

## 5. 文件服务如何使用 uid

### 上传文件

`POST /api/v1/log-files` 或 `POST /api/v1/app-releases` 验签成功后，文件服务应把可信 uid 与服务端计算出的文件属性一起保存：

- `owner_uid`
- `file_id`
- 原始文件名
- 实际大小
- 服务端 SHA-256
- Content-Type
- 创建时间

这些信息可以放在文件服务数据库或 MinIO 对象 metadata 中。客户端提交的 uid 不能覆盖 `owner_uid`。

### 用户下载

普通用户调用 `GET /api/v1/log-files/{file_id}` 时，文件服务应要求：

```text
token.UserId == file.owner_uid
```

文件不存在和无权访问建议都返回 404，减少文件枚举信息泄露。

### Feedback 检查文件

Feedback 调用 `HEAD /api/v1/log-files/{file_id}` 是服务间请求。Gateway 不会把请求体中的 `com.jwt_token` 转发给 Feedback，Feedback 也不应保存用户原始 token，因此 HEAD 不能依赖用户 access token。

应为 Feedback 配置独立服务凭据，并要求 `files:read-metadata` 权限。HEAD 在鉴权成功后返回：

```http
Content-Length: 5242880
Content-Type: application/zip
X-File-SHA256: 62b8...
X-Original-Filename: logs-20260919.zip
X-Owner-Uid: 用户ID
```

Feedback 使用 `X-Owner-Uid` 与 Gateway 传入的可信 `xmd-uid` 比较，从而阻止跨用户绑定 `file_id`。

### 安装包上传与发布

当前 access token 不包含 `role` 或 `scope`，所以文件服务只校验登录态并记录安装包的
`owner_uid`，不在上传阶段判断管理员角色。Admin 发布接口从账号表校验管理员角色，并且
当前只允许 `ygliu_csdn@163.com` 发布。管理员前端把上传接口返回的 file_id、文件名、大小、
SHA-256、平台和包类型提交给 Admin；Admin 不再回查文件服务。安装包 GET 是公开下载接口，
不依赖 access token。

跨用户日志下载仍然不能因为请求来自管理页面、携带任意 uid 或知道 file_id 就直接放行。

## 6. 必测场景

- 合法 access token 上传成功，并把 token 的 `UserId` 保存为 owner。
- Authorization 缺失、空 Bearer、多个 token 均返回 401。
- HS384、RS256、`alg=none` 均被拒绝。
- 使用错误密钥签名、issuer 不一致、token 被篡改均被拒绝。
- access token 过期、尚未生效均被拒绝。
- refresh token 和 password_reset token 均被拒绝。
- `UserId` 缺失或只有空白字符被拒绝。
- 客户端伪造 uid 不影响最终 owner。
- 普通用户不能下载或绑定其他用户的日志文件。
- Feedback 服务凭据不能调用普通用户上传接口。
- token 不出现在日志、指标标签和错误响应中。

## 7. 建议同步加固

当前 Login 签发的 access token 总是包含 `exp`，但 Gateway 使用的 `jwt.ParseWithClaims` 没有启用 `jwt.WithExpirationRequired()`。这意味着一枚签名正确、issuer 正确、类型正确但完全没有 `exp` 的自制 token，可能通过当前 Gateway 验证。

建议后续同时修改 Gateway 与文件服务，增加：

```go
jwt.WithExpirationRequired()
```

如需容忍机器时钟误差，可在所有验签服务统一设置很小的 leeway，例如 30 秒；不要只在某一个服务中设置。该加固会改变当前验签行为，应在 Gateway、文件服务和测试中同时上线。
