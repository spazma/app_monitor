# ============================
#  Process Monitor API Server
# ============================

$ErrorActionPreference = "SilentlyContinue"

# Load config
$configPath = Join-Path $PSScriptRoot "config.json"
$config = Get-Content $configPath | ConvertFrom-Json

# Konwertuj arrays na rzeczywiste arraye jeśli są nullami
if ($config.apps -eq $null) { $config.apps = @() }
if ($config.monitor -eq $null) { $config.monitor = @() }

# Start HTTP listener
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:8080/")
$listener.Start()

$serverStartTime = Get-Date

Write-Host "API server running at http://localhost:8080" -ForegroundColor Green
Write-Host "-------------------------------------------" -ForegroundColor Green
Write-Host "Config path: $configPath" -ForegroundColor Cyan
Write-Host "File exists: $(Test-Path $configPath)" -ForegroundColor Cyan
Write-Host "-------------------------------------------" -ForegroundColor Green
Write-Host "Server started at: $($serverStartTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Green
Write-Host "Status: Online" -ForegroundColor Green
Write-Host "Waiting for requests..." -ForegroundColor Yellow

function Send-Response($context, $text, $contentType = "text/plain") {
    $context.Response.Headers.Add("Access-Control-Allow-Origin", "*")
    $context.Response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    $context.Response.Headers.Add("Access-Control-Allow-Headers", "*")
    $context.Response.ContentType = $contentType

    $buffer = [System.Text.Encoding]::UTF8.GetBytes($text)
    $context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $context.Response.Close()
}

