[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$StageRoot = '',
    [string]$PythonVersion = '3.13.2',
    [string]$EsptoolVersion = '5.2.0'
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    } else {
        $RepoRoot = (Get-Location).Path
    }
}

if ([string]::IsNullOrWhiteSpace($StageRoot)) {
    $StageRoot = Join-Path $RepoRoot 'dist\windows-installer'
}

function Copy-Directory {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path $Source)) {
        throw "Required path not found: $Source"
    }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Copy-Item -Path (Join-Path $Source '*') -Destination $Destination -Recurse -Force
}

$hostBuildRoot = Join-Path $RepoRoot 'host_app\build\windows\x64\runner\Release'
$appRoot = Join-Path $StageRoot 'app'
$toolsRoot = Join-Path $appRoot 'tools'
$pythonRoot = Join-Path $toolsRoot 'python'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'nimble-hitl-installer'
$pythonArchive = Join-Path $tempRoot "python-$PythonVersion-embed-amd64.zip"
$esptoolArchive = Join-Path $tempRoot "esptool-v$EsptoolVersion-windows-amd64.zip"
$esptoolExpandRoot = Join-Path $tempRoot 'esptool-expanded'
$esptoolRoot = Join-Path $toolsRoot 'esptool'
$pythonTag = ($PythonVersion.Split('.')[0..1] -join '')
$pythonPth = Join-Path $pythonRoot "python$pythonTag._pth"
$pythonExe = Join-Path $pythonRoot 'python.exe'
$getPip = Join-Path $tempRoot 'get-pip.py'

if (-not (Test-Path $hostBuildRoot)) {
    throw "Flutter Windows release output not found at $hostBuildRoot. Run 'flutter build windows' in host_app first."
}

Remove-Item -Path $StageRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $appRoot -Force | Out-Null
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

Copy-Directory -Source $hostBuildRoot -Destination $appRoot
Copy-Directory -Source (Join-Path $RepoRoot 'firmware') -Destination (Join-Path $appRoot 'firmware')
Copy-Directory -Source (Join-Path $RepoRoot 'shared') -Destination (Join-Path $appRoot 'shared')

$pythonUrl = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-embed-amd64.zip"
$esptoolUrl = "https://github.com/espressif/esptool/releases/download/v$EsptoolVersion/esptool-v$EsptoolVersion-windows-amd64.zip"
Invoke-WebRequest -Uri $pythonUrl -OutFile $pythonArchive
Invoke-WebRequest -Uri $esptoolUrl -OutFile $esptoolArchive
New-Item -ItemType Directory -Path $pythonRoot -Force | Out-Null
New-Item -ItemType Directory -Path $esptoolExpandRoot -Force | Out-Null
Expand-Archive -Path $pythonArchive -DestinationPath $pythonRoot -Force
Expand-Archive -Path $esptoolArchive -DestinationPath $esptoolExpandRoot -Force

$esptoolEntries = Get-ChildItem -Path $esptoolExpandRoot
$esptoolSource = if ($esptoolEntries.Count -eq 1 -and $esptoolEntries[0].PSIsContainer) {
    $esptoolEntries[0].FullName
} else {
    $esptoolExpandRoot
}
Copy-Directory -Source $esptoolSource -Destination $esptoolRoot

New-Item -ItemType Directory -Path (Join-Path $pythonRoot 'Lib\site-packages') -Force | Out-Null
$pthContent = Get-Content -Path $pythonPth
$filteredContent = foreach ($line in $pthContent) {
    if ($line -ne 'Lib\site-packages' -and $line -ne 'import site') {
        $line
    }
}
$updatedContent = @($filteredContent) + 'Lib\site-packages' + 'import site'
Set-Content -Path $pythonPth -Value $updatedContent

Invoke-WebRequest -Uri 'https://bootstrap.pypa.io/get-pip.py' -OutFile $getPip
& $pythonExe $getPip '--disable-pip-version-check' '--no-warn-script-location'
& $pythonExe -m pip install '--upgrade' 'pip' 'setuptools' 'wheel' '--disable-pip-version-check' '--no-warn-script-location'
& $pythonExe -m pip install 'platformio' 'esptool' '--disable-pip-version-check' '--no-warn-script-location'

$manifest = @(
    "stage_root=$StageRoot"
    "app_root=$appRoot"
    "python_version=$PythonVersion"
    "esptool_version=$EsptoolVersion"
    "python_executable=tools\python\python.exe"
    "esptool_executable=tools\esptool\esptool.exe"
    "bundled_python_modules=platformio,esptool"
    "bundled_native_tools=esptool"
) -join "`r`n"
Set-Content -Path (Join-Path $StageRoot 'bundle_manifest.txt') -Value $manifest

Write-Host "Staged self-contained Windows bundle at $StageRoot"
