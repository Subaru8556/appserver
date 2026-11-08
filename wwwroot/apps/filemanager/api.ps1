# wwwroot/apps/filemanager/api.ps1
param($Context, $Action, $Config)

$request = $Context.Request
$response = $Context.Response

# NASルートパスの正規化（末尾の \ を統一して保持）
$nasRoot = [System.IO.Path]::GetFullPath($Config.nasRootPath).TrimEnd('\')

# 【重要】HttpListenerのQueryString文字化けを回避し、UTF-8として正確にデコードする関数
function Get-QueryParam([string]$key) {
    $rawQuery = $request.Url.Query.TrimStart('?')
    if ([string]::IsNullOrEmpty($rawQuery)) { return "" }
    foreach ($pair in $rawQuery.Split('&')) {
        if ([string]::IsNullOrEmpty($pair)) { continue }
        $kv = $pair.Split('=', 2)
        $k = [System.Uri]::UnescapeDataString($kv[0].Replace('+', ' '))
        if ($k -eq $key) {
            if ($kv.Length -eq 2) {
                return [System.Uri]::UnescapeDataString($kv[1].Replace('+', ' '))
            }
            return ""
        }
    }
    return ""
}

# セキュリティ: NASルート外のパス参照（..等）を防止しつつ安全にフルパスを生成する関数
function Resolve-SafeNasPath([string]$relPath) {
    if ([string]::IsNullOrWhiteSpace($relPath)) {
        return $nasRoot
    }
    # スラッシュをバックスラッシュに統一し、先頭・末尾の余分な区切り文字を除去
    $cleanRel = $relPath.Replace('/', '\').Trim('\')
    if ([string]::IsNullOrWhiteSpace($cleanRel)) {
        return $nasRoot
    }

    $combined = Join-Path $nasRoot $cleanRel
    $full = [System.IO.Path]::GetFullPath($combined).TrimEnd('\')

    # ルート自身、または「ルート + \」で始まるパスのみ許可
    $rootPrefix = $nasRoot + "\"
    if ($full -ne $nasRoot -and -not $full.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "不正なパスアクセスが検出されました。"
    }
    return $full
}

# 同名ファイル存在時の連番リネーム生成 ("file (1).txt")
function Get-UniqueFilePath([string]$dirPath, [string]$fileName) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    $ext = [System.IO.Path]::GetExtension($fileName)
    $counter = 1
    $candidate = Join-Path $dirPath $fileName
    while (Test-Path -LiteralPath $candidate) {
        $newName = "{0} ({1}){2}" -f $baseName, $counter, $ext
        $candidate = Join-Path $dirPath $newName
        $counter++
    }
    return $candidate
}

function Read-JsonBody($req) {
    $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
    $body = $reader.ReadToEnd()
    $reader.Close()
    return ($body | ConvertFrom-Json)
}

switch ($Action) {
    # 1. ファイル・フォルダ一覧取得
    "list" {
        $relPath = Get-QueryParam "path"
        $dirsOnly = (Get-QueryParam "dirsOnly") -eq "true"
        $targetDir = Resolve-SafeNasPath $relPath

        if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
            # デバッグしやすいよう、どのパスを探して失敗したかもコンソールに出力
            Write-Warning "Folder not found: $targetDir (relPath: $relPath)"
            Send-JsonResponse $response @{ error = "指定されたフォルダが存在しません。($relPath)" } 404
            return
        }

        $items = @(Get-ChildItem -LiteralPath $targetDir -Force:$false | Where-Object {
            -not $dirsOnly -or $_.PSIsContainer
        } | ForEach-Object {
            @{
                name         = $_.Name
                isDir        = [bool]$_.PSIsContainer
                size         = if ($_.PSIsContainer) { 0 } else { $_.Length }
                lastModified = $_.LastWriteTime.ToString("yyyy/MM/dd HH:mm:ss")
                timestamp    = [int64](([datetimeoffset]$_.LastWriteTime).ToUnixTimeMilliseconds())
            }
        })
        Send-JsonResponse $response @{ path = $relPath; items = $items }
    }

    # 2. ファイルダウンロード
    "download" {
        $relPath = Get-QueryParam "path"
        $targetFile = Resolve-SafeNasPath $relPath

        if (-not (Test-Path -LiteralPath $targetFile -PathType Leaf)) {
            $response.StatusCode = 404
            $response.Close()
            return
        }

        $fileName = [System.IO.Path]::GetFileName($targetFile)
        $encodedName = [System.Uri]::EscapeDataString($fileName)
        $response.ContentType = "application/octet-stream"
        $response.AddHeader("Content-Disposition", "attachment; filename=`"$fileName`"; filename*=UTF-8''$encodedName")

        $fileStream = [System.IO.File]::OpenRead($targetFile)
        $response.ContentLength64 = $fileStream.Length
        $fileStream.CopyTo($response.OutputStream)
        $fileStream.Close()
        $response.Close()
    }

    # 3. 事前重複チェック（アップロード・移動用）
    "check-exists" {
        $body = Read-JsonBody $request
        $targetDir = Resolve-SafeNasPath $body.dir
        $conflicts = @()
        foreach ($name in $body.names) {
            $checkPath = Join-Path $targetDir $name
            if (Test-Path -LiteralPath $checkPath) {
                $conflicts += $name
            }
        }
        Send-JsonResponse $response @{ conflicts = $conflicts }
    }

    # 4. ファイルアップロード
    "upload" {
        $relDir = Get-QueryParam "dir"
        $fileName = Get-QueryParam "name"
        $mode = Get-QueryParam "mode"

        $targetDir = Resolve-SafeNasPath $relDir
        $destPath = Join-Path $targetDir $fileName

        if (Test-Path -LiteralPath $destPath) {
            if ($mode -eq "rename") {
                $destPath = Get-UniqueFilePath $targetDir $fileName
            } elseif ($mode -ne "overwrite") {
                Send-JsonResponse $response @{ error = "File already exists"; conflict = $true } 409
                return
            }
        }

        $fileStream = [System.IO.File]::Create($destPath)
        $request.InputStream.CopyTo($fileStream)
        $fileStream.Close()

        Send-JsonResponse $response @{
            success   = $true
            savedName = [System.IO.Path]::GetFileName($destPath)
        }
    }

    # 5. ファイル削除
    "delete-file" {
        $body = Read-JsonBody $request
        $targetFile = Resolve-SafeNasPath $body.path
        if (Test-Path -LiteralPath $targetFile -PathType Leaf) {
            Remove-Item -LiteralPath $targetFile -Force
            Send-JsonResponse $response @{ success = $true }
        } else {
            Send-JsonResponse $response @{ error = "ファイルが見つかりません。" } 404
        }
    }

    # 6. ディレクトリ作成
    "mkdir" {
        $body = Read-JsonBody $request
        $parentDir = Resolve-SafeNasPath $body.dir
        $newDirName = $body.name.Trim()
        if ([string]::IsNullOrEmpty($newDirName) -or $newDirName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            Send-JsonResponse $response @{ error = "フォルダ名に使用できない文字が含まれています。" } 400
            return
        }
        $newDirPath = Join-Path $parentDir $newDirName
        if (Test-Path -LiteralPath $newDirPath) {
            Send-JsonResponse $response @{ error = "同名のフォルダまたはファイルが既に存在します。" } 409
            return
        }
        New-Item -ItemType Directory -Path $newDirPath | Out-Null
        Send-JsonResponse $response @{ success = $true }
    }

    # 7. ディレクトリ削除（空でない場合は中断）
    "rmdir" {
        $body = Read-JsonBody $request
        $targetDir = Resolve-SafeNasPath $body.path
        if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
            Send-JsonResponse $response @{ error = "フォルダが見つかりません。" } 404
            return
        }
        $children = @(Get-ChildItem -LiteralPath $targetDir -Force)
        if ($children.Count -gt 0) {
            Send-JsonResponse $response @{
                error = "フォルダ内にファイルまたはサブフォルダが存在するため、削除を中断しました。"
            } 400
            return
        }
        Remove-Item -LiteralPath $targetDir -Force
        Send-JsonResponse $response @{ success = $true }
    }

    # 8. ファイル移動
    "move" {
        $body = Read-JsonBody $request
        $srcDir = Resolve-SafeNasPath $body.sourceDir
        $destDir = Resolve-SafeNasPath $body.targetDir
        $resolutions = $body.resolutions

        $movedCount = 0
        foreach ($fileName in $body.files) {
            $srcFile = Join-Path $srcDir $fileName
            if (-not (Test-Path -LiteralPath $srcFile -PathType Leaf)) { continue }

            $destFile = Join-Path $destDir $fileName
            if ($srcFile -eq $destFile) { continue }

            if (Test-Path -LiteralPath $destFile) {
                $act = if ($resolutions -and $resolutions.$fileName) { $resolutions.$fileName } else { "cancel" }
                if ($act -eq "cancel") { continue }
                elseif ($act -eq "rename") {
                    $destFile = Get-UniqueFilePath $destDir $fileName
                }
            }
            Move-Item -LiteralPath $srcFile -Destination $destFile -Force
            $movedCount++
        }
        Send-JsonResponse $response @{ success = $true; movedCount = $movedCount }
    }
}