# スマホだけで動くアプリ（Cloud Run の API につなぐ）を作って入れる。
#
#   1. env/real.example.json を env/real.json に写し、APP_TOKEN を書く（real.json はコミットしない）
#   2. app/mobile で:  pwsh tool/build_release.ps1            （APK を作る）
#                      pwsh tool/build_release.ps1 -Install   （つないだ端末に入れる）
#
# 入れたあとは PC につながなくても動く（API・警報・読み上げ・顔ぼかしは端末と Cloud Run だけで動く）。
param([switch]$Install)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

$envFile = 'env/real.json'
if (-not (Test-Path $envFile)) { throw "$envFile がありません。env/real.example.json を写して APP_TOKEN を書いてください" }
$cfg = Get-Content $envFile -Raw | ConvertFrom-Json
if (-not $cfg.APP_TOKEN -or $cfg.APP_TOKEN -match 'ここに') { throw "$envFile の APP_TOKEN が未設定です" }
if ($cfg.API_MODE -ne 'real' -or -not $cfg.API_BASE_URL) { throw "$envFile は API_MODE=real と API_BASE_URL が要ります" }

# 生存確認（トークンは送らない）
try {
  $h = Invoke-RestMethod -Uri "$($cfg.API_BASE_URL)/health" -TimeoutSec 20
  Write-Host "API の生存確認: $($h.status)"
} catch { Write-Warning "API の生存確認に失敗しました（ビルドは続けます）: $_" }

flutter build apk --release --dart-define-from-file=$envFile
if ($LASTEXITCODE -ne 0) { throw 'ビルドに失敗しました' }
$apk = 'build/app/outputs/flutter-apk/app-release.apk'
Write-Host "できた APK: $apk"

if ($Install) {
  # flutter install は古い版を消してから入れる（設定・歩行ログも消える）ので、adb で上書きする
  $adb = Join-Path $env:LOCALAPPDATA 'Android/Sdk/platform-tools/adb.exe'
  if (-not (Test-Path $adb)) { $adb = 'adb' }
  # 使える状態（device）の端末だけを選ぶ（オフラインのエミュレーターがあっても入れられるように）
  $devices = @(& $adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '	device$' } | ForEach-Object { ($_ -split '	')[0] })
  if ($devices.Count -ne 1) { throw "使える端末が $($devices.Count) 台です。1台だけつないでください" }
  & $adb -s $devices[0] install -r $apk
  if ($LASTEXITCODE -ne 0) { throw '端末に入れられませんでした' }
}