while ($true) {
    $context = $listener.GetContext()
    $req = $context.Request
    $path = $req.Url.AbsolutePath
    $query = $req.QueryString

    # Handle OPTIONS (CORS preflight)
    if ($req.HttpMethod -eq "OPTIONS") {
        $context.Response.Headers.Add("Access-Control-Allow-Origin", "*")
        $context.Response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        $context.Response.Headers.Add("Access-Control-Allow-Headers", "*")
        $context.Response.StatusCode = 200
        $context.Response.Close()
        continue
    }

	# /list
	if ($path -eq "/list") {
		Send-Response $context ($config | ConvertTo-Json -Depth 5) "application/json"
		continue
	}

    # /run - uruchom server.ps1 w nowym oknie (jeśli się urywał)
    if ($path -eq "/run") {
        if ($req.HttpMethod -eq "POST") {
            $scriptPath = $PSCommandPath
            Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
            Send-Response $context "Server started" "text/plain"
        }
        continue
    }

    # /add - dodaj aplikację
    if (($path -eq "/add" -or $path -eq "/add/") -and $req.HttpMethod -eq "POST") {
        $body = $req.InputStream
        $reader = New-Object System.IO.StreamReader($body)
        $json = $reader.ReadToEnd()
        $reader.Close()

        # Przeładuj config ze świeżych danych
        $config = Get-Content $configPath | ConvertFrom-Json

        if ($config.apps -eq $null) { $config.apps = @() }
        if ($config.monitor -eq $null) { $config.monitor = @() }

        $payload = $json | ConvertFrom-Json

        $newApp = [PSCustomObject]@{
            name = $payload.name
            process = $payload.process
            path = $payload.path
        }

        if ($payload.section -eq "monitor" -or $payload.clickable) {
            $newApp | Add-Member -NotePropertyName "clickable" -NotePropertyValue $true
        }

        # Dodaj do odpowiedniej sekcji
        if ($payload.section -eq "apps") {
            $config.apps = @($config.apps) + @($newApp)
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Write-Host "[$timestamp] DODANO APLIKACJĘ: $($payload.name) ($($payload.process))" -ForegroundColor Green
        } elseif ($payload.section -eq "monitor") {
            $config.monitor = @($config.monitor) + @($newApp)
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Write-Host "[$timestamp] DODANO DO MONITOROWANIA: $($payload.name) ($($payload.process))" -ForegroundColor Cyan
        }

        $config | ConvertTo-Json -Depth 10 | Out-File -FilePath $configPath -Encoding UTF8 -Force

        # Zwolnij pamięć
        $reader.Dispose()
        $payload = $null
        $newApp = $null

        Send-Response $context "Added" "text/plain"
        continue
    }

    # /remove - usuń aplikację
    if (($path -eq "/remove" -or $path -eq "/remove/") -and $req.HttpMethod -eq "POST") {
        $body = $req.InputStream
        $reader = New-Object System.IO.StreamReader($body)
        $json = $reader.ReadToEnd()
        $reader.Close()

        $payload = $json | ConvertFrom-Json

        # Przeładuj config
        $config = Get-Content $configPath | ConvertFrom-Json
        if ($config.apps -eq $null) { $config.apps = @() }
        if ($config.monitor -eq $null) { $config.monitor = @() }

        # Usuń z odpowiedniej sekcji
        if ($payload.section -eq "apps") {
            $removedApps = $config.apps | Where-Object { $_.process -in $payload.processes }
            $config.apps = $config.apps | Where-Object { $_.process -notin $payload.processes }
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            foreach ($app in $removedApps) {
                Write-Host "[$timestamp] USUNIĘTO APLIKACJĘ: $($app.name) ($($app.process))" -ForegroundColor Yellow
            }
        } elseif ($payload.section -eq "monitor") {
            $removedApps = $config.monitor | Where-Object { $_.process -in $payload.processes }
            $config.monitor = $config.monitor | Where-Object { $_.process -notin $payload.processes }
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            foreach ($app in $removedApps) {
                Write-Host "[$timestamp] USUNIĘTO Z MONITOROWANIA: $($app.name) ($($app.process))" -ForegroundColor Yellow
            }
        }

        # Zapisz config
        $config | ConvertTo-Json -Depth 10 | Out-File -FilePath $configPath -Encoding UTF8 -Force

        # Zwolnij pamięć
        $reader.Dispose()
        $payload = $null
        $removedApps = $null

        Send-Response $context "Removed" "text/plain"
        continue
    }

    # Get app by process name
    $procName = $query["proc"]
    $app = $config.apps | Where-Object { $_.process -eq $procName }
    
    # Jeśli nie ma w apps, szukaj w monitor
    if (-not $app) {
        $app = $config.monitor | Where-Object { $_.process -eq $procName }
    }

    if (-not $app) {
        Send-Response $context "Unknown process"
        continue
    }

    # /status
    if ($path -eq "/status") {
        $p = Get-Process $app.process -ErrorAction SilentlyContinue
        $msg = if ($p) { "running" } else { "stopped" }
        Send-Response $context $msg
        continue
    }

    # /kill
    if ($path -eq "/kill") {
        $processName = $app.name
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Stop-Process -Name $app.process -Force -ErrorAction SilentlyContinue
        Write-Host "[$timestamp] KILLED: $processName ($($app.process))" -ForegroundColor Red
        
        # Przeładuj config i sprawdź status
        $config = Get-Content $configPath | ConvertFrom-Json
        Send-Response $context "stopped"
        continue
    }

    # /start
    if ($path -eq "/start") {
        $processName = $app.name
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Start-Process $app.path -ErrorAction SilentlyContinue
        Write-Host "[$timestamp] URUCHOMIONO: $processName ($($app.process))" -ForegroundColor Green
        
        Start-Sleep -Milliseconds 500
        Send-Response $context "running"
        continue
    }

    # /restart
    if ($path -eq "/restart") {
        $processName = $app.name
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Stop-Process -Name $app.process -Force -ErrorAction SilentlyContinue
        Write-Host "[$timestamp] STOPPED: $processName ($($app.process))" -ForegroundColor Yellow
        
        Start-Sleep -Milliseconds 500
        Start-Process $app.path -ErrorAction SilentlyContinue
        Write-Host "[$timestamp] RESTARTED: $processName ($($app.process))" -ForegroundColor Green
        
        Start-Sleep -Milliseconds 500
        Send-Response $context "running"
        continue
    }

    Send-Response $context "Invalid endpoint"
	
	# Wyświetl uptime co jakiś czas
    if ($uptime) {
        $elapsed = (Get-Date) - $serverStartTime
        Write-Host "Uptime: $($elapsed.Hours)h $($elapsed.Minutes)m $($elapsed.Seconds)s" -ForegroundColor Cyan
    }
}