$ErrorActionPreference = 'Stop'

flutter build apk --debug --split-per-abi
if ($LASTEXITCODE -ne 0) {
  exit $LASTEXITCODE
}

$targetDir = 'C:\temp\microzaimich_vscode'
New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
Copy-Item -Force 'build\app\outputs\flutter-apk\app-x86_64-debug.apk' (Join-Path $targetDir 'app-x86_64-debug.apk')

Write-Output 'Prepared C:\temp\microzaimich_vscode\app-x86_64-debug.apk'
