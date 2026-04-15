$ErrorActionPreference = "Stop"

function Get-EnvValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if (-not (Test-Path $FilePath)) {
        throw ".env failas nerastas: $FilePath"
    }

    $lines = [System.IO.File]::ReadAllLines($FilePath, [System.Text.Encoding]::UTF8)
    $prefix = "$Key="
    $value = $null

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith("#") -or [string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        if ($trimmed.StartsWith($prefix)) {
            $value = $trimmed.Substring($prefix.Length)
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Nerastas '$Key' raktas .env faile."
    }

    return $value.Trim().Trim("'`"")
}

function Get-ContentType {
    param([string]$Path)

    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($ext) {
        ".html" { "text/html; charset=utf-8" }
        ".css" { "text/css; charset=utf-8" }
        ".js" { "application/javascript; charset=utf-8" }
        ".json" { "application/json; charset=utf-8" }
        ".png" { "image/png" }
        ".jpg" { "image/jpeg" }
        ".jpeg" { "image/jpeg" }
        ".mp3" { "audio/mpeg" }
        ".mp4" { "video/mp4" }
        default { "application/octet-stream" }
    }
}

function Send-Json {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [int]$StatusCode,
        [hashtable]$Data
    )

    $json = $Data | ConvertTo-Json -Depth 8
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = "application/json; charset=utf-8"
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$envPath = Join-Path $projectRoot ".env"
$apiKey = Get-EnvValue -FilePath $envPath -Key "GEMINI_API_KEY"
$port = 8091

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()

Write-Host ""
Write-Host "Serveris paleistas: http://localhost:$port" -ForegroundColor Green
Write-Host "Sustabdymas: Ctrl+C" -ForegroundColor Yellow
Write-Host ""

$systemMessage = @"
Tu esi generalisto karjeros ekspertas.

TAISYKLES:
1) Atsakyk tik i klausimus apie generalisto karjera: igudziai, karjeros kryptis, darbo rinka, CV, portfolio, interviu, atlyginimo derybos, mokymosi planas, darbo paieska, perejimas tarp roliu.
2) Jei klausimas NE apie generalisto karjera (pvz. gamta, orai, politika, bendros zinios, programavimo bugai, medicina ir kt.), PRIVALAI atsisakyti atsakyti.
3) Atsisakymas turi buti trumpas, mandagus, lietuviskas, ir pasiulyti uzduoti klausima apie generalisto karjera.
4) Neissipleisk ir neapeik taisykliu.
"@

$allowedTopicPattern = "(?i)(generalist|generalisto|karjer|cv|portfolio|reziume|interviu|darbo rinka|atlyginim|igudz|kompetenc|mokymosi plan|darbo paiesk|role|junior|mid|senior|specializacij|persikvalifik)"

while ($listener.IsListening) {
    try {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        $rawPath = $request.Url.AbsolutePath.TrimStart("/")
        $path = [Uri]::UnescapeDataString($rawPath)

        if ($request.HttpMethod -eq "POST" -and $path -eq "api/generalist-chat") {
            $encoding = $request.ContentEncoding
            if ($null -eq $encoding) {
                $encoding = [System.Text.Encoding]::UTF8
            }

            $reader = New-Object System.IO.StreamReader($request.InputStream, $encoding)
            $body = $reader.ReadToEnd()
            $reader.Close()

            if ([string]::IsNullOrWhiteSpace($body)) {
                Send-Json -Response $response -StatusCode 400 -Data @{ error = "Tuscias uzklausos body." }
                continue
            }

            try {
                $payload = $body | ConvertFrom-Json
            } catch {
                Send-Json -Response $response -StatusCode 400 -Data @{ error = "Neteisingas JSON formatas." }
                continue
            }

            $userMessage = [string]$payload.message
            if ([string]::IsNullOrWhiteSpace($userMessage)) {
                Send-Json -Response $response -StatusCode 400 -Data @{ error = "Zinute tuscia." }
                continue
            }

            if ($userMessage -notmatch $allowedTopicPattern) {
                Send-Json -Response $response -StatusCode 200 -Data @{
                    reply = "Atsiprasau, atsakau tik i klausimus apie generalisto karjera. Uzduokite klausima sia tema."
                }
                continue
            }

            $geminiBody = @{
                systemInstruction = @{
                    role = "system"
                    parts = @(
                        @{
                            text = $systemMessage
                        }
                    )
                }
                contents = @(
                    @{
                        role = "user"
                        parts = @(
                            @{
                                text = $userMessage
                            }
                        )
                    }
                )
                generationConfig = @{
                    temperature = 0.4
                    maxOutputTokens = 450
                }
            } | ConvertTo-Json -Depth 10

            try {
                $geminiModels = @("gemini-2.0-flash", "gemini-1.5-flash", "gemini-1.5-flash-latest")
                $geminiResponse = $null
                $lastGeminiError = ""

                foreach ($modelName in $geminiModels) {
                    try {
                        $geminiResponse = Invoke-RestMethod `
                            -Method Post `
                            -Uri "https://generativelanguage.googleapis.com/v1beta/models/$modelName:generateContent?key=$apiKey" `
                            -Headers @{
                                "Content-Type" = "application/json"
                            } `
                            -Body $geminiBody
                        if ($geminiResponse) {
                            break
                        }
                    } catch {
                        $lastGeminiError = $_.Exception.Message
                    }
                }

                if (-not $geminiResponse) {
                    throw "Nepavyko pasiekti Gemini modelio. $lastGeminiError"
                }

                $replyText = ""
                if ($geminiResponse.candidates -and $geminiResponse.candidates.Count -gt 0) {
                    $candidate = $geminiResponse.candidates[0]
                    if ($candidate.content -and $candidate.content.parts) {
                        foreach ($part in $candidate.content.parts) {
                            if ($part.text) {
                                $replyText += $part.text
                            }
                        }
                    }
                }

                if ([string]::IsNullOrWhiteSpace($replyText)) {
                    $replyText = "Nepavyko sugeneruoti atsakymo. Pabandykite dar karta."
                }

                Send-Json -Response $response -StatusCode 200 -Data @{ reply = $replyText.Trim() }
            } catch {
                $geminiError = $_.Exception.Message
                Send-Json -Response $response -StatusCode 500 -Data @{ error = "Gemini uzklausa nepavyko."; details = $geminiError }
            }

            continue
        }

        if ([string]::IsNullOrWhiteSpace($path)) {
            $path = "index.html"
        }

        $filePath = Join-Path $projectRoot $path
        if (-not (Test-Path $filePath -PathType Leaf)) {
            $response.StatusCode = 404
            $notFound = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found")
            $response.OutputStream.Write($notFound, 0, $notFound.Length)
            $response.OutputStream.Close()
            continue
        }

        $bytes = [System.IO.File]::ReadAllBytes($filePath)
        $response.StatusCode = 200
        $response.ContentType = Get-ContentType -Path $filePath
        $response.ContentLength64 = $bytes.Length
        $response.OutputStream.Write($bytes, 0, $bytes.Length)
        $response.OutputStream.Close()
    } catch {
        if ($listener.IsListening) {
            try {
                $response = $context.Response
                Send-Json -Response $response -StatusCode 500 -Data @{ error = "Serverio klaida."; details = $_.Exception.Message }
            } catch {
                # Ignore secondary response errors.
            }
        }
    }
}
