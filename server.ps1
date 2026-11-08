# server.ps1
param(
    [string]$App = "",         # 直接起動するアプリのID (例: "filemanager")
    [switch]$Standalone,       # 単体起動モード（「ポータルへ戻る」を非表示）
    [switch]$AppWindow         # Edgeのデスクトップアプリ風ウィンドウで開く
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptDir "config.json"
$config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json

if (-not (Test-Path -LiteralPath $config.nasRootPath)) {
    New-Item -ItemType Directory -Path $config.nasRootPath -Force | Out-Null
}

$port = $config.port
$prefix = "http://localhost:$port/"
$wwwroot = Join-Path $scriptDir "wwwroot"

# 起動時に開くターゲットURLの決定
$targetUrl = $prefix
if (-not [string]::IsNullOrWhiteSpace($App)) {
    $matchedApp = $config.apps | Where-Object { $_.id -eq $App } | Select-Object -First 1
    if ($matchedApp) {
        $relAppPath = $matchedApp.path.TrimStart('/')
        $targetUrl = "$prefix$relAppPath"
    } else {
        $targetUrl = "${prefix}apps/$App/"
    }
    if ($Standalone) {
        $targetUrl += "?standalone=1"
    }
}

function Open-AppBrowser([string]$url) {
    if ($AppWindow) {
        Start-Process "msedge.exe" -ArgumentList "--app=`"$url`" --window-size=1150,780"
    } else {
        Start-Process $url
    }
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)

try {
    $listener.Start()
} catch {
    Open-AppBrowser $targetUrl
    exit
}

Open-AppBrowser $targetUrl

function Send-JsonResponse($response, $data, $statusCode = 200) {
    $response.StatusCode = $statusCode
    $response.ContentType = "application/json; charset=utf-8"
    $json = $data | ConvertTo-Json -Depth 10 -Compress
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    $response.ContentLength64 = $buffer.Length
    $response.OutputStream.Write($buffer, 0, $buffer.Length)
    $response.Close()
}

# --- クライアント死活監視用の状態変数 ---
$script:hasConnected = $false
$script:lastHeartbeat = [DateTime]::Now
$script:closeRequestedAt = $null

try {
    # GetContextAsync() で非同期にリクエストを待ち受ける
    $contextTask = $listener.GetContextAsync()

    while ($listener.IsListening) {
        # 500ミリ秒待機し、リクエストが来ていなければ死活チェックを行う
        if (-not $contextTask.Wait(500)) {
            if ($script:hasConnected) {
                $now = [DateTime]::Now

                # 判定1: 画面から「×」で閉じた通知(client-closed)があり、3秒間次の画面遷移や再接続がない場合
                if ($null -ne $script:closeRequestedAt -and ($now - $script:closeRequestedAt).TotalSeconds -ge 3.0) {
                    break
                }

                # 判定2: ハートビート通信が15秒以上完全に途絶えた場合（強制終了対策）
                if (($now - $script:lastHeartbeat).TotalSeconds -ge 15.0) {
                    break
                }
            }
            continue
        }

        $context = $contextTask.Result
        # 次のリクエストを非同期で待機開始
        $contextTask = $listener.GetContextAsync()

        $request = $context.Request
        $response = $context.Response
        $urlPath = $request.Url.AbsolutePath

        try {
            # A. ハートビート受信（生存時間の更新＆終了予約のキャンセル）
            if ($urlPath -eq "/api/system/heartbeat") {
                $script:hasConnected = $true
                $script:lastHeartbeat = [DateTime]::Now
                $script:closeRequestedAt = $null
                $response.StatusCode = 204
                $response.Close()
                continue
            }

            # B. ウィンドウ閉鎖シグナル受信（3秒後の終了タイマーをセット）
            if ($urlPath -eq "/api/system/client-closed") {
                $script:closeRequestedAt = [DateTime]::Now
                $response.StatusCode = 204
                $response.Close()
                continue
            }

            # C. 明示的な即時シャットダウンAPI
            if ($urlPath -eq "/api/system/shutdown") {
                Send-JsonResponse $response @{ status = "shutting_down" }
                break
            }

            # 通常のアクセスがあった場合も生存状態を更新する
            $script:hasConnected = $true
            $script:lastHeartbeat = [DateTime]::Now
            $script:closeRequestedAt = $null

            # ポータル用設定取得API
            if ($urlPath -eq "/api/portal/apps") {
                Send-JsonResponse $response @{ apps = $config.apps }
                continue
            }

            # 個別アプリのAPIルーティング (/api/{appId}/{action})
            if ($urlPath -match "^/api/([^/]+)/(.+)$") {
                $appId = $matches[1]
                $action = $matches[2]
                $apiScript = Join-Path $wwwroot "apps\$appId\api.ps1"
                if (Test-Path -LiteralPath $apiScript) {
                    & $apiScript -Context $context -Action $action -Config $config
                } else {
                    Send-JsonResponse $response @{ error = "API module not found" } 404
                }
                continue
            }

            # 静的ファイル配信
            $localPath = $urlPath.TrimStart('/').Replace('/', '\')
            if ([string]::IsNullOrEmpty($localPath)) { $localPath = "index.html" }
            $fullPath = Join-Path $wwwroot $localPath

            if (Test-Path -LiteralPath $fullPath -PathType Container) {
                $fullPath = Join-Path $fullPath "index.html"
            }

            if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
                $ext = [System.IO.Path]::GetExtension($fullPath).ToLower()
                $mime = switch ($ext) {
                    ".html" { "text/html; charset=utf-8" }
                    ".css"  { "text/css; charset=utf-8" }
                    ".js"   { "application/javascript; charset=utf-8" }
                    ".json" { "application/json; charset=utf-8" }
                    ".svg"  { "image/svg+xml" }
                    default { "application/octet-stream" }
                }
                $response.ContentType = $mime
                $bytes = [System.IO.File]::ReadAllBytes($fullPath)
                $response.ContentLength64 = $bytes.Length
                $response.OutputStream.Write($bytes, 0, $bytes.Length) # <- 下の行で正確な長さを出力
                $response.Close()
            } else {
                $response.StatusCode = 404
                $response.Close()
            }
        } catch {
            try { Send-JsonResponse $response @{ error = $_.Exception.Message } 500 } catch {}
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}