$ErrorActionPreference = "Stop"
$LaunchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:RTABMAP_REPROCESS = Join-Path $LaunchDir "bin\rtabmap-reprocess.exe"
$env:MARKETSCANNER_FACTOR_GRAPH_BIN = Join-Path $LaunchDir "bin\rtabmap-prior-map-factor-graph.exe"

$Python = Get-Command py -ErrorAction SilentlyContinue
if ($null -ne $Python) {
    $PythonArgs = @("-3")
    $PythonExe = $Python.Source
} else {
    $PythonExe = (Get-Command python -ErrorAction Stop).Source
    $PythonArgs = @()
}

$Server = Join-Path $LaunchDir "tools\SupermarketMapStudio\server.py"
& $PythonExe @PythonArgs $Server --selfcheck --mode production
if ($LASTEXITCODE -ne 0) {
    Write-Error "Supermarket Map Studio startup self-check failed. Keep this output for support."
    exit $LASTEXITCODE
}
& $PythonExe @PythonArgs $Server --mode production @args
exit $LASTEXITCODE
